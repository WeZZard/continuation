import Foundation
import XCTest
@testable import ContinuationsKit

/// The states of the agent-cell table, read from each agent's own records.
final class InstallerTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeRecords(version: String) -> Data {
        Data("""
        {"version": 2, "plugins": {"continuation@continuation":
          [{"scope": "user", "version": "\(version)"}]}}
        """.utf8)
    }

    private func claudeSettings(marketplace: String, enabled: Bool? = true) -> Data {
        let enabledPart = enabled.map {
            #", "enabledPlugins": {"continuation@continuation": \#($0)}"#
        } ?? ""
        return Data("""
        {"extraKnownMarketplaces": {"continuation": {"source":
          {"source": "directory", "path": "\(marketplace)"}}}\(enabledPart)}
        """.utf8)
    }

    // ----------------------------------------------------------- versions

    func testCLIVersionParsesFromScriptText() {
        let script = """
        SCHEMA_VERSION = 2
        VERSION = "0.4.0"
        PROTO = "v1"
        """
        XCTAssertEqual(InstallerFacts.cliVersion(inScript: script), "0.4.0")
        XCTAssertNil(InstallerFacts.cliVersion(inScript: "no version here"))
    }

    func testPluginVersionParsesFromJSON() {
        let json = Data(#"{"name": "continuation", "version": "0.1.1"}"#.utf8)
        XCTAssertEqual(InstallerFacts.pluginVersion(inPluginJSON: json), "0.1.1")
    }

    // ------------------------------------------------------ Claude states

    func testClaudeNotInstalledWhenNoRecords() {
        let facts = InstallerFacts.claudeInstallation(
            installedPluginsJSON: nil, settingsJSON: nil,
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.installation, .notInstalled)
        XCTAssertNil(facts.location)
    }

    func testClaudeInstalledReportsVersionAndSource() {
        let source = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let facts = InstallerFacts.claudeInstallation(
            installedPluginsJSON: claudeRecords(version: "0.1.1"),
            settingsJSON: claudeSettings(marketplace: source.path),
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: false,
                                  updateAvailable: false))
        XCTAssertEqual(facts.location, source.path)
    }

    func testClaudeDisabledByTheAgentIsItsOwnState() {
        let source = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let facts = InstallerFacts.claudeInstallation(
            installedPluginsJSON: claudeRecords(version: "0.1.1"),
            settingsJSON: claudeSettings(marketplace: source.path, enabled: false),
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: true,
                                  updateAvailable: false))
    }

    func testClaudeUpdateAvailableWhenTheAppCarriesNewer() {
        let source = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let facts = InstallerFacts.claudeInstallation(
            installedPluginsJSON: claudeRecords(version: "0.1.1"),
            settingsJSON: claudeSettings(marketplace: source.path),
            bundledPluginVersion: "0.2.0")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: false,
                                  updateAvailable: true))
    }

    func testClaudeBrokenNamesItsCause() {
        // Source registered, nothing installed.
        let source = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let halfway = InstallerFacts.claudeInstallation(
            installedPluginsJSON: nil,
            settingsJSON: claudeSettings(marketplace: source.path),
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(halfway.installation,
                       .broken(cause: "source registered, plugin not installed"))

        // Registered source that no longer exists on disk.
        let missing = InstallerFacts.claudeInstallation(
            installedPluginsJSON: claudeRecords(version: "0.1.1"),
            settingsJSON: claudeSettings(marketplace: "/nonexistent/source"),
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(missing.installation, .broken(cause: "source missing"))
        XCTAssertEqual(missing.location, "/nonexistent/source")

        // Installed with no registered source at all.
        let unregistered = InstallerFacts.claudeInstallation(
            installedPluginsJSON: claudeRecords(version: "0.1.1"),
            settingsJSON: Data("{}".utf8),
            bundledPluginVersion: "0.1.1")
        XCTAssertEqual(unregistered.installation,
                       .broken(cause: "installed from an unregistered source"))
    }

    // ---------------------------------------------------------- pi states

    private func piPackage(at root: URL, version: String) throws -> URL {
        let path = root.appendingPathComponent("plugins/continuation")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(#"{"name": "continuation", "version": "\#(version)"}"#.utf8)
            .write(to: path.appendingPathComponent("package.json"))
        return path
    }

    func testPiInstalledReadsTheLivePackage() throws {
        let payload = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payload) }
        let package = try piPackage(at: payload, version: "0.1.1")
        let settings = Data(#"{"packages": ["\#(package.path)"]}"#.utf8)

        let facts = InstallerFacts.piInstallation(
            settingsJSON: settings,
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload, bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: false,
                                  updateAvailable: false))
        XCTAssertEqual(facts.location, package.path)
    }

    func testPiUpdateAvailableWhenPayloadIsBehindTheBundle() throws {
        let payload = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payload) }
        let package = try piPackage(at: payload, version: "0.1.1")
        let settings = Data(#"{"packages": ["\#(package.path)"]}"#.utf8)

        let facts = InstallerFacts.piInstallation(
            settingsJSON: settings,
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload, bundledPluginVersion: "0.2.0")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: false,
                                  updateAvailable: true))
    }

    func testPiDisabledWhenSkillsAreFilteredOff() throws {
        let payload = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payload) }
        let package = try piPackage(at: payload, version: "0.1.1")
        let settings = Data("""
        {"packages": [{"source": "\(package.path)", "skills": []}]}
        """.utf8)
        let facts = InstallerFacts.piInstallation(
            settingsJSON: settings,
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload, bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.installation,
                       .installed(version: "0.1.1", disabled: true,
                                  updateAvailable: false))
    }

    func testPiBrokenWhenSourceMissingAndNotInstalledWhenAbsent() {
        let payload = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payload) }
        let settings = Data(#"{"packages": ["/nonexistent/plugins/continuation"]}"#.utf8)
        let broken = InstallerFacts.piInstallation(
            settingsJSON: settings,
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload, bundledPluginVersion: "0.1.1")
        XCTAssertEqual(broken.installation, .broken(cause: "source missing"))

        let none = InstallerFacts.piInstallation(
            settingsJSON: Data(#"{"packages": ["npm:other"]}"#.utf8),
            agentDir: URL(fileURLWithPath: "/Users/u/.pi/agent"),
            payloadDir: payload, bundledPluginVersion: "0.1.1")
        XCTAssertEqual(none.installation, .notInstalled)
    }

    func testPiResolvesRelativeEntriesAgainstTheAgentDir() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentDir = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let package = try piPackage(at: root, version: "0.1.1")
        let settings = Data(#"{"packages": ["../plugins/continuation"]}"#.utf8)

        let facts = InstallerFacts.piInstallation(
            settingsJSON: settings, agentDir: agentDir,
            payloadDir: root, bundledPluginVersion: "0.1.1")
        XCTAssertEqual(facts.location, package.path)
    }
}

// MARK: - Plans

extension InstallerTests {

    private func paths(payload: URL) -> InstallerEngine.Paths {
        var paths = InstallerEngine.Paths.standard()
        paths.payloadDest = payload
        return paths
    }

    private func status(_ kind: AgentKind, _ installation: AgentInstallation,
                        location: String?) -> AgentStatus {
        AgentStatus(kind: kind, binaryPath: "/usr/local/bin/\(kind.command)",
                    version: "1.0", installation: installation, location: location)
    }

    func testClaudeInstallRegistersThenInstalls() {
        let payload = URL(fileURLWithPath: "/tmp/payload")
        let plan = OperationPlanner.plan(
            .install,
            for: status(.claude, .notInstalled, location: nil),
            paths: paths(payload: payload))
        XCTAssertEqual(plan.steps.map(\.argv), [
            ["claude", "plugin", "marketplace", "add", "/tmp/payload"],
            ["claude", "plugin", "marketplace", "update", "continuation"],
            ["claude", "plugin", "install", "continuation@continuation"],
        ])
        // The disclosure derives from the argument vector.
        XCTAssertEqual(plan.steps[2].display,
                       "claude plugin install continuation@continuation")
    }

    func testRetryConvergesWhenTheSourceIsAlreadyOurs() {
        let payload = URL(fileURLWithPath: "/tmp/payload")
        let plan = OperationPlanner.plan(
            .retry,
            for: status(.claude,
                        .broken(cause: "source registered, plugin not installed"),
                        location: "/tmp/payload"),
            paths: paths(payload: payload))
        // Converged: no add, but the listing is still re-read — Claude
        // caches it, and a stale listing is what broke the first attempt.
        XCTAssertEqual(plan.steps.map(\.argv), [
            ["claude", "plugin", "marketplace", "update", "continuation"],
            ["claude", "plugin", "install", "continuation@continuation"],
        ])
    }

    func testRetryReplacesAStaleSource() {
        let payload = URL(fileURLWithPath: "/tmp/payload")
        let plan = OperationPlanner.plan(
            .retry,
            for: status(.claude, .broken(cause: "source missing"),
                        location: "/gone/elsewhere"),
            paths: paths(payload: payload))
        XCTAssertEqual(plan.steps.map(\.argv.first),
                       ["claude", "claude", "claude", "claude"])
        XCTAssertEqual(plan.steps[0].argv[3], "remove")
        XCTAssertEqual(plan.steps[1].argv[3], "add")
        XCTAssertEqual(plan.steps[2].argv[3], "update")
        XCTAssertEqual(plan.steps[3].argv[2], "install")
    }

    func testClaudeUninstallUnregistersOnlyWhatIsRegistered() {
        let payload = URL(fileURLWithPath: "/tmp/payload")
        let wired = OperationPlanner.plan(
            .uninstall,
            for: status(.claude,
                        .installed(version: "0.1.1", disabled: false,
                                   updateAvailable: false),
                        location: "/tmp/payload"),
            paths: paths(payload: payload))
        XCTAssertEqual(wired.steps.count, 2)

        let noSource = OperationPlanner.plan(
            .uninstall,
            for: status(.claude,
                        .broken(cause: "installed from an unregistered source"),
                        location: nil),
            paths: paths(payload: payload))
        XCTAssertEqual(noSource.steps.count, 1)
    }

    func testPiPlansInstallAndReplaceStale() {
        let payload = URL(fileURLWithPath: "/tmp/payload")
        let fresh = OperationPlanner.plan(
            .install, for: status(.pi, .notInstalled, location: nil),
            paths: paths(payload: payload))
        XCTAssertEqual(fresh.steps.map(\.argv),
                       [["pi", "install", "/tmp/payload/plugins/continuation"]])

        let stale = OperationPlanner.plan(
            .install,
            for: status(.pi, .notInstalled, location: "/checkout/plugins/continuation"),
            paths: paths(payload: payload))
        XCTAssertEqual(stale.steps.map(\.argv), [
            ["pi", "remove", "/checkout/plugins/continuation"],
            ["pi", "install", "/tmp/payload/plugins/continuation"],
        ])
    }

    func testUninstallNeedsNoPreparation() {
        XCTAssertFalse(OperationVerb.uninstall.needsPreparation)
        XCTAssertTrue(OperationVerb.install.needsPreparation)
        XCTAssertTrue(OperationVerb.update.needsPreparation)
        XCTAssertTrue(OperationVerb.retry.needsPreparation)
    }
}

// MARK: - Geometry, umbrellas, CLI link

extension InstallerTests {

    func testIconTakesTheGoldenShareOfTheCellInBothRegimes() {
        // Text leads: the cell is text + padding, the icon follows.
        let padding: CGFloat = 12
        let tall = AgentCellGeometry.iconHeight(textHeight: 32,
                                                verticalPadding: padding)
        XCTAssertEqual(tall, 0.618 * (32 + padding), accuracy: 0.001)
        XCTAssertEqual(tall / (32 + padding), 0.618, accuracy: 0.001)
        XCTAssertLessThanOrEqual(tall, 32)

        // Icon leads: its own fixed point, h = ratio * (h + padding).
        let short = AgentCellGeometry.iconHeight(textHeight: 4,
                                                 verticalPadding: padding)
        XCTAssertEqual(short, short / (short + padding) * (short + padding),
                       accuracy: 0.001)
        XCTAssertEqual(short / (short + padding), 0.618, accuracy: 0.001)
        XCTAssertGreaterThan(short, 4)
    }

    func testUmbrellaNamesSplitByBuild() {
        XCTAssertEqual(AppSupportUmbrella.directoryName(
            base: "Continuation",
            bundleID: "com.wezzarddesign.continuation.debug"),
            "Continuation-Debug")
        XCTAssertEqual(AppSupportUmbrella.directoryName(
            base: "Continuation",
            bundleID: "com.wezzarddesign.continuations"),
            "Continuation")
        XCTAssertEqual(AppSupportUmbrella.directoryName(
            base: "Continuations", bundleID: nil),
            "Continuations")
    }

    func testLinkAndUnlinkCLIRoundTrip() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payloadBin = dir.appendingPathComponent("payload/bin")
        try FileManager.default.createDirectory(at: payloadBin,
                                                withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: payloadBin.appendingPathComponent("continuation"))

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

// MARK: - Capture

extension InstallerTests {

    func testCaptureCommandQuotesTheSpacedPayloadPath() {
        let directory = URL(fileURLWithPath:
            "/Users/u/Library/Application Support/Continuation-Debug/plugins/console")
        XCTAssertEqual(
            CaptureLaunch.command(for: .claude, pluginDirectory: directory),
            "claude --plugin-dir '/Users/u/Library/Application Support/"
                + "Continuation-Debug/plugins/console'")
        // pi has no hook surface this plugin can use yet.
        XCTAssertNil(CaptureLaunch.command(for: .pi, pluginDirectory: directory))
    }

    func testCaptureCommandLeavesAPlainPathUnquoted() {
        XCTAssertEqual(
            CaptureLaunch.command(for: .claude,
                                  pluginDirectory: URL(fileURLWithPath: "/opt/console")),
            "claude --plugin-dir /opt/console")
    }
}
