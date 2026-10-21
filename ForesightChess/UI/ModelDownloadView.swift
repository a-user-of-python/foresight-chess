import SwiftUI

/// First-launch model download screen.
///
/// Shows large-text progress while the Stockfish NNUE networks download
/// (~75MB total). Handles failure with a retry button — no reinstall needed.
struct ModelDownloadView: View {
    @ObservedObject var engine = StockfishEngine.shared
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Downloading Chess Brain")
                .font(.largeTitle)
                .bold()
                .multilineTextAlignment(.center)

            Text("First launch needs the Stockfish neural network (~75 MB). " +
                 "This happens once — it's cached after that.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if engine.downloadFailed {
                Text("Download failed. Check your connection and try again.")
                    .font(.title2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Retry Download") {
                    engine.retryDownload(onComplete: onComplete)
                }
                .font(.title2)
                .buttonStyle(.borderedProminent)
                .padding()
            } else {
                ProgressView(value: engine.downloadProgress)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 3)
                    .padding(.horizontal, 40)

                Text("\(Int(engine.downloadProgress * 100))%")
                    .font(.system(size: 48, weight: .bold))
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding()
        .onAppear {
            // Kick off the download when the screen appears.
            engine.retryDownload(onComplete: onComplete)
        }
    }
}
