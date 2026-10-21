import Foundation

/// Trains the KnowledgeNet on finished games.
///
/// The network is the app's chess reference — it gets better over time as it
/// absorbs real games. Same approach as Adaptive Chess: TD(λ) over all
/// positions, plus a full move-by-move review where the network coaches
/// itself on every suboptimal move it made.
final class KnowledgeTrainer {

    let network: KnowledgeNet

    init(network: KnowledgeNet) {
        self.network = network
    }

    // MARK: - Training

    func trainOnGame(moves: [Move], result: GameResult, aiColor: PieceColor) {
        guard !moves.isEmpty else { return }

        // Rebuild every position from the opening.
        let game = ChessGame()
        var positions: [[Float]] = []
        positions.reserveCapacity(moves.count)
        for m in moves {
            positions.append(PositionEncoder.encode(game))
            game.makeMove(m)
        }

        let finalResult: Float
        switch result {
        case .whiteWins: finalResult = 1
        case .blackWins: finalResult = -1
        case .draw: finalResult = 0
        }

        // Phase 1: TD(λ) over all positions.
        let lambda: Float = 0.7
        let lr: Float = 0.015
        let epochs = 3

        for _ in 0..<epochs {
            var boot0 = finalResult
            var boot1 = finalResult
            var boot2 = finalResult
            for idx in positions.indices.reversed() {
                let x = positions[idx]
                let f1 = positions[min(idx + 2, positions.count - 1)]
                let f2 = positions[min(idx + 4, positions.count - 1)]

                let t0 = lambda * boot0 + (1 - lambda) * finalResult
                let t1 = lambda * boot1 + (1 - lambda) * finalResult
                let t2 = lambda * boot2 + (1 - lambda) * finalResult

                network.train(x: x, targets: [t0, t1, t2], lr: lr)

                let preds = network.forwardMulti(x)
                boot0 = preds[0]
                boot1 = network.forwardMulti(f1)[0]
                boot2 = network.forwardMulti(f2)[0]
            }
        }

        // Phase 2: move-by-move review of the AI's moves.
        let aiIsWhite = (aiColor == .white)
        let aiSign: Float = aiIsWhite ? 1 : -1
        let reviewLr: Float = 0.03
        let reviewThreshold: Float = 0.15

        let reviewGame = ChessGame()
        for idx in moves.indices {
            let isAiMove = aiIsWhite ? (idx % 2 == 0) : (idx % 2 == 1)
            if isAiMove {
                let legal = reviewGame.legalMoves()
                if !legal.isEmpty {
                    var bestVal: Float = aiIsWhite ? -.infinity : .infinity
                    for lm in legal {
                        reviewGame.makeMove(lm)
                        let v: Float
                        if reviewGame.isGameOver {
                            v = terminalValue(reviewGame)
                        } else {
                            let h = network.forwardMulti(PositionEncoder.encode(reviewGame))
                            v = 0.5 * h[0] + 0.3 * h[1] + 0.2 * h[2]
                        }
                        reviewGame.undoMove()
                        if aiIsWhite ? (v > bestVal) : (v < bestVal) {
                            bestVal = v
                        }
                    }
                    reviewGame.makeMove(moves[idx])
                    let playedVal: Float
                    if reviewGame.isGameOver {
                        playedVal = terminalValue(reviewGame)
                    } else {
                        let h = network.forwardMulti(PositionEncoder.encode(reviewGame))
                        playedVal = 0.5 * h[0] + 0.3 * h[1] + 0.2 * h[2]
                    }
                    reviewGame.undoMove()

                    let gap = (bestVal - playedVal) * aiSign
                    if gap > reviewThreshold {
                        let epochs = min(10, 2 + Int(gap * 10))
                        for _ in 0..<epochs {
                            network.train(x: positions[idx],
                                          targets: [bestVal, bestVal, bestVal],
                                          lr: reviewLr)
                        }
                    }
                }
            }
            reviewGame.makeMove(moves[idx])
        }
    }

    private func terminalValue(_ game: ChessGame) -> Float {
        if game.isCheckmate {
            return game.sideToMove == .white ? -1 : 1
        }
        return 0
    }
}
