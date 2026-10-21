import Foundation

/// Alpha-beta search with adjustable foresight depth, using the KnowledgeNet
/// as the evaluation function.
///
/// Foresight is measured in full moves (1 move = 2 plies). The user sets it
/// in-app: 1 = sees one move ahead, 3 = sees three moves ahead.
///
/// Speed safeguards (so higher foresight can't hang or crash):
/// - Breadth limit: only the top 8 moves per node (by 1-ply eval) are searched
/// - Transposition table: caches evaluations by FEN
/// - Hard time limit: search aborts after 4 seconds, returns best found so far
/// - Node cap: absolute ceiling on positions evaluated
final class ForesightSearch {

    let network: KnowledgeNet
    /// Full moves ahead to see (1...3). Plies = moves * 2.
    var foresightMoves: Int

    /// Max seconds for the whole search. Hard guarantee against hangs.
    var timeLimit: Double = 4.0
    /// Max moves searched per node (breadth limit).
    var breadthLimit: Int = 8
    /// Absolute ceiling on nodes evaluated.
    var nodeCap: Int = 20000

    private var startTime: Double = 0
    private var nodeCount: Int = 0
    private var transposition: [String: Float] = [:]
    private var timedOut: Bool = false

    init(network: KnowledgeNet, foresightMoves: Int = 2) {
        self.network = network
        self.foresightMoves = max(1, min(3, foresightMoves))
    }

    // MARK: - Public API

    /// A candidate move with its search evaluation and principal variation.
    struct Candidate {
        let move: Move
        /// Evaluation from White's perspective after the search.
        let value: Float
        /// Principal variation: the line the search considers best.
        let line: [Move]
    }

    /// Search all legal moves to the foresight depth.
    /// Returns candidates sorted best-first for the side to move.
    /// Guaranteed to return quickly (time limit + node cap).
    func searchCandidates(game: ChessGame) -> [Candidate] {
        startTime = Date().timeIntervalSince1970
        nodeCount = 0
        timedOut = false
        transposition.removeAll(keepingCapacity: true)

        let moves = game.legalMoves()
        guard !moves.isEmpty else { return [] }

        let depth = foresightMoves * 2
        var candidates: [Candidate] = []
        candidates.reserveCapacity(moves.count)

        // Order root moves by 1-ply eval so the best is found early
        // (better alpha-beta pruning, and if we time out we have the best).
        let ordered = orderByEval(moves: moves, game: game)

        for m in ordered {
            if timedOut { break }
            game.makeMove(m)
            let (value, line) = alphaBeta(game: game, depth: depth - 1,
                                          alpha: -.infinity, beta: .infinity)
            game.undoMove()
            candidates.append(Candidate(move: m, value: value, line: [m] + line))
        }

        // Sort what we have best-first for the side to move.
        let aiIsWhite = (game.sideToMove == .white)
        candidates.sort { aiIsWhite ? ($0.value > $1.value) : ($0.value < $1.value) }
        return candidates
    }

    /// Quick 1-ply evaluation for move ordering and fallback.
    func evaluate(game: ChessGame) -> Float {
        if game.isGameOver { return terminalValue(game) }
        let h = network.forwardMulti(PositionEncoder.encode(game))
        return 0.5 * h[0] + 0.3 * h[1] + 0.2 * h[2]
    }

    // MARK: - Alpha-beta

    private func checkLimits() -> Bool {
        nodeCount += 1
        if nodeCount > nodeCap { timedOut = true; return true }
        // Check time every 256 nodes (cheaper than every node).
        if nodeCount & 255 == 0 {
            if Date().timeIntervalSince1970 - startTime > timeLimit {
                timedOut = true
                return true
            }
        }
        return timedOut
    }

    private func alphaBeta(game: ChessGame, depth: Int,
                           alpha: Float, beta: Float) -> (Float, [Move]) {
        if timedOut || checkLimits() {
            return (evaluate(game), [])
        }
        if game.isGameOver || depth <= 0 {
            return (evaluate(game), [])
        }

        // Transposition table lookup.
        let key = game.toFEN()
        if let cached = transposition[key] {
            return (cached, [])
        }

        let moves = limitedMoves(game: game)
        guard !moves.isEmpty else {
            let v = evaluate(game)
            transposition[key] = v
            return (v, [])
        }

        let maximizing = (game.sideToMove == .white)
        var a = alpha
        var b = beta
        var bestLine: [Move] = []
        var best: Float = maximizing ? -.infinity : .infinity

        for m in moves {
            if timedOut { break }
            game.makeMove(m)
            let (v, line) = alphaBeta(game: game, depth: depth - 1, alpha: a, beta: b)
            game.undoMove()
            if maximizing ? (v > best) : (v < best) {
                best = v
                bestLine = [m] + line
            }
            if maximizing { a = max(a, best) } else { b = min(b, best) }
            if a >= b { break }
        }

        transposition[key] = best
        return (best, bestLine)
    }

    /// All moves at root, top-N by eval at deeper nodes.
    private func limitedMoves(game: ChessGame) -> [Move] {
        let moves = game.legalMoves()
        if moves.count <= breadthLimit { return orderByEval(moves: moves, game: game) }
        return Array(orderByEval(moves: moves, game: game).prefix(breadthLimit))
    }

    /// Order moves by 1-ply eval (best-first for side to move).
    /// Captures/checks get a small bonus for better pruning.
    private func orderByEval(moves: [Move], game: ChessGame) -> [Move] {
        let maximizing = (game.sideToMove == .white)
        var scored: [(Move, Float)] = []
        scored.reserveCapacity(moves.count)
        for m in moves {
            game.makeMove(m)
            var v = evaluate(game: game)
            // Small bonus for captures and checks (tactical moves first).
            if m.isCapture { v += maximizing ? 0.05 : -0.05 }
            if game.isInCheck(game.sideToMove) { v += maximizing ? 0.03 : -0.03 }
            game.undoMove()
            scored.append((m, v))
        }
        scored.sort { maximizing ? ($0.1 > $1.1) : ($0.1 < $1.1) }
        return scored.map { $0.0 }
    }

    private func terminalValue(_ game: ChessGame) -> Float {
        if game.isCheckmate {
            return game.sideToMove == .white ? -1 : 1
        }
        return 0
    }
}
