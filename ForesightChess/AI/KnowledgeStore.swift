import Foundation

/// Persists the KnowledgeNet weights to disk.
///
/// Unlike Adaptive Chess (per-profile networks), Foresight Chess has a single
/// shared knowledge network that improves over every game played on the device.
final class KnowledgeStore: ObservableObject {

    static let shared = KnowledgeStore()

    @Published private(set) var weights: NetworkWeights?

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent("foresight-knowledge.json")
    }

    private init() {
        load()
    }

    /// Load weights from disk, or nil if none saved yet.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let w = try? JSONDecoder().decode(NetworkWeights.self, from: data),
              w.isValid else {
            weights = nil
            return
        }
        weights = w
    }

    /// Save weights to disk.
    func save(_ w: NetworkWeights) {
        guard let data = try? JSONEncoder().encode(w) else { return }
        try? data.write(to: fileURL, options: .atomic)
        DispatchQueue.main.async { self.weights = w }
    }

    /// Fresh network (random weights) for a new knowledge base.
    func freshNetwork() -> KnowledgeNet {
        KnowledgeNet()
    }

    /// Current network: loaded weights, or fresh if none.
    func currentNetwork() -> KnowledgeNet {
        if let w = weights, let net = KnowledgeNet(weights: w) {
            return net
        }
        return KnowledgeNet()
    }

    /// Reset knowledge (fresh random weights).
    func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.main.async { self.weights = nil }
    }
}

/// Flat weight storage, matching the KnowledgeNet architecture.
struct NetworkWeights: Codable {
    var w1: [Float]; var b1: [Float]
    var w2: [Float]; var b2: [Float]
    var w3: [Float]; var b3: [Float]
    var w4: [Float]; var b4: [Float]
    var w5: [Float]; var b5: [Float]
    var w6: [Float]; var b6: [Float]

    static let w1Count = 911 * 512
    static let b1Count = 512
    static let w2Count = 512 * 256
    static let b2Count = 256
    static let w3Count = 256 * 128
    static let b3Count = 128
    static let w4Count = 128 * 64
    static let b4Count = 64
    static let w5Count = 64 * 32
    static let b5Count = 32
    static let w6Count = 32 * 3
    static let b6Count = 3

    var isValid: Bool {
        w1.count == Self.w1Count && b1.count == Self.b1Count &&
        w2.count == Self.w2Count && b2.count == Self.b2Count &&
        w3.count == Self.w3Count && b3.count == Self.b3Count &&
        w4.count == Self.w4Count && b4.count == Self.b4Count &&
        w5.count == Self.w5Count && b5.count == Self.b5Count &&
        w6.count == Self.w6Count && b6.count == Self.b6Count
    }
}
