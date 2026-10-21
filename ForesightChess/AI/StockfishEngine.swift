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
    /// Downloads both NNUE models on first launch, then initializes UCI.
    func start() {
        guard !started else { return }
        started = true

        queue.async { [weak self] in
            guard let self = self else { return }

            // 1. Ensure both NNUE models are downloaded.
            self.ensureModelsDownloaded()

            // 2. Start the engine thread.
            sf_init()

            // 3. Wait for it to come up.
            var attempts = 0
            while sf_is_running() == 0 && attempts < 100 {
                Thread.sleep(forTimeInterval: 0.05)
                attempts += 1
            }

            // 4. UCI handshake.
            _ = self.sendAndWait("uci\n", expect: "uciok", timeout: 10)
            _ = self.sendAndWait("isready\n", expect: "readyok", timeout: 10)

            // 5. Point to downloaded NNUEs if we have them.
            if self.modelDownloaded {
                let bigPath = self.nnuePath(self.nnueBigFileName)
                let smallPath = self.nnuePath(self.nnueSmallFileName)
                _ = self.sendAndWait(
                    "setoption name EvalFile value \(bigPath)\n",
                    expect: "readyok", timeout: 5)
                _ = self.sendAndWait(
                    "setoption name EvalFileSmall value \(smallPath)\n",
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

    private func downloadFile(from urlString: String, to fileName: String,
                              expectedSize: Int) -> Bool {
        let path = nnuePath(fileName)
        // Skip if already valid.
        if isValidNNUE(at: path, expectedSize: expectedSize) { return true }

        guard let url = URL(string: urlString) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
            defer { semaphore.signal() }
            guard let tmpURL = tmpURL, error == nil else { return }
            let dest = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                success = self.isValidNNUE(at: path, expectedSize: expectedSize)
            } catch {
                success = false
            }
        }
        task.resume()
        semaphore.wait()
        return success
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
    /// - Parameter depth: search depth (the "foresight" setting).
    /// - Returns: UCI move string (e.g. "e2e4"), or nil on failure.
    func bestMove(fen: String, depth: Int) -> String? {
        guard sf_is_running() != 0 else { return nil }

        sf_send("position fen \(fen)\n")
        sf_send("go depth \(depth)\n")

        let deadline = Date().addingTimeInterval(Double(depth) * 2 + 10)
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
        sf_send("go depth \(depth)\n")

        let deadline = Date().addingTimeInterval(Double(depth) * 2 + 10)
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
