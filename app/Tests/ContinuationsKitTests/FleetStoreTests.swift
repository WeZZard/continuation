import Foundation
import XCTest
@testable import ContinuationsKit

@MainActor
final class FleetStoreTests: XCTestCase {

    private func makeStore() -> FleetStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-test-\(UUID().uuidString)")
        return FleetStore(persistence: Persistence(directory: dir))
    }

    private func info(nodeID: String) -> NodeInfo {
        NodeInfo(proto: "v1", nodeID: nodeID, hostname: "h",
                 displayName: nil, version: "0", schemaVersions: [2],
                 now: "", startedAt: "", lastTickAt: nil,
                 tickAgentLoaded: nil,
                 queueCounts: .init(due: 0, scheduled: 0, attention: 0))
    }

    private func manualNode(key: String = "manual:1.2.3.4:7787",
                            nodeID: String) -> NodeState {
        NodeState(key: key, source: .manual,
                  url: URL(string: "http://1.2.3.4:7787")!,
                  displayName: "m", info: info(nodeID: nodeID), queue: nil)
    }

    func testDiscoveredDisplacesManualTwin() {
        let store = makeStore()
        store.seed(manualNode(nodeID: "X"))
        store.upsertBonjour(DiscoveredService(
            name: "m", url: URL(string: "http://m.local:7787")!, nodeID: "X"))
        XCTAssertEqual(store.nodes.map(\.source), [.bonjour])
    }

    func testDifferentNodeIDsCoexist() {
        let store = makeStore()
        store.seed(manualNode(nodeID: "X"))
        store.upsertBonjour(DiscoveredService(
            name: "other", url: URL(string: "http://o.local:7787")!, nodeID: "Y"))
        XCTAssertEqual(store.nodes.count, 2)
    }

    func testExclusionPersistsAcrossStoresAndBonjourTicks() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-test-\(UUID().uuidString)")
        let persistence = Persistence(directory: dir)
        let service = DiscoveredService(
            name: "m", url: URL(string: "http://m.local:7787")!, nodeID: "X")

        let store = FleetStore(persistence: persistence)
        store.upsertBonjour(service)
        store.setExcluded(true, key: "bonjour:m")
        XCTAssertEqual(store.nodes.map(\.excluded), [true])
        store.upsertBonjour(service)   // the standing services list re-fires
        XCTAssertEqual(store.nodes.count, 1)

        // A fresh store (new launch) re-applies the exclusion at upsert.
        let relaunched = FleetStore(persistence: persistence)
        relaunched.upsertBonjour(service)
        XCTAssertEqual(relaunched.nodes.map(\.excluded), [true])

        // Excluded nodes contribute nothing to the fleet aggregation.
        XCTAssertTrue(relaunched.dueEntries.isEmpty)

        // The toggle reverses.
        relaunched.setExcluded(false, key: "bonjour:m")
        XCTAssertEqual(relaunched.nodes.map(\.excluded), [false])
    }

    func testPollDedupePrefersDiscovered() {
        let store = makeStore()
        store.seed(manualNode(nodeID: "X"))
        var bonjour = NodeState(key: "bonjour:m", source: .bonjour,
                                url: URL(string: "http://m.local:7787")!,
                                displayName: "m", info: info(nodeID: "X"),
                                queue: nil)
        bonjour.online = true
        store.seed(bonjour)
        // The manual node's poll returns; the discovered twin must win.
        store.dedupe(nodeID: "X", keep: "manual:1.2.3.4:7787")
        XCTAssertEqual(store.nodes.map(\.source), [.bonjour])
    }

    func testDisplacementLeavesManualPersistenceAlone() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-test-\(UUID().uuidString)")
        let persistence = Persistence(directory: dir)
        persistence.saveManualNodes([ManualNode(host: "1.2.3.4", port: 7787)])
        let store = FleetStore(persistence: persistence)
        XCTAssertEqual(store.nodes.count, 1)
        // Displace the manual row the way a discovered twin would.
        store.displace(key: "manual:1.2.3.4:7787")
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertEqual(persistence.loadManualNodes().count, 1)
    }
}
