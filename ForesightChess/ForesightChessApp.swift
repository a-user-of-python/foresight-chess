import SwiftUI

@main
struct ForesightChessApp: App {
    init() {
        // Start Stockfish on launch. The NNUE model URL is set once
        // the research subagent returns it; empty string = embedded net.
        // TODO: Set the real NNUE download URL here.
        StockfishEngine.shared.start(nnueURL: "")
    }

    var body: some Scene {
        WindowGroup {
            GameView()
        }
    }
}
