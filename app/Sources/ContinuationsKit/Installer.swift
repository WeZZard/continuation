import Foundation

// The app's payload — the `continuation` command-line tool plus the agent
// plugin, nothing else — is embedded at Resources/payload and materialized
// to ~/Library/Application Support/Continuation/. This module is the single
// home of the install/update wiring so a future App Store helper can reuse
// it. Reads are file-level; every mutation of agent state shells out to the
// agent's own CLI (`claude` / `pi`) — the app never edits their settings
// files directly. A wiring that points anywhere other than the materialized
// payload is a development checkout and is never touched.

public enum PluginWiring: Equatable, Sendable {
    case agentMissing
    case notInstalled
    case installed(version: String?)   // wired to the app's payload
    case devCheckout(path: String)     // wired elsewhere — left alone
}

public struct AgentStatus: Equatable, Sendable {
    public let binaryPath: String?
    public let binaryVersion: String?
    public let wiring: PluginWiring

    public var detected: Bool { binaryPath != nil }

    public init(binaryPath: String?, binaryVersion: String?, wiring: PluginWiring) {
        self.binaryPath = binaryPath
        self.binaryVersion = binaryVersion
        self.wiring = wiring
    }
}

public struct InstallerSnapshot: Equatable, Sendable {
    public let bundledCLIVersion: String?
    public let bundledPluginVersion: String?
    public let installedCLIVersion: String?
    public let installedPluginVersion: String?
    public let payloadDir: String
    public let cliOnPath: String?
    public let claude: AgentStatus
    public let pi: AgentStatus

    public init(bundledCLIVersion: String?, bundledPluginVersion: String?,
                installedCLIVersion: String?, installedPluginVersion: String?,
                payloadDir: String, cliOnPath: String?,
                claude: AgentStatus, pi: AgentStatus) {
        self.bundledCLIVersion = bundledCLIVersion
        self.bundledPluginVersion = bundledPluginVersion
        self.installedCLIVersion = installedCLIVersion
        self.installedPluginVersion = installedPluginVersion
        self.payloadDir = payloadDir
        self.cliOnPath = cliOnPath
        self.claude = claude
        self.pi = pi
    }
}

/// Pure classifiers over the facts on disk — testable without a live system.
public enum InstallerFacts {

    /// The CLI's version constant, read from the script text itself: the
    /// tool has no dependency on being runnable to be inspectable.
    public static func cliVersion(inScript text: String) -> String? {
        guard let range = text.range(of: #"VERSION = \"([0-9][^\"]*)\""#,
                                     options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("VERSION = \"".count).dropLast())
    }

    public static func pluginVersion(inPluginJSON data: Data) -> String? {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        return (parsed as? [String: Any])?["version"] as? String
    }

    /// Claude Code wiring, judged from ~/.claude/settings.json: the
    /// `continuation` marketplace entry names a directory; ours or a
    /// checkout. The installed version is the newest version-keyed cache
    /// directory (Claude copies plugins; content is not live).
    public static func claudeWiring(settingsJSON: Data?, payloadDir: URL,
                                    cacheDir: URL,
                                    fileManager: FileManager = .default) -> PluginWiring {
        guard let data = settingsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .notInstalled }
        let marketplaces = root["extraKnownMarketplaces"] as? [String: Any]
        guard let entry = marketplaces?["continuation"] as? [String: Any],
              let source = entry["source"] as? [String: Any],
              let path = source["path"] as? String else { return .notInstalled }
        if URL(fileURLWithPath: path).standardizedFileURL.path
            != payloadDir.standardizedFileURL.path {
            return .devCheckout(path: path)
        }
        let enabled = (root["enabledPlugins"] as? [String: Any])?
            .keys.contains("continuation@continuation") ?? false
        guard enabled else { return .notInstalled }
        let versions = (try? fileManager.contentsOfDirectory(atPath: cacheDir.path))?
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return .installed(version: versions?.last)
    }

    /// pi wiring, judged from ~/.pi/agent/settings.json: local packages are
    /// path entries (absolute, relative to the agent dir, or "local:"-
    /// prefixed) referenced in place — content is live, so no version.
    public static func piWiring(settingsJSON: Data?, agentDir: URL,
                                payloadDir: URL) -> PluginWiring {
        guard let data = settingsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let packages = root["packages"] as? [Any] else { return .notInstalled }
        for package in packages {
            var source = package as? String
            if source == nil, let object = package as? [String: Any] {
                source = object["source"] as? String
            }
            guard var path = source else { continue }
            if path.hasPrefix("local:") { path = String(path.dropFirst("local:".count)) }
            if path.hasPrefix("npm:") || path.contains("://") || path.hasPrefix("git") {
                continue
            }
            let resolved: URL
            if path.hasPrefix("~") {
                resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else if path.hasPrefix("/") {
                resolved = URL(fileURLWithPath: path)
            } else {
                resolved = agentDir.appendingPathComponent(path)
            }
            let standardized = resolved.standardizedFileURL.path
            guard standardized.hasSuffix("/plugins/continuation") else { continue }
            let ours = payloadDir.appendingPathComponent("plugins/continuation")
                .standardizedFileURL.path
            return standardized == ours
                ? .installed(version: nil)
                : .devCheckout(path: standardized)
        }
        return .notInstalled
    }
}

/// Everything filesystem- and process-shaped. Synchronous by design; the
/// UI layer calls it from a background task.
public final class InstallerEngine {

    public struct Paths {
        public var payloadSource: URL?      // Resources/payload in the bundle
        public var payloadDest: URL         // ~/Library/App Support/Continuation
        public var claudeSettings: URL
        public var claudeCache: URL         // …/plugins/cache/continuation/continuation
        public var piAgentDir: URL
        public var localBin: URL

        public static func standard(bundle: Bundle = .main) -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Paths(
                payloadSource: bundle.resourceURL?
                    .appendingPathComponent("payload", isDirectory: true),
                payloadDest: appSupport.appendingPathComponent("Continuation", isDirectory: true),
                claudeSettings: home.appendingPathComponent(".claude/settings.json"),
                claudeCache: home.appendingPathComponent(
                    ".claude/plugins/cache/continuation/continuation", isDirectory: true),
                piAgentDir: home.appendingPathComponent(".pi/agent", isDirectory: true),
                localBin: home.appendingPathComponent(".local/bin", isDirectory: true))
        }
    }

    public let paths: Paths
    public private(set) var transcript = ""

    public init(paths: Paths = .standard()) {
        self.paths = paths
    }

    // ------------------------------------------------------------- reading

    public func snapshot() -> InstallerSnapshot {
        let fm = FileManager.default
        let bundledCLI = (paths.payloadSource?
            .appendingPathComponent("bin/continuation"))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(InstallerFacts.cliVersion(inScript:))
        let bundledPlugin = (paths.payloadSource?
            .appendingPathComponent("plugins/continuation/.claude-plugin/plugin.json"))
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(InstallerFacts.pluginVersion(inPluginJSON:))
        let installedCLI = (try? String(
            contentsOf: paths.payloadDest.appendingPathComponent("bin/continuation"),
            encoding: .utf8))
            .flatMap(InstallerFacts.cliVersion(inScript:))
        let installedPlugin = (try? Data(contentsOf: paths.payloadDest
            .appendingPathComponent("plugins/continuation/.claude-plugin/plugin.json")))
            .flatMap(InstallerFacts.pluginVersion(inPluginJSON:))

        let claudeBinary = which("claude") ?? firstExisting([
            "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        let piBinary = which("pi") ?? firstExisting([
            "/opt/homebrew/bin/pi", "/usr/local/bin/pi"])
        let claudeSettings = try? Data(contentsOf: paths.claudeSettings)
        let piSettings = try? Data(contentsOf:
            paths.piAgentDir.appendingPathComponent("settings.json"))

        var claudeWiring = InstallerFacts.claudeWiring(
            settingsJSON: claudeSettings, payloadDir: paths.payloadDest,
            cacheDir: paths.claudeCache, fileManager: fm)
        if claudeBinary == nil { claudeWiring = .agentMissing }
        var piWiring = InstallerFacts.piWiring(
            settingsJSON: piSettings, agentDir: paths.piAgentDir,
            payloadDir: paths.payloadDest)
        if piBinary == nil { piWiring = .agentMissing }

        return InstallerSnapshot(
            bundledCLIVersion: bundledCLI,
            bundledPluginVersion: bundledPlugin,
            installedCLIVersion: installedCLI,
            installedPluginVersion: installedPlugin,
            payloadDir: paths.payloadDest.path,
            cliOnPath: which("continuation"),
            claude: AgentStatus(
                binaryPath: claudeBinary,
                binaryVersion: claudeBinary.flatMap { toolVersion($0) },
                wiring: claudeWiring),
            pi: AgentStatus(
                binaryPath: piBinary,
                binaryVersion: piBinary.flatMap { toolVersion($0) },
                wiring: piWiring))
    }

    // ------------------------------------------------------------- actions

    /// Copy the bundled payload into place atomically: build aside, swap.
    public func materialize() throws {
        guard let source = paths.payloadSource,
              FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.noPayload
        }
        let fm = FileManager.default
        let dest = paths.payloadDest
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent("Continuation.staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755],
                             ofItemAtPath: staging.appendingPathComponent("bin/continuation").path)
        let old = dest.deletingLastPathComponent()
            .appendingPathComponent("Continuation.previous", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: old) }
        try fm.moveItem(at: staging, to: dest)
        try? fm.removeItem(at: old)
        note("materialized payload at \(dest.path)")
    }

    public func linkCLI() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.localBin, withIntermediateDirectories: true)
        let link = paths.localBin.appendingPathComponent("continuation")
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(
            at: link,
            withDestinationURL: paths.payloadDest.appendingPathComponent("bin/continuation"))
        note("linked \(link.path)")
    }

    @discardableResult
    public func wireClaude() -> Bool {
        // `marketplace add` is refused when the name is already registered;
        // that is fine — install still resolves through the existing entry
        // (a dev entry never reaches here: callers guard on wiring state).
        _ = shell("claude plugin marketplace add '\(paths.payloadDest.path)'")
        return shell("claude plugin install continuation@continuation").status == 0
    }

    @discardableResult
    public func updateClaude() -> Bool {
        shell("claude plugin update continuation@continuation").status == 0
    }

    @discardableResult
    public func unwireClaude() -> Bool {
        let ok = shell("claude plugin uninstall continuation@continuation").status == 0
        _ = shell("claude plugin marketplace remove continuation")
        return ok
    }

    @discardableResult
    public func wirePi() -> Bool {
        shell("pi install '\(paths.payloadDest.appendingPathComponent("plugins/continuation").path)'")
            .status == 0
    }

    @discardableResult
    public func unwirePi() -> Bool {
        shell("pi remove '\(paths.payloadDest.appendingPathComponent("plugins/continuation").path)'")
            .status == 0
    }

    // ------------------------------------------------------------- helpers

    public enum InstallerError: Error, LocalizedError {
        case noPayload
        public var errorDescription: String? {
            "This build carries no payload — run from a bundled app."
        }
    }

    /// GUI apps get launchd's minimal PATH; agent CLIs live in user PATH
    /// territory, so every shell-out runs with the usual locations added.
    @discardableResult
    public func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            \(command)
            """]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            note("$ \(command)\nfailed to launch: \(error.localizedDescription)")
            return (127, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        note("$ \(command)\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return (process.terminationStatus, output)
    }

    private func which(_ name: String) -> String? {
        let result = shell("command -v \(name)")
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        return result.status == 0 && path.hasPrefix("/") ? path : nil
    }

    private func firstExisting(_ candidates: [String]) -> String? {
        candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func toolVersion(_ binary: String) -> String? {
        let result = shell("'\(binary)' --version 2>/dev/null | head -1")
        let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !line.isEmpty ? line : nil
    }

    private func note(_ line: String) {
        transcript += line + "\n"
    }
}
