import Foundation
import Network
import XCTest
@testable import ContinuationsKit

/// End-to-end against the real mDNS stack: advertise a service with a
/// nodeid TXT record, then require BonjourDiscovery to browse, read the
/// TXT, and resolve host:port — the exact pipeline the app runs.
@MainActor
final class DiscoveryTests: XCTestCase {

    func testBrowseReadsTXTAndResolves() async throws {
        let name = "test-\(UUID().uuidString.prefix(8))"
        var txt = NWTXTRecord()
        txt["nodeid"] = "TESTNODE123"
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(
            name: name, type: "_agentic-cont-test._tcp", txtRecord: txt.data)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        defer { listener.cancel() }

        let discovery = BonjourDiscovery(type: "_agentic-cont-test._tcp")
        discovery.start()
        defer { discovery.stop() }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let found = discovery.services.first(where: { $0.name == name }) {
                XCTAssertEqual(found.nodeID, "TESTNODE123")
                XCTAssertEqual(found.url.port.map(UInt16.init),
                               listener.port?.rawValue)
                XCTAssertEqual(found.url.scheme, "http")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("advertised service was not discovered and resolved in time")
    }
}
