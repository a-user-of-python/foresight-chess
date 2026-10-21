import Foundation

/// Alpha-beta search with adjustable foresight depth, using the KnowledgeNet
/// as the evaluation function.
///
/// Foresight is measured in full moves (1 move = 2 plies). The user sets it
/// in-app: 1 = sees one move ahead, 3 = sees three moves ahead.
///
/// This is a separate app from Adaptive Chess with different rules — here
/// the user explicitly asked for adjustable lookahead, so search is allowed.
final class ForesightSearch {

    let network: KnowledgeNet
    /// Full moves ahead to see (1...3). Plies = moves * 2.
    var foresightMoves: Int

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
    func searchCandidates(game: ChessGame) -> [Candidate] {
        let moves = game.legalMoves()
        guard !moves.isEmpty else { return [] }

        let depth = foresightMoves * 2
        var candidates: [Candidate] = []

        for m in moves {
            game.makeMove(m)
            let (value, line) = alphaBeta(game: game, depth: depth - 1,
                                          alpha: -.infinity, beta: .infinity)
            game.undoMove()
            candidates.append(Candidate(move: m, value: value, line: [m] + line))
        }

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

    private func alphaBeta(game: ChessGame, depth: Int,
                           alpha: Float, beta: Float) -> (Float, [Move]) {
        if game.isGameOver || depth <= 0 {
            return (evaluate(game), [])
        }

        let moves = orderedMoves(game: game)
        guard !moves.isEmpty else { return (evaluate(game), []) }

        let maximizing = (game.sideToMove == .white)
        var a = alpha
        var b = beta
        var bestLine: [Move] = []

        if maximizing {
            var best: Float = -.infinity
            for m in moves {
                game.makeMove(m)
                let (v, line) = alphaBeta(game: game, depth: depth - 1, alpha: a, beta: b)
                game.undoMove()
                if v > best {
                    best = v
                    bestLine = [m] + line
                }
                a = max(a, best)
                if a >= b { break }  // beta cutoff
            }
            return (best, bestLine)
        } else {
            var best: Float = .infinity
            for m in moves {
                game.makeMove(m)
                let (v, line) = alphaBeta(game: game, depth: depth - 1, alpha: a, beta: b)
                game.undoMove()
                if v < best {
                    best = v
                    bestLine = [m] + line
                }
                b = min(b, best)
                if a >= b { break }  // alpha cutoff
            }
            return (best, bestLine)
        }
    }

    /// Move ordering: captures and checks first (cheap heuristic,
    /// dramatically improves alpha-beta pruning).
    private func orderedMoves(game: ChessGame) -> [Move] {
        let moves = game.legalMoves()
        // Score: captures first, then checks. Simple but effective.
        return moves.sorted { m1, m2 in
            score(m1, game: game) > score(m2, game: game)
        }
    }

    private func score(_ m: Move, game: ChessGame) -> Int {
        var s = 0
        if m.isCapture { s += 10 }
        if m.promotion != nil { s += 8 }
        game.makeMove(m)
        if game.isInCheck { s += 5 }
        game.undoMove()
        return s
    }

    private func terminalValue(_ game: ChessGame) -> Float {
        if game.isCheckmate {
            return game.sideToMove == .white ? -1 : 1
        }
        return 0
    }
}
