// Disk cache: manual node list + per-node last-seen snapshots.
// A snapshot is a cache of truth for offline display ("as of ..."), never
// written back to any node and never authoritative.

import Foundation

public struct ManualNode: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var url: URL? { URL(string: "http://\(host):\(port)") }
    public var key: String { "manual:\(host):\(port)" }
}

public struct NodeSnapshot: Codable, Sendable {
    public var key: String
    public var sourceRaw: String
    public var urlString: String
    public var displayName: String
    public var info: NodeInfo?
    public var queue: QueueSnapshot?
    public var lastSeen: Date?
    public var lastEventID: Int
}

public struct Persistence: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                AppSupportUmbrella.directoryName(base: "Continuations"),
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.directory.appendingPathComponent("nodes", isDirectory: true),
            withIntermediateDirectories: true)
    }

    private var manualURL: URL { directory.appendingPathComponent("manual-nodes.json") }

    private func snapshotURL(_ key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("nodes", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    public func loadManualNodes() -> [ManualNode] {
        guard let data = try? Data(contentsOf: manualURL) else { return [] }
        return (try? JSONDecoder().decode([ManualNode].self, from: data)) ?? []
    }

    private var excludedURL: URL { directory.appendingPathComponent("excluded-nodes.json") }

    public func loadExcludedKeys() -> Set<String> {
        guard let data = try? Data(contentsOf: excludedURL) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    public func saveExcludedKeys(_ keys: Set<String>) {
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return }
        try? data.write(to: excludedURL, options: .atomic)
    }

    public func saveManualNodes(_ nodes: [ManualNode]) {
        guard let data = try? JSONEncoder().encode(nodes) else { return }
        try? data.write(to: manualURL, options: .atomic)
    }

    public func loadSnapshots() -> [NodeSnapshot] {
        let dir = directory.appendingPathComponent("nodes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(NodeSnapshot.self, from: data)
        }
    }

    public func saveSnapshot(_ snapshot: NodeSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL(snapshot.key), options: .atomic)
    }

    public func deleteSnapshot(key: String) {
        try? FileManager.default.removeItem(at: snapshotURL(key))
    }
}
