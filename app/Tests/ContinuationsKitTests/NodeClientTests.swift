// End-to-end: the Swift client against the REAL `serve` subprocess over a
// temp store — the same wire the app uses, no stubs.

import XCTest
@testable import ContinuationsKit

final class NodeClientTests: XCTestCase {
    static let harness = try! ServeHarness()

    override class func tearDown() {
        harness.stop()
        super.tearDown()
    }

    var client: NodeClient { NodeClient(baseURL: Self.harness.baseURL) }

    func testNodeIdentity() async throws {
        let node = try await client.node()
        XCTAssertEqual(node.proto, "v1")
        XCTAssertEqual(node.nodeID.count, 26)
        XCTAssertEqual(node.schemaVersions, [1, 2])
        XCTAssertFalse(node.hostname.isEmpty)
        XCTAssertFalse((node.displayName ?? "").isEmpty)
    }

    func testQueueAndTaskDetail() async throws {
        let queue = try await client.queue()
        let open = queue.open
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].task, "kit-task")
        XCTAssertEqual(open[0].continuation, "probe-step--01")
        XCTAssertEqual(open[0].schedule?.mode, "every")
        XCTAssertEqual(open[0].schedule?.label, "every 12h")

        let detail = try await client.taskDetail("kit-task")
        XCTAssertEqual(detail.mustNot, ["touch production"])
        let runs = try XCTUnwrap(detail.runs)
        XCTAssertEqual(runs.count, 1)
        let entry = try XCTUnwrap(runs[0].entries.first)
        XCTAssertEqual(entry.cid, "probe-step--01")
        XCTAssertEqual(entry.core.task, "Check whether the thing finished.")
        XCTAssertEqual(entry.evaluations, 1)
    }

    func testPrompts() async throws {
        let detail = try await client.taskDetail("kit-task")
        let run = try XCTUnwrap(detail.runs?.first)
        let prompts = try await client.prompts(task: "kit-task", run: run.runID)
        XCTAssertEqual(prompts.map(\.name), ["prompt--probe-step--01--001.md"])
        let text = try await client.promptText(
            task: "kit-task", run: run.runID, name: prompts[0].name)
        XCTAssertTrue(text.contains("You are evaluating a registered continuation"))
    }

    func testLogAndLiveEvents() async throws {
        let recent = try await client.log(limit: 1)
        let cursor = try XCTUnwrap(recent.first).id

        let stream = client.events(after: cursor)
        Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            try Self.harness.cli("list")
        }
        let first = try await withThrowingTaskGroup(of: EventRow?.self) { group in
            group.addTask {
                for try await row in stream { return row }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        XCTAssertEqual(try XCTUnwrap(first).cmd, "list")
        XCTAssertEqual(try XCTUnwrap(first).id, cursor + 1)
    }
}

// MARK: - Harness

final class ServeHarness {
    private(set) var baseURL: URL
    private let storeDir: URL
    private let repoBin: String
    private let serveProcess: Process

    init() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ContinuationsKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
        repoBin = repoRoot.appendingPathComponent("bin/continuation").path
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuations-kit-tests-\(UUID().uuidString)")

        let continuation = storeDir.appendingPathComponent("continuation.json")
        try FileManager.default.createDirectory(
            at: storeDir, withIntermediateDirectories: true)
        try Data("""
        {"schema_version": 2, "step": "probe-step",
         "task": "Check whether the thing finished.",
         "when_to_stop": ["Thing still running - stop, return nothing."],
         "when_to_continue": "When done, return the next step.",
         "context": "Kit test continuation.",
         "schedule": {"mode": "every", "amount": 12, "unit": "h"}}
        """.utf8).write(to: continuation)

        serveProcess = Process()
        baseURL = URL(string: "http://127.0.0.1:0")!  // replaced below

        try cli("register", "kit-task", "--agent", "claude-code",
                "--agent-command", "/usr/bin/true",
                "--must-not", "touch production",
                "--continuation", continuation.path)
        try cli("tick")  // starts the run, archives the prompt, evaluates once

        serveProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serveProcess.arguments = [repoBin, "serve", "--bind", "127.0.0.1",
                                  "--port", "0", "--no-mdns", "--sse-poll", "0.05"]
        serveProcess.environment = environment
        let stdout = Pipe()
        serveProcess.standardOutput = stdout
        try serveProcess.run()

        var banner = ""
        let deadline = Date().addingTimeInterval(15)
        while !banner.contains("\n") && Date() < deadline {
            let data = stdout.fileHandleForReading.availableData
            if data.isEmpty { break }
            banner += String(decoding: data, as: UTF8.self)
        }
        guard let match = banner.range(
            of: #"on 127\.0\.0\.1:(\d+)"#, options: .regularExpression),
            let port = Int(banner[match].split(separator: ":").last ?? "") else {
            throw NSError(domain: "harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no serve banner in: \(banner)"])
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["AGENTIC_CONTINUATION_STORE"] = storeDir.appendingPathComponent("store").path
        env["PATH"] = "/usr/bin:/bin"  // hide the real `things` CLI
        return env
    }

    @discardableResult
    func cli(_ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repoBin] + arguments
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func stop() {
        serveProcess.terminate()
        serveProcess.waitUntilExit()
        try? FileManager.default.removeItem(at: storeDir)
    }
}
