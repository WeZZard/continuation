// Bonjour discovery of `_agentic-cont._tcp` nodes on the LAN.
// Each browse result resolves to host:port by opening a throwaway TCP
// connection and reading the path's remote endpoint — the standard way to
// turn an NWEndpoint.service into something URLSession can dial.

@preconcurrency import Network
import Foundation

public struct DiscoveredService: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public var id: String { name }
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
            for: .bonjour(type: "_agentic-cont._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
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
        var names: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            names.insert(name)
            if !resolving.contains(name),
               !services.contains(where: { $0.name == name }) {
                resolving.insert(name)
                resolve(result.endpoint, name: name)
            }
        }
        services.removeAll { !names.contains($0.name) }
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                connection.cancel()
                Task { @MainActor in
                    self?.resolving.remove(name)
                    guard let self,
                          case .hostPort(let host, let port) = remote,
                          let url = Self.url(host: host, port: port) else { return }
                    if !self.services.contains(where: { $0.name == name }) {
                        self.services.append(DiscoveredService(name: name, url: url))
                        self.services.sort { $0.name < $1.name }
                    }
                }
            case .failed, .cancelled:
                Task { @MainActor in self?.resolving.remove(name) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let text: String
        switch host {
        case .ipv4(let address):
            text = "\(address)"
        case .ipv6(let address):
            let raw = "\(address)".replacingOccurrences(of: "%", with: "%25")
            text = "[\(raw)]"
        case .name(let name, _):
            text = name
        @unknown default:
            return nil
        }
        return URL(string: "http://\(text):\(port.rawValue)")
    }
}
