import SwiftUI

@main
struct ForesightChessApp: App {
    init() {
        // Start Stockfish on launch. Downloads both NNUE models
        // (~75MB total) on first launch.
        StockfishEngine.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            GameView()
        }
    }
}
