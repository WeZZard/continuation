// The aggregation point of the fleet. Each node's store.db stays the single
// source of truth for its own queue; this object holds live *views* of the
// N truths plus a labeled last-seen cache for offline nodes. The unified
// list is computed, never stored.

import Combine
import Foundation
import SystemConfiguration

public enum NodeSource: String, Codable, Sendable {
    case bonjour
    case manual
}

public struct NodeState: Identifiable, Hashable {
    public let key: String
    public var source: NodeSource
    public var url: URL
    public var displayName: String
    public var info: NodeInfo?
    public var queue: QueueSnapshot?
    public var online: Bool = false
    public var lastSeen: Date?
    public var lastEventID: Int = 0
    /// Excluded from the fleet (views, aggregation, polling) while the
    /// row stays visible in Settings — the reversible form of removal
    /// for discovered nodes, which re-appear if merely removed.
    public var excluded: Bool = false

    public var id: String { key }
    public var pendingCount: Int {
        guard let queue else { return 0 }
        return queue.due.count + queue.scheduled.count + queue.attention.count
    }

    /// This machine — reached over loopback, any of its own interface
    /// addresses, or its own mDNS hostname (a discovered face resolves to
    /// `<host>.local`). Pinned first in the fleet, labeled "This Mac".
    public var isLocal: Bool {
        var host = (url.host ?? "").components(separatedBy: "%").first ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
            || LocalAddresses.all.contains(host)
            || LocalAddresses.hostnames.contains(host.lowercased())
    }
}

/// Every numeric address this machine answers on, for deciding whether a
/// discovered node is this Mac.
public enum LocalAddresses {
    public static let all: Set<String> = {
        var addresses: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let size = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, size, &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                addresses.insert(text.components(separatedBy: "%").first ?? text)
            }
        }
        return addresses
    }()

    /// The machine's own names, lowercased, with and without `.local`.
    /// The Bonjour hosttarget comes from the LocalHostName, which need
    /// not match gethostname — both are collected.
    public static let hostnames: Set<String> = {
        var names: Set<String> = []
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.insert(String(cString: buffer).lowercased())
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) {
            names.insert((local as String).lowercased())
        }
        for name in Host.current().names {
            names.insert(name.lowercased())
        }
        for name in names {
            names.insert(name.hasSuffix(".local")
                ? String(name.dropLast(6)) : name + ".local")
        }
        return names
    }()
}

public struct FleetEntry: Identifiable, Hashable {
    public let nodeKey: String
    public let nodeName: String
    public let nodeOnline: Bool
    public let entry: QueueEntry

    public var id: String { "\(nodeKey)|\(entry.id)" }
    public var activationDate: Date? { StoreDate.parse(entry.activation) }
}

public struct ActivityItem: Identifiable, Hashable {
    public let nodeKey: String
    public let nodeName: String
    public let event: EventRow

    public var id: String { "\(nodeKey)#\(event.id)" }
}

@MainActor
public final class FleetStore: ObservableObject {
    @Published public private(set) var nodes: [NodeState] = []
    @Published public private(set) var activity: [ActivityItem] = []

    public let discovery = BonjourDiscovery()
    private let persistence: Persistence
    private var loops: [String: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Persisted exclusions: discovered nodes cannot be removed (the
    /// next Bonjour tick would re-add them), only excluded.
    private var excludedKeys: Set<String> = []

    /// Events that change what a queue view shows; anything else is audit.
    private static let refreshingCommands: Set<String> = [
        "register", "unregister", "continue", "migrate", "tick",
        "tick.start-run", "tick.evaluate", "tick.run-settled",
    ]

    public init(persistence: Persistence = Persistence()) {
        self.persistence = persistence
        excludedKeys = persistence.loadExcludedKeys()
        for snapshot in persistence.loadSnapshots() {
            guard let url = URL(string: snapshot.urlString) else { continue }
            nodes.append(NodeState(
                key: snapshot.key,
                source: NodeSource(rawValue: snapshot.sourceRaw) ?? .manual,
                url: url, displayName: snapshot.displayName,
                info: snapshot.info, queue: snapshot.queue,
                online: false, lastSeen: snapshot.lastSeen,
                lastEventID: snapshot.lastEventID,
                excluded: excludedKeys.contains(snapshot.key)))
        }
        sortNodes()
        for node in nodes where !node.excluded { startLoop(key: node.key) }
        for manual in persistence.loadManualNodes() { upsertManual(manual) }
        discovery.$services
            .receive(on: DispatchQueue.main)
            .sink { [weak self] services in
                for service in services { self?.upsertBonjour(service) }
            }
            .store(in: &cancellables)
        discovery.start()
    }

    // ------------------------------------------------------------- fleet ops

    public func addManualNode(host: String, port: Int) {
        let manual = ManualNode(host: host, port: port)
        var saved = persistence.loadManualNodes()
        if !saved.contains(manual) {
            saved.append(manual)
            persistence.saveManualNodes(saved)
        }
        upsertManual(manual)
    }

    public func removeNode(key: String) {
        loops[key]?.cancel()
        loops[key] = nil
        nodes.removeAll { $0.key == key }
        persistence.deleteSnapshot(key: key)
        if key.hasPrefix("manual:") {
            let remaining = persistence.loadManualNodes().filter { $0.key != key }
            persistence.saveManualNodes(remaining)
        }
    }

    /// The reversible removal for discovered nodes: the row stays, the
    /// node leaves the fleet. Exclusion persists across launches.
    public func setExcluded(_ excluded: Bool, key: String) {
        if excluded {
            excludedKeys.insert(key)
        } else {
            excludedKeys.remove(key)
        }
        persistence.saveExcludedKeys(excludedKeys)
        update(key: key) { node in
            node.excluded = excluded
            if excluded { node.online = false }
        }
        if excluded {
            loops[key]?.cancel()
            loops[key] = nil
        } else {
            startLoop(key: key)
        }
    }

    public func node(key: String) -> NodeState? {
        nodes.first { $0.key == key }
    }

    public func client(key: String) -> NodeClient? {
        node(key: key).map { NodeClient(baseURL: $0.url) }
    }

    // ----------------------------------------------------------- unified view

    public var dueEntries: [FleetEntry] {
        collect(\.due).sorted {
            ($0.activationDate ?? .distantPast) < ($1.activationDate ?? .distantPast)
        }
    }

    public var scheduledEntries: [FleetEntry] {
        collect(\.scheduled).sorted {
            ($0.activationDate ?? .distantFuture) < ($1.activationDate ?? .distantFuture)
        }
    }

    /// Entries the scheduler will not act on by itself, one pile per state
    /// (`expired` / `invalid` / `paused`) — distinct sections, no umbrella.
    public func entries(state: String) -> [FleetEntry] {
        collect(\.attention)
            .filter { $0.entry.state == state }
            .sorted { $0.entry.registeredAt < $1.entry.registeredAt }
    }

    /// (state, count) for every non-empty stuck pile, in canonical order.
    public var stuckCounts: [(state: String, count: Int)] {
        ["expired", "invalid", "paused"].compactMap { state in
            let count = entries(state: state).count
            return count > 0 ? (state, count) : nil
        }
    }

    public var dueCount: Int { dueEntries.count }

    /// What the menu bar counts down to: the soonest scheduled activation,
    /// or nil when something is already due (the countdown shows "due now").
    public var nextScheduled: FleetEntry? { scheduledEntries.first }

    private func collect(_ section: KeyPath<QueueSnapshot, [QueueEntry]>) -> [FleetEntry] {
        nodes.flatMap { node -> [FleetEntry] in
            guard !node.excluded, let queue = node.queue else { return [] }
            return queue[keyPath: section].map {
                FleetEntry(nodeKey: node.key, nodeName: node.displayName,
                           nodeOnline: node.online, entry: $0)
            }
        }
    }

    /// Test seam: the merge logic is exercised directly by unit tests.
    func seed(_ node: NodeState) {
        nodes.append(node)
    }

    // ------------------------------------------------------------- node loops

    private func upsertManual(_ manual: ManualNode) {
        guard let url = manual.url else { return }
        upsert(key: manual.key, source: .manual, url: url,
               fallbackName: manual.host)
    }

    func upsertBonjour(_ service: DiscoveredService) {
        let key = "bonjour:\(service.name)"
        // Discovery outranks a by-address entry for the same node id: the
        // advertisement is live identity, the address entry only its
        // fallback. Displacing leaves manual-nodes.json untouched, so the
        // fallback returns at the next launch if the advertisement is gone.
        if let id = service.nodeID {
            for twin in nodes where twin.key != key && twin.info?.nodeID == id {
                displace(key: twin.key)
            }
        }
        upsert(key: key, source: .bonjour,
               url: service.url, fallbackName: service.name)
    }

    /// Remove a row without touching persisted manual addresses.
    func displace(key: String) {
        loops[key]?.cancel()
        loops[key] = nil
        nodes.removeAll { $0.key == key }
        persistence.deleteSnapshot(key: key)
    }

    private func upsert(key: String, source: NodeSource, url: URL,
                        fallbackName: String) {
        if let index = nodes.firstIndex(where: { $0.key == key }) {
            if nodes[index].url != url, !nodes[index].excluded {
                nodes[index].url = url
                restartLoop(key: key)
            }
            return
        }
        nodes.append(NodeState(key: key, source: source, url: url,
                               displayName: fallbackName,
                               excluded: excludedKeys.contains(key)))
        sortNodes()
        if !excludedKeys.contains(key) { startLoop(key: key) }
    }

    private func sortNodes() {
        nodes.sort {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.displayName < $1.displayName
        }
    }

    private func restartLoop(key: String) {
        loops[key]?.cancel()
        loops[key] = nil
        startLoop(key: key)
    }

    private func startLoop(key: String) {
        guard loops[key] == nil else { return }
        loops[key] = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.runLoopOnce(key: key)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func runLoopOnce(key: String) async {
        guard let state = node(key: key) else { return }
        let client = NodeClient(baseURL: state.url)
        do {
            let info = try await client.node()
            let queue = try await client.queue()
            update(key: key) { node in
                node.online = true
                node.lastSeen = Date()
                node.info = info
                node.queue = queue
                node.displayName = info.displayName ?? info.hostname
            }
            sortNodes()
            dedupe(nodeID: info.nodeID, keep: key)
            saveSnapshot(key: key)
            var cursor = node(key: key)?.lastEventID ?? 0
            if cursor == 0 {
                // First contact: seed activity with recent history instead
                // of replaying the store's whole audit log.
                let recent = try await client.log(limit: 50)
                cursor = recent.first?.id ?? 0
                ingest(recent.reversed(), key: key)
            }
            for try await event in client.events(after: cursor) {
                update(key: key) { node in
                    node.lastEventID = event.id
                    node.lastSeen = Date()
                }
                ingest([event], key: key)
                if Self.refreshingCommands.contains(event.cmd) {
                    let queue = try await client.queue()
                    let info = try? await client.node()
                    update(key: key) { node in
                        node.queue = queue
                        if let info { node.info = info }
                    }
                    saveSnapshot(key: key)
                }
            }
        } catch {
            update(key: key) { node in node.online = false }
            saveSnapshot(key: key)
        }
    }

    func dedupe(nodeID: String, keep key: String) {
        // The same node can surface twice (Bonjour + manual, or an old
        // Bonjour name). The discovered face wins; the by-address entry is
        // its fallback and is displaced, never deleted from persistence.
        let duplicates = nodes.filter {
            $0.key != key && $0.info?.nodeID == nodeID
        }
        guard let mine = node(key: key) else { return }
        for duplicate in duplicates {
            if mine.source == .manual && duplicate.source == .bonjour {
                displace(key: key)
                return
            }
            displace(key: duplicate.key)
        }
    }

    private func update(key: String, _ mutate: (inout NodeState) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.key == key }) else { return }
        mutate(&nodes[index])
    }

    private func ingest(_ events: [EventRow], key: String) {
        guard let state = node(key: key) else { return }
        let items = events.map {
            ActivityItem(nodeKey: key, nodeName: state.displayName, event: $0)
        }
        activity.insert(contentsOf: items.reversed(), at: 0)
        if activity.count > 500 {
            activity.removeLast(activity.count - 500)
        }
    }

    private func saveSnapshot(key: String) {
        guard let state = node(key: key) else { return }
        persistence.saveSnapshot(NodeSnapshot(
            key: state.key, sourceRaw: state.source.rawValue,
            urlString: state.url.absoluteString,
            displayName: state.displayName, info: state.info,
            queue: state.queue, lastSeen: state.lastSeen,
            lastEventID: state.lastEventID))
    }
}
