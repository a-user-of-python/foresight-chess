import SwiftUI

/// Main game view: you play White, the on-device AI (Foundation Models +
/// KnowledgeNet) plays Black.
final class GameViewModel: ObservableObject {
    @Published var game = ChessGame()
    @Published var selectedSquare: Square?
    @Published var lastMove: Move?
    @Published var aiThinking = false
    @Published var statusText = "White to move"
    @Published var gameOverText: String? = nil
    @Published var aiExplanation: String? = nil
    @Published var showSettings = false

    private var recorded = false
    private var gameID = UUID()

    /// Foresight depth in full moves (1...3). Adjustable in settings.
    /// Clamped on set — never triggers recursion, never crashes.
    @Published var foresightMoves: Int = 2 {
        didSet {
            let clamped = max(1, min(3, foresightMoves))
            if clamped != foresightMoves {
                // Defer to avoid didSet re-entry issues.
                DispatchQueue.main.async { [weak self] in
                    self?.foresightMoves = clamped
                }
            }
        }
    }

    private func refresh() { objectWillChange.send() }

    init() { updateStatus() }

    // MARK: - User actions

    func userDidChooseMove(_ move: Move) {
        guard !aiThinking, !game.isGameOver,
              game.sideToMove == .white else { return }
        game.makeMove(move)
        refresh()
        lastMove = move
        selectedSquare = nil
        updateStatus()
        if checkGameOver() { return }
        triggerAIMove()
    }

    func newGame() {
        if !recorded && !game.isGameOver && game.moveHistory.count >= 4 {
            finishGame(result: .draw, message: "Game abandoned.")
        }
        gameID = UUID()
        game = ChessGame()
        selectedSquare = nil
        lastMove = nil
        aiThinking = false
        recorded = false
        gameOverText = nil
        aiExplanation = nil
        updateStatus()
    }

    func resign() {
        guard !game.isGameOver, !recorded else { return }
        finishGame(result: .blackWins, message: "You resigned. AI wins.")
    }

    // MARK: - AI turn (Stockfish)

    private func triggerAIMove() {
        guard !game.isGameOver, game.sideToMove == .black,
              !recorded else { return }
        aiThinking = true
        updateStatus()

        let id = gameID
        let fen = game.toFEN()
        // Foresight slider (1-3) maps to Stockfish time budget in bestMove.
        let depth = foresightMoves

        DispatchQueue.global(qos: .userInitiated).async {
            // Stockfish plays the move. Retry once if the first attempt fails.
            var uciMove: String? = nil
            var position: ChessGame? = nil
            var chosen: Move? = nil
            for _ in 0..<2 {
                uciMove = StockfishEngine.shared.bestMove(fen: fen, depth: depth)
                if let m = uciMove,
                   let pos = ChessGame(fen: fen),
                   let c = pos.legalMoves().first(where: { $0.uci == m }) {
                    position = pos
                    chosen = c
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard let uci = uciMove, let pos = position, let move = chosen else {
                // Stockfish failed twice — show error instead of soft-locking.
                Task { @MainActor [weak self] in
                    self?.aiThinking = false
                    self?.aiExplanation = "Stockfish didn't respond. Try moving foresight or restarting the app."
                    self?.updateStatus()
                }
                return
            }
            let chosenMove = move
            let pos = pos
            let uciStr = uci

            // KnowledgeNet learns from Stockfish's evaluation (distillation).
            // Done in background, doesn't block the move.
            let sfEval = StockfishEngine.shared.evaluate(fen: fen, depth: 10)

            Task { @MainActor [weak self] in
                guard let self = self,
                      self.gameID == id,
                      !self.recorded else { return }
                self.aiThinking = false
                self.game.makeMove(chosenMove)
                self.refresh()
                self.lastMove = chosenMove
                self.selectedSquare = nil
                self.aiExplanation = "Stockfish (foresight \(depth)) played \(uciStr)."
                self.updateStatus()

                // Distillation: teach KnowledgeNet Stockfish's eval.
                if let target = sfEval {
                    DispatchQueue.global(qos: .utility).async {
                        let network = KnowledgeStore.shared.currentNetwork()
                        let x = PositionEncoder.encode(pos)
                        // Train all 3 outputs toward Stockfish's eval.
                        for _ in 0..<3 {
                            network.train(x: x, targets: [target, target, target], lr: 0.01)
                        }
                        KnowledgeStore.shared.save(network.exportWeights())
                    }
                }

                _ = self.checkGameOver()
            }
        }
    }

    // MARK: - Status & game over

    private func updateStatus() {
        if let over = gameOverText {
            statusText = over
            return
        }
        if aiThinking {
            statusText = "AI is thinking…"
            return
        }
        statusText = game.sideToMove == .white ? "White to move" : "Black to move"
    }

    private func checkGameOver() -> Bool {
        let result: GameResult
        let message: String
        if game.isCheckmate {
            if game.sideToMove == .white {
                result = .blackWins
                message = "Checkmate — AI wins."
            } else {
                result = .whiteWins
                message = "Checkmate — you win!"
            }
        } else if game.isStalemate {
            result = .draw
            message = "Draw by stalemate."
        } else if game.isDrawByFiftyMove {
            result = .draw
            message = "Draw by fifty-move rule."
        } else if game.isDrawByRepetition {
            result = .draw
            message = "Draw by threefold repetition."
        } else if game.isDrawByInsufficientMaterial {
            result = .draw
            message = "Draw by insufficient material."
        } else {
            return false
        }
        finishGame(result: result, message: message)
        return true
    }

    private func finishGame(result: GameResult, message: String) {
        recorded = true
        aiThinking = false
        gameOverText = message
        statusText = message
        let moves = game.moveHistory

        // Train the knowledge network on this game (background).
        DispatchQueue.global(qos: .utility).async {
            let network = KnowledgeStore.shared.currentNetwork()
            let trainer = KnowledgeTrainer(network: network)
            trainer.trainOnGame(moves: moves, result: result, aiColor: .black)
            KnowledgeStore.shared.save(network.exportWeights())
        }
    }
}

// MARK: - View

struct GameView: View {
    @StateObject private var vm = GameViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text(vm.statusText)
                    .font(.title2)
                    .padding(.top)

                BoardView(game: vm.game,
                          selectedSquare: $vm.selectedSquare,
                          lastMove: $vm.lastMove,
                          interactionEnabled: !vm.aiThinking && vm.gameOverText == nil,
                          onMove: vm.userDidChooseMove)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal)

                if let explanation = vm.aiExplanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .lineLimit(3)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button("New Game") { vm.newGame() }
                        .buttonStyle(.bordered)
                    Button("Resign") { vm.resign() }
                        .buttonStyle(.bordered)
                        .disabled(vm.gameOverText != nil)
                    Button("Foresight: \(vm.foresightMoves)") {
                        vm.showSettings = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.bottom)
            }
            .navigationTitle("Foresight Chess")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $vm.showSettings) {
                SettingsView(foresightMoves: $vm.foresightMoves)
            }
        }
        .navigationViewStyle(.stack)
    }
}
