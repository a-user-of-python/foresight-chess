import Foundation

/// Swift interface to the embedded Stockfish engine.
///
/// Stockfish runs its UCI loop on a background thread (see sf_wrapper).
/// This class sends UCI commands and parses responses.
///
/// The NNUE network file downloads on first launch (keeps the IPA small).
/// Until it's downloaded, Stockfish uses its built-in default network.
final class StockfishEngine: ObservableObject {

    static let shared = StockfishEngine()

    @Published var isReady = false
    @Published var modelDownloaded = false
    @Published var downloadProgress: Double = 0
    @Published var downloadFailed = false
    @Published var needsDownload = false  // true on first launch

    /// NNUE network files in Documents (Stockfish 17 needs both).
    private let nnueBigFileName = "nn-1111cefa1111.nnue"    // ~71MB
    private let nnueSmallFileName = "nn-37f18f62d772.nnue"  // ~3.4MB

    /// Verified download URLs (data.stockfishchess.org).
    private let nnueBigURL = "https://data.stockfishchess.org/nn/nn-1111cefa1111.nnue"
    private let nnueSmallURL = "https://data.stockfishchess.org/nn/nn-37f18f62d772.nnue"

    private let queue = DispatchQueue(label: "stockfish.uci", qos: .userInitiated)
    private var started = false

    private init() {}

    // MARK: - Startup

    /// Start the engine. Call once at app launch.
    /// If models aren't downloaded, sets needsDownload = true so the UI
    /// can show the download screen. Otherwise starts immediately.
    func start() {
        guard !started else { return }
        started = true

        // Check if we need the download UI.
        let bigOK = isValidNNUE(at: nnuePath(nnueBigFileName), expectedSize: 74874478)
        let smallOK = isValidNNUE(at: nnuePath(nnueSmallFileName), expectedSize: 3519630)

        if bigOK && smallOK {
            DispatchQueue.main.async { self.modelDownloaded = true }
            launchEngine()
        } else {
            DispatchQueue.main.async { self.needsDownload = true }
        }
    }

    /// Called from the download UI. Downloads models with progress,
    /// then launches the engine. On failure sets downloadFailed = true.
    func retryDownload(onComplete: @escaping () -> Void) {
        DispatchQueue.main.async { self.downloadFailed = false }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.downloadWithProgress()
            DispatchQueue.main.async {
                if self.modelDownloaded {
                    self.needsDownload = false
                    onComplete()
                } else {
                    self.downloadFailed = true
                }
            }
        }
    }

    /// Download both models with real byte-level progress.
    private func downloadWithProgress() {
        let bigOK = downloadFileWithProgress(from: nnueBigURL, to: nnueBigFileName,
                                             expectedSize: 74874478, weight: 0.95)
        let smallOK = downloadFileWithProgress(from: nnueSmallURL, to: nnueSmallFileName,
                                               expectedSize: 3519630, weight: 0.05)
        let done = bigOK && smallOK
        DispatchQueue.main.async {
            self.modelDownloaded = done
            self.downloadProgress = done ? 1.0 : self.downloadProgress
            self.downloadFailed = !done
        }
        if done {
            launchEngine()
        }
    }

    private func launchEngine() {
        queue.async { [weak self] in
            guard let self = self else { return }
            sf_init()
            var attempts = 0
            while sf_is_running() == 0 && attempts < 100 {
                Thread.sleep(forTimeInterval: 0.05)
                attempts += 1
            }
            _ = self.sendAndWait("uci\n", expect: "uciok", timeout: 10)
            _ = self.sendAndWait("isready\n", expect: "readyok", timeout: 10)
            if self.modelDownloaded {
                let bigPath = self.nnuePath(self.nnueBigFileName)
                let smallPath = self.nnuePath(self.nnueSmallFileName)
                _ = self.sendAndWait("setoption name EvalFile value \(bigPath)\n",
                                     expect: "readyok", timeout: 5)
                _ = self.sendAndWait("setoption name EvalFileSmall value \(smallPath)\n",
                                     expect: "readyok", timeout: 5)
                _ = self.sendAndWait("isready\n", expect: "readyok", timeout: 10)
            }
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    // MARK: - Model download

    private func nnuePath(_ fileName: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName).path
    }

    /// NNUE magic bytes (little-endian) for integrity check.
    private let nnueMagic: UInt32 = 0x7AF32F20

    private func isValidNNUE(at path: String, expectedSize: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size == expectedSize,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        return magic == nnueMagic
    }

    private func downloadFileWithProgress(from urlString: String, to fileName: String,
                                          expectedSize: Int, weight: Double) -> Bool {
        let path = nnuePath(fileName)
        if isValidNNUE(at: path, expectedSize: expectedSize) { return true }

        guard let url = URL(string: urlString) else { return false }

        let baseProgress = downloadProgress
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        // Pure-delegate download: progress via didWriteData, completion via didFinishDownloadingTo.
        // (Don't use the completion-handler variant — it suppresses delegate progress callbacks.)
        let delegate = DownloadDelegate()
        delegate.onProgress = { [weak self] received, expected in
            guard expected > 0 else { return }
            let fileProgress = Double(received) / Double(expected)
            let total = baseProgress + fileProgress * weight
            DispatchQueue.main.async { self?.downloadProgress = min(total, 1.0) }
        }
        delegate.onComplete = { tmpURL in
            defer { semaphore.signal() }
            guard let tmpURL = tmpURL else { return }
            let dest = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                success = self.isValidNNUE(at: path, expectedSize: expectedSize)
            } catch {
                success = false
            }
        }
        // Hold the session strongly for the duration of the download.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.downloadTask(with: url).resume()
        semaphore.wait()
        session.invalidateAndCancel()
        return success
    }

    /// URLSession delegate for download progress + completion.
    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var session: URLSession?  // strong ref keeps session alive during download
        var onProgress: ((Int64, Int64) -> Void)?
        var onComplete: ((URL?) -> Void)?
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            onComplete?(location)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if error != nil { onComplete?(nil) }
        }
    }

    // Legacy simple download (kept for reference, not used).
    private func downloadFile(from urlString: String, to fileName: String,
                              expectedSize: Int) -> Bool {
        return downloadFileWithProgress(from: urlString, to: fileName,
                                        expectedSize: expectedSize, weight: 1.0)
    }

    private func ensureModelsDownloaded() {
        // Big net (~71MB) + small net (~3.4MB).
        let bigOK = downloadFile(from: nnueBigURL, to: nnueBigFileName,
                                 expectedSize: 74874478)
        let smallOK = downloadFile(from: nnueSmallURL, to: nnueSmallFileName,
                                   expectedSize: 3519630)

        let done = bigOK && smallOK
        DispatchQueue.main.async {
            self.modelDownloaded = done
            self.downloadProgress = done ? 1.0 : 0
        }
    }

    // MARK: - UCI

    /// Send a command and wait for a line containing `expect`.
    /// Returns the full response text.
    @discardableResult
    private func sendAndWait(_ cmd: String, expect: String,
                             timeout: Double) -> String {
        sf_send(cmd)
        let deadline = Date().addingTimeInterval(timeout)
        var output = ""
        var buf = [CChar](repeating: 0, count: 8192)

        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                sf_read(ptr.baseAddress!, Int32(ptr.count), 200)
            }
            if n > 0 {
                let chunk = buf.withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                output += chunk
                if output.contains(expect) { break }
            }
        }
        return output
    }

    /// Get Stockfish's best move for a FEN position.
    /// - Parameter depth: the "foresight" setting (1-3), mapped to a time budget.
    /// - Returns: UCI move string (e.g. "e2e4"), or nil on failure.
    func bestMove(fen: String, depth: Int) -> String? {
        guard sf_is_running() != 0 else {
            print("[Stockfish] bestMove: engine not running")
            return nil
        }

        // Map foresight to a time budget — depth-based search is unpredictable
        // on mobile CPUs. 1s / 3s / 8s keeps moves snappy.
        let movetime = [1: 1000, 2: 3000, 3: 8000][depth] ?? 2000

        // Stop any stuck search first, then set up the position.
        sf_send("stop\n")
        Thread.sleep(forTimeInterval: 0.1)
        sf_send("position fen \(fen)\n")
        sf_send("go movetime \(movetime)\n")

        let deadline = Date().addingTimeInterval(Double(movetime) / 1000.0 + 10)
        var buf = [CChar](repeating: 0, count: 8192)
        var output = ""

        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                sf_read(ptr.baseAddress!, Int32(ptr.count), 500)
            }
            if n > 0 {
                let chunk = buf.withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                output += chunk
                if let bm = parseBestMove(from: output) {
                    return bm
                }
            }
        }
        return parseBestMove(from: output)
    }

    /// Get Stockfish's static evaluation of a FEN position (in centipawns,
    /// from White's perspective). Used for KnowledgeNet distillation.
    func evaluate(fen: String, depth: Int = 12) -> Float? {
        guard sf_is_running() != 0 else { return nil }

        sf_send("position fen \(fen)\n")
        sf_send("go movetime 1500\n")

        let deadline = Date().addingTimeInterval(12)
        var buf = [CChar](repeating: 0, count: 8192)
        var output = ""
        var lastScore: Float?

        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                sf_read(ptr.baseAddress!, Int32(ptr.count), 500)
            }
            if n > 0 {
                let chunk = buf.withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                output += chunk
                if let s = parseScore(from: output) {
                    lastScore = s
                }
                if output.contains("bestmove") { break }
            }
        }
        return lastScore ?? parseScore(from: output)
    }

    // MARK: - Parsing

    private func parseBestMove(from output: String) -> String? {
        // "bestmove e2e4 ponder e7e5"
        let pattern = #"bestmove\s+([a-h][1-8][a-h][1-8][qrbn]?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output,
                                           range: NSRange(output.startIndex..., in: output)),
              let r = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[r])
    }

    /// Parse the latest "score cp <n>" from search info.
    /// Converts centipawns to [-1, 1] from White's perspective.
    private func parseScore(from output: String) -> Float? {
        // "info depth 12 ... score cp 35 ..."
        // Note: score is from side-to-move's perspective in UCI.
        // We need FEN to know side to move — simplified: parse last occurrence.
        let pattern = #"score\s+cp\s+(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: output,
                                    range: NSRange(output.startIndex..., in: output))
        guard let last = matches.last,
              let r = Range(last.range(at: 1), in: output),
              let cp = Float(output[r]) else {
            return nil
        }
        // Tanh normalization: 400cp ≈ 0.76, 1000cp ≈ 0.96
        return tanh(cp / 400.0)
    }
}
