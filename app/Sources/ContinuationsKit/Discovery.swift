// Bonjour discovery of `_agentic-cont._tcp` nodes on the LAN.
// Browsing uses NWBrowser (with TXT records — the advertisement carries
// the node id). Resolution uses DNSServiceResolve, NOT an NWConnection:
// inside the bundled app the connect-to-service leg never leaves
// .preparing under any signing or launch mode (observed 2026-07-25),
// while the mDNSResponder channel — the one browsing rides — works
// everywhere. DNSServiceResolve stays on that channel and yields
// hosttarget:port with no connection at all.

@preconcurrency import Network
import Foundation
import dnssd

public struct DiscoveredService: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    /// From the advertisement's TXT record (`nodeid=<ULID>`): identity
    /// without polling, so duplicates are refusable before they appear.
    public let nodeID: String?
    public var id: String { name }
}

/// Diagnostic trail for the discovery pipeline — the debug loop reads it
/// from /tmp/continuation-debug.log (NSLog lands on stderr).
func discoveryLog(_ message: String) {
    NSLog("[discovery] %@", message)
}

@MainActor
public final class BonjourDiscovery: ObservableObject {
    @Published public private(set) var services: [DiscoveredService] = []

    private var browser: NWBrowser?
    private var resolving: Set<String> = []

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_agentic-cont._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
        browser.stateUpdateHandler = { state in
            discoveryLog("browser state: \(String(describing: state))")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.sync(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        services = []
        resolving = []
    }

    private func sync(_ results: Set<NWBrowser.Result>) {
        discoveryLog("browse results: \(results.count)")
        var names: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            names.insert(name)
            var nodeID: String?
            if case .bonjour(let txt) = result.metadata {
                nodeID = txt["nodeid"]
            }
            discoveryLog("service \(name) nodeid=\(nodeID ?? "nil")")
            if !resolving.contains(name),
               !services.contains(where: { $0.name == name }) {
                resolving.insert(name)
                resolve(result.endpoint, name: name, nodeID: nodeID)
            }
        }
        services.removeAll { !names.contains($0.name) }
    }

    private func resolve(_ endpoint: NWEndpoint, name: String, nodeID: String?) {
        ServiceResolver.resolve(name: name) { [weak self] resolved in
            Task { @MainActor in
                guard let self else { return }
                self.resolving.remove(name)
                guard let resolved,
                      let url = URL(string: "http://\(resolved.host):\(resolved.port)")
                else {
                    discoveryLog("resolve failed \(name)")
                    return
                }
                discoveryLog("resolved \(name) -> \(url)")
                if !self.services.contains(where: { $0.name == name }) {
                    self.services.append(
                        DiscoveredService(name: name, url: url, nodeID: nodeID))
                    self.services.sort { $0.name < $1.name }
                }
            }
        }
    }
}

/// One-shot DNS-SD resolution of a `_agentic-cont._tcp` instance to
/// hosttarget + port. The callback fires exactly once — first answer or
/// the timeout — and the service ref is torn down with it.
enum ServiceResolver {

    final class Pending {
        var ref: DNSServiceRef?
        var completed = false
        let completion: ((host: String, port: UInt16)?) -> Void

        init(completion: @escaping ((host: String, port: UInt16)?) -> Void) {
            self.completion = completion
        }

        /// Idempotent: deallocates the service ref, releases the retain
        /// the resolve call took, and reports exactly once. Everything
        /// runs on the main queue, so calls are serialized.
        func finish(_ result: (host: String, port: UInt16)?) {
            guard !completed else { return }
            completed = true
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            completion(result)
            Unmanaged.passUnretained(self).release()
        }
    }

    static func resolve(type: String = "_agentic-cont._tcp",
                        domain: String = "local.",
                        name: String,
                        timeout: TimeInterval = 5,
                        completion: @escaping ((host: String, port: UInt16)?) -> Void) {
        let pending = Pending(completion: completion)
        let context = Unmanaged.passRetained(pending).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(
            &ref, 0, 0, name, type, domain,
            { _, _, _, errorCode, _, hosttarget, port, _, _, context in
                guard let context else { return }
                let pending = Unmanaged<Pending>.fromOpaque(context)
                    .takeUnretainedValue()
                guard errorCode == kDNSServiceErr_NoError,
                      let hosttarget else {
                    pending.finish(nil)
                    return
                }
                var host = String(cString: hosttarget)
                if host.hasSuffix(".") { host.removeLast() }
                pending.finish((host, UInt16(bigEndian: port)))
            },
            context)
        guard error == kDNSServiceErr_NoError, let serviceRef = ref else {
            Unmanaged<Pending>.fromOpaque(context).release()
            completion(nil)
            return
        }
        pending.ref = serviceRef
        DNSServiceSetDispatchQueue(serviceRef, .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            pending.finish(nil)
        }
    }
}
