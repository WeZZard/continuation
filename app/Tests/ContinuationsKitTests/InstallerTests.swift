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

extension InstallerTests {

    func testClaudeEnabledFlagParses() {
        let on = Data(#"{"enabledPlugins": {"continuation@continuation": true}}"#.utf8)
        let off = Data(#"{"enabledPlugins": {"continuation@continuation": false}}"#.utf8)
        XCTAssertEqual(InstallerFacts.claudeEnabled(settingsJSON: on), true)
        XCTAssertEqual(InstallerFacts.claudeEnabled(settingsJSON: off), false)
        XCTAssertNil(InstallerFacts.claudeEnabled(settingsJSON: Data("{}".utf8)))
    }

    func testPiEnabledFlagParses() {
        let agentDir = URL(fileURLWithPath: "/Users/u/.pi/agent")
        let plain = Data(#"{"packages": ["/x/plugins/continuation"]}"#.utf8)
        let disabled = Data(#"{"packages": [{"source": "/x/plugins/continuation", "skills": []}]}"#.utf8)
        XCTAssertEqual(InstallerFacts.piEnabled(settingsJSON: plain, agentDir: agentDir), true)
        XCTAssertEqual(InstallerFacts.piEnabled(settingsJSON: disabled, agentDir: agentDir), false)
        XCTAssertNil(InstallerFacts.piEnabled(settingsJSON: Data("{}".utf8), agentDir: agentDir))
    }

    func testEngineTogglesBothSettingsFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-toggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pi-agent"), withIntermediateDirectories: true)
        let claudeSettings = dir.appendingPathComponent("claude-settings.json")
        let piSettings = dir.appendingPathComponent("pi-agent/settings.json")
        try Data(#"{"model": "fable", "enabledPlugins": {"continuation@continuation": true}}"#.utf8)
            .write(to: claudeSettings)
        try Data(#"{"packages": ["/x/plugins/continuation"]}"#.utf8).write(to: piSettings)
        defer { try? FileManager.default.removeItem(at: dir) }

        var paths = InstallerEngine.Paths.standard()
        paths.claudeSettings = claudeSettings
        paths.piAgentDir = dir.appendingPathComponent("pi-agent")
        let engine = InstallerEngine(paths: paths)

        try engine.setClaudeEnabled(false)
        XCTAssertEqual(
            InstallerFacts.claudeEnabled(settingsJSON: try Data(contentsOf: claudeSettings)),
            false)
        // Unrelated keys survive the rewrite.
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeSettings)) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "fable")

        let agentDir = paths.piAgentDir
        try engine.setPiEnabled(false)
        XCTAssertEqual(
            InstallerFacts.piEnabled(settingsJSON: try Data(contentsOf: piSettings),
                                     agentDir: agentDir), false)
        try engine.setPiEnabled(true)
        XCTAssertEqual(
            InstallerFacts.piEnabled(settingsJSON: try Data(contentsOf: piSettings),
                                     agentDir: agentDir), true)
    }
}

extension InstallerTests {

    func testLinkAndUnlinkCLIRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-link-\(UUID().uuidString)")
        let payloadBin = dir.appendingPathComponent("payload/bin")
        try FileManager.default.createDirectory(at: payloadBin,
                                                withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: payloadBin.appendingPathComponent("continuation"))
        defer { try? FileManager.default.removeItem(at: dir) }

        var paths = InstallerEngine.Paths.standard()
        paths.payloadDest = dir.appendingPathComponent("payload")
        paths.localBin = dir.appendingPathComponent("bin")
        let engine = InstallerEngine(paths: paths)

        try engine.linkCLI()
        let link = paths.localBin.appendingPathComponent("continuation")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            paths.payloadDest.appendingPathComponent("bin/continuation").path)

        try engine.unlinkCLI()
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertNoThrow(try engine.unlinkCLI())   // idempotent
    }
}
