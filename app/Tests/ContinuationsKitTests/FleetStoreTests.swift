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

// MARK: - Review, gathered by project

extension FleetStoreTests {

    private func session(_ ref: String, cwd: String) -> SupervisedSession {
        SupervisedSession(sessionRef: ref, agent: "claude-code", cwd: cwd,
                          source: "startup", startedAt: "2026-07-26T00:00:00Z")
    }

    private func review(_ id: Int, ref: String, cwd: String,
                        kind: String = "stopped", held: Bool = false) -> ReviewItem {
        let payload = """
            {"held": \(held)}
            """.data(using: .utf8)!
        return ReviewItem(
            id: id, sessionRef: ref, agent: "claude-code", kind: kind, cwd: cwd,
            summary: "Waiting for your next message",
            payload: try! JSONDecoder().decode(ReviewPayload.self, from: payload),
            raisedAt: "2026-07-26T00:00:00Z")
    }

    func testSessionsGatherUnderTheirProject() {
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha"),
                         session("b", cwd: "/w/beta"),
                         session("c", cwd: "/w/alpha")]
        node.reviews = [review(1, ref: "a", cwd: "/w/alpha")]
        store.seed(node)

        let groups = store.reviewGroups
        XCTAssertEqual(groups.map(\.project), ["alpha", "beta"])
        XCTAssertEqual(groups[0].rows.count, 2)
        XCTAssertEqual(groups[0].waitingCount, 1)
        // The one waiting on a human leads its project.
        XCTAssertEqual(groups[0].rows.first?.sessionRef, "a")
    }

    func testProjectsWaitingSortFirst() {
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha"),
                         session("z", cwd: "/w/zeta")]
        node.reviews = [review(1, ref: "z", cwd: "/w/zeta")]
        store.seed(node)
        XCTAssertEqual(store.reviewGroups.map(\.project), ["zeta", "alpha"])
        XCTAssertEqual(store.waitingCount, 1)
    }

    func testOnlyAHeldLocalSessionTakesAMessage() {
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha"), session("b", cwd: "/w/alpha")]
        node.reviews = [review(1, ref: "a", cwd: "/w/alpha", held: true),
                        review(2, ref: "b", cwd: "/w/alpha", held: false)]
        store.seed(node)

        let rows = store.reviewGroups.flatMap(\.rows)
        // A manual node is not this Mac, so nothing is drivable yet.
        XCTAssertEqual(rows.filter(\.canReceiveMessage).count, 0)
        // Held-ness is carried per item, whatever the node.
        XCTAssertEqual(rows.first { $0.sessionRef == "a" }?
            .review?.payload.held, true)
        XCTAssertEqual(rows.first { $0.sessionRef == "b" }?
            .review?.payload.held, false)
    }

    func testAQuestionIsNotAMessageTarget() {
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha")]
        node.reviews = [review(1, ref: "a", cwd: "/w/alpha",
                               kind: "question", held: true)]
        store.seed(node)
        let row = store.reviewGroups.flatMap(\.rows).first
        XCTAssertEqual(row?.review?.kind, "question")
        XCTAssertFalse(row?.canReceiveMessage ?? true)
    }
}

// MARK: - An offline node's rows say so

extension FleetStoreTests {

    func testAnOfflineNodesSessionDoesNotClaimToBeRunning() {
        // The app kept a five-minute-old snapshot on screen reading
        // "running" while the session was in fact idle and waiting.
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha")]
        node.online = false
        node.lastSeen = Date(timeIntervalSince1970: 1_785_000_000)
        store.seed(node)

        let row = store.reviewGroups.flatMap(\.rows).first
        XCTAssertEqual(row?.nodeOnline, false)
        XCTAssertTrue(row?.stateLine.hasPrefix("as of") ?? false,
                      "expected a last-seen label, got \(row?.stateLine ?? "nil")")
    }

    func testALiveNodesSessionStillReadsRunning() {
        let store = makeStore()
        var node = manualNode(nodeID: "X")
        node.sessions = [session("a", cwd: "/w/alpha")]
        node.online = true
        store.seed(node)
        XCTAssertEqual(store.reviewGroups.flatMap(\.rows).first?.stateLine,
                       "running")
    }
}

// MARK: - This Mac over loopback

extension FleetStoreTests {

    func testThisMacIsReachedOverLoopback() {
        let own = LocalAddresses.hostnames.first { $0.hasSuffix(".local") }
            ?? "localhost"
        let advertised = URL(string: "http://\(own):7787")!
        XCTAssertEqual(FleetStore.preferLoopback(advertised).host, "127.0.0.1")
        XCTAssertEqual(FleetStore.preferLoopback(advertised).port, 7787)
    }

    func testAnotherMacKeepsItsAdvertisedHost() {
        let remote = URL(string: "http://Mac-mini-M4-1.local:7787")!
        XCTAssertEqual(FleetStore.preferLoopback(remote).host,
                       "Mac-mini-M4-1.local")
    }
}
