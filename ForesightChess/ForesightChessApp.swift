import SwiftUI

@main
struct ForesightChessApp: App {
    @ObservedObject private var engine = StockfishEngine.shared
    @State private var downloadComplete = false

    init() {
        // Start Stockfish on launch. If NNUE models aren't cached,
        // the download screen appears (see body).
        StockfishEngine.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            if engine.needsDownload && !downloadComplete {
                ModelDownloadView {
                    downloadComplete = true
                }
            } else {
                GameView()
            }
        }
    }
}
