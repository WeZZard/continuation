import Foundation
import XCTest
@testable import ContinuationsKit

final class InstallerTests: XCTestCase {

    private let payload = URL(fileURLWithPath: "/Users/u/Library/Application Support/Continuation")

    func testCLIVersionParsesFromScriptText() {
        let script = """
        SCHEMA_VERSION = 2
        LABEL = "com.wezzard.agent.agentic-continuation"
        VERSION = "0.3.0"
        PROTO = "v1"
        """
        XCTAssertEqual(InstallerFacts.cliVersion(inScript: script), "0.3.0")
        XCTAssertNil(InstallerFacts.cliVersion(inScript: "no version here"))
    }

    func testPluginVersionParsesFromJSON() {
        let json = Data(#"{"name": "continuation", "version": "0.1.1"}"#.utf8)
        XCTAssertEqual(InstallerFacts.pluginVersion(inPluginJSON: json), "0.1.1")
    }

    func testClaudeWiringClassifiesDevCheckout() {
        let settings = Data("""
        {"extraKnownMarketplaces": {"continuation": {"source":
          {"source": "directory", "path": "/Users/u/Artifacts/agentic-continuation"}}},
         "enabledPlugins": {"continuation@continuation": true}}
        """.utf8)
        let wiring = InstallerFacts.claudeWiring(
            settingsJSON: settings, payloadDir: payload,
            cacheDir: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(wiring, .devCheckout(path: "/Users/u/Artifacts/agentic-continuation"))
    }

    func testClaudeWiringClassifiesInstalledWithCacheVersion() throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-test-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("0.1.9"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("0.1.10"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let settings = Data("""
        {"extraKnownMarketplaces": {"continuation": {"source":
          {"source": "directory", "path": "\(payload.path)"}}},
         "enabledPlugins": {"continuation@continuation": true}}
        """.utf8)
        let wiring = InstallerFacts.claudeWiring(
            settingsJSON: settings, payloadDir: payload, cacheDir: cache)
        XCTAssertEqual(wiring, .installed(version: "0.1.10"))  // numeric sort
    }

    func testClaudeWiringNotInstalledWhenAbsentOrDisabled() {
        XCTAssertEqual(
            InstallerFacts.claudeWiring(settingsJSON: Data("{}".utf8),
                                        payloadDir: payload,
                                        cacheDir: URL(fileURLWithPath: "/x")),
            .notInstalled)
        let marketplaceOnly = Data("""
        {"extraKnownMarketplaces": {"continuation": {"source":
          {"source": "directory", "path": "\(payload.path)"}}}}
        """.utf8)
        XCTAssertEqual(
            InstallerFacts.claudeWiring(settingsJSON: marketplaceOnly,
                                        payloadDir: payload,
                                        cacheDir: URL(fileURLWithPath: "/x")),
            .notInstalled)
    }

    func testPiWiringResolvesRelativeEntriesAgainstAgentDir() {
        let agentDir = URL(fileURLWithPath: "/Users/u/.pi/agent")
        let settings = Data("""
        {"packages": ["npm:pi-web-access",
                      "../../Artifacts/agentic-continuation/plugins/continuation"]}
        """.utf8)
        let wiring = InstallerFacts.piWiring(
            settingsJSON: settings, agentDir: agentDir, payloadDir: payload)
        XCTAssertEqual(wiring,
            .devCheckout(path: "/Users/u/Artifacts/agentic-continuation/plugins/continuation"))
    }

    func testPiWiringRecognizesPayloadInstall() {
        let settings = Data("""
        {"packages": ["\(payload.path)/plugins/continuation"]}
        """.utf8)
        let wiring = InstallerFacts.piWiring(
            settingsJSON: settings,
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload)
        XCTAssertEqual(wiring, .installed(version: nil))
    }

    func testPiWiringIgnoresRemoteSources() {
        let settings = Data("""
        {"packages": ["npm:x", "https://github.com/a/b", "git@github.com:a/b.git"]}
        """.utf8)
        XCTAssertEqual(
            InstallerFacts.piWiring(settingsJSON: settings,
                                    agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
                                    payloadDir: payload),
            .notInstalled)
    }
}
