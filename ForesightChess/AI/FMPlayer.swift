import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Foundation Models player: Apple's on-device LLM plays the game,
/// consulting the KnowledgeNet as its chess reference.
///
/// How it works:
/// 1. ForesightSearch generates candidate moves with evaluations + principal variations
/// 2. The candidates are formatted into a compact prompt
/// 3. The on-device model picks the best move and explains its reasoning
/// 4. If the model is unavailable or the response can't be parsed, falls back
///    to the search's top candidate (the KnowledgeNet plays directly)
///
/// Requires iOS 26+ and a device with Apple Intelligence (iPhone 15 Pro+,
/// M-series iPad/Mac). Everything runs on-device — no network, no API key.
@available(iOS 26, *)
final class FMPlayer: ObservableObject {

    static let shared = FMPlayer()

    /// The model's explanation of its last move, for UI display.
    @Published var lastExplanation: String?

    /// Whether the on-device model is available right now.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    private init() {}

    // MARK: - Move selection

    /// Ask the model to pick a move. Returns the chosen move + explanation.
    /// Falls back to the search's best candidate if the model is unavailable.
    func chooseMove(game: ChessGame,
                    candidates: [ForesightSearch.Candidate],
                    foresightMoves: Int) async -> (move: Move, explanation: String) {
        guard !candidates.isEmpty else {
            fatalError("chooseMove called with no candidates")
        }

        // Fast path: model unavailable → play the search's top pick.
        guard isAvailable else {
            return (candidates[0].move,
                    "On-device AI unavailable — playing the neural network's top choice.")
        }

        let prompt = buildPrompt(game: game, candidates: candidates,
                                 foresightMoves: foresightMoves)
        do {
            #if canImport(FoundationModels)
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content
            if let move = parseMove(from: text, candidates: candidates) {
                let explanation = parseExplanation(from: text)
                await MainActor.run { self.lastExplanation = explanation }
                return (move, explanation)
            }
            #endif
        } catch {
            // Fall through to fallback below.
        }

        // Fallback: model's response didn't contain a valid move.
        await MainActor.run {
            self.lastExplanation = "Couldn't parse the AI's pick — playing the network's top choice."
        }
        return (candidates[0].move, "Fallback to search best.")
    }

    // MARK: - Prompt building

    private func buildPrompt(game: ChessGame,
                             candidates: [ForesightSearch.Candidate],
                             foresightMoves: Int) -> String {
        let side = game.sideToMove == .white ? "White" : "Black"

        var lines: [String] = []
        lines.append("You are playing chess as \(side).")
        lines.append("Position (FEN): \(game.toFEN())")
        lines.append("")
        lines.append("Your chess knowledge network evaluated these candidate moves")
        lines.append("(score: positive favors White, negative favors Black):")
        lines.append("")

        // Top 5 candidates with evals and principal variations.
        for (i, c) in candidates.prefix(5).enumerated() {
            let eval = String(format: "%+.2f", c.value)
            let lineStr = c.line.prefix(foresightMoves * 2 + 1)
                .map { $0.uci }.joined(separator: " ")
            lines.append("\(i + 1). \(c.move.uci) (eval \(eval)) — line: \(lineStr)")
        }

        lines.append("")
        lines.append("The evals come from a neural network trained on real games;")
        lines.append("the lines show \(foresightMoves) moves of foresight each.")
        lines.append("Pick the strongest move. Consider tactics, king safety, and")
        lines.append("whether the eval trend favors your side.")
        lines.append("")
        lines.append("Reply in exactly this format:")
        lines.append("MOVE: <uci, e.g. e2e4 or e7e8q>")
        lines.append("WHY: <one or two sentences explaining the choice>")

        return lines.joined(separator: "\n")
    }

    // MARK: - Response parsing

    private func parseMove(from text: String,
                           candidates: [ForesightSearch.Candidate]) -> Move? {
        // Look for "MOVE: <uci>" pattern.
        let pattern = #"MOVE:\s*([a-h][1-8][a-h][1-8][qrbn]?)"""#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              let uciRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let uci = String(text[uciRange]).lowercased()
        return candidates.first { $0.move.uci.lowercased() == uci }?.move
    }

    private func parseExplanation(from text: String) -> String {
        let pattern = #"WHY:\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              let whyRange = Range(match.range(at: 1), in: text) else {
            return "The model chose a move but didn't explain why."
        }
        return String(text[whyRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300).description
    }
}
