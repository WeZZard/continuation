import Foundation

// The app's payload — the `continuation` command-line tool plus the agent
// plugin, nothing else — is embedded at Resources/payload and materialized
// to the build's own Application Support umbrella. This module is the
// single home of the install wiring so a future App Store helper can reuse
// it.
//
// Per the agent-plugin-management scene: the agent's OWN records are the
// truth — installation status is read from them every time, never
// remembered here — and every change goes through the agent's native
// plugin system, never by writing into files the user authored.

/// Debug and release builds keep separate Application Support umbrellas
/// (user ruling 2026-07-25): a debug app never writes into the release
/// app's folders.
public enum AppSupportUmbrella {
    public static func directoryName(
        base: String,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> String {
        (bundleID?.hasSuffix(".debug") ?? false) ? base + "-Debug" : base
    }
}

public enum AgentKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case claude
    case pi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .pi: return "pi"
        }
    }

    /// The command the agent's own plugin system is driven through.
    public var command: String {
        switch self {
        case .claude: return "claude"
        case .pi: return "pi"
        }
    }
}

/// The states of the cell's table, read from the agent every time.
public enum AgentInstallation: Equatable, Sendable {
    case absent                        // no usable agent on this Mac
    case notInstalled
    case installed(version: String?, disabled: Bool, updateAvailable: Bool)
    case broken(cause: String)
}

public struct AgentStatus: Equatable, Sendable, Identifiable {
    public let kind: AgentKind
    public let binaryPath: String?
    /// The version the agent itself reports; nil when none was found.
    public let version: String?
    public let installation: AgentInstallation
    /// Where the agent installs the plugin FROM.
    public let location: String?

    public var id: AgentKind { kind }
    public var detected: Bool { binaryPath != nil }

    public init(kind: AgentKind, binaryPath: String?, version: String?,
                installation: AgentInstallation, location: String?) {
        self.kind = kind
        self.binaryPath = binaryPath
        self.version = version
        self.installation = installation
        self.location = location
    }
}

public struct InstallerSnapshot: Equatable, Sendable {
    public let bundledCLIVersion: String?
    public let bundledPluginVersion: String?
    public let installedCLIVersion: String?
    public let installedPluginVersion: String?
    public let payloadDir: String
    public let cliOnPath: String?
    public let agents: [AgentStatus]

    public func agent(_ kind: AgentKind) -> AgentStatus? {
        agents.first { $0.kind == kind }
    }

    public init(bundledCLIVersion: String?, bundledPluginVersion: String?,
                installedCLIVersion: String?, installedPluginVersion: String?,
                payloadDir: String, cliOnPath: String?, agents: [AgentStatus]) {
        self.bundledCLIVersion = bundledCLIVersion
        self.bundledPluginVersion = bundledPluginVersion
        self.installedCLIVersion = installedCLIVersion
        self.installedPluginVersion = installedPluginVersion
        self.payloadDir = payloadDir
        self.cliOnPath = cliOnPath
        self.agents = agents
    }
}

/// Pure classifiers over the agents' own records — testable without a
/// live system.
public enum InstallerFacts {

    public static let pluginID = "continuation@continuation"
    public static let marketplaceName = "continuation"

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

    /// Claude Code's own install record: `~/.claude/plugins/installed_plugins.json`
    /// is what `claude plugin list` reports from — settings.json alone
    /// never installs anything (probed 2026-07-25).
    public static func claudeInstalledVersion(installedPluginsJSON: Data?) -> String? {
        guard let data = installedPluginsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let records = plugins[pluginID] as? [Any],
              let record = records.first as? [String: Any] else { return nil }
        return (record["version"] as? String) ?? ""
    }

    /// The registered marketplace directory — where Claude Code installs
    /// the plugin FROM.
    public static func claudeMarketplacePath(settingsJSON: Data?) -> String? {
        guard let data = settingsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let marketplaces = root["extraKnownMarketplaces"] as? [String: Any],
              let entry = marketplaces[marketplaceName] as? [String: Any],
              let source = entry["source"] as? [String: Any] else { return nil }
        return source["path"] as? String
    }

    /// The agent's own enable flag; nil when it holds no opinion.
    public static func claudeEnabled(settingsJSON: Data?) -> Bool? {
        guard let data = settingsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = root["enabledPlugins"] as? [String: Any] else { return nil }
        return plugins[pluginID] as? Bool
    }

    public static func claudeInstallation(
        installedPluginsJSON: Data?, settingsJSON: Data?,
        bundledPluginVersion: String?,
        fileManager: FileManager = .default
    ) -> (installation: AgentInstallation, location: String?) {
        let marketplace = claudeMarketplacePath(settingsJSON: settingsJSON)
        let installed = claudeInstalledVersion(installedPluginsJSON: installedPluginsJSON)

        guard let installed else {
            // A registered source with nothing installed is a half state —
            // named, and repaired by the cell's action.
            if marketplace != nil {
                return (.broken(cause: "source registered, plugin not installed"),
                        marketplace)
            }
            return (.notInstalled, nil)
        }
        guard let marketplace else {
            return (.broken(cause: "installed from an unregistered source"), nil)
        }
        guard fileManager.fileExists(atPath: marketplace) else {
            return (.broken(cause: "source missing"), marketplace)
        }
        let disabled = claudeEnabled(settingsJSON: settingsJSON) == false
        let stale = bundledPluginVersion.map { !installed.isEmpty && installed != $0 }
            ?? false
        return (.installed(version: installed.isEmpty ? nil : installed,
                           disabled: disabled, updateAvailable: stale),
                marketplace)
    }

    /// pi installs from a local package path referenced IN PLACE, so its
    /// version is whatever that directory holds right now.
    public static func piInstallation(
        settingsJSON: Data?, agentDir: URL, payloadDir: URL,
        bundledPluginVersion: String?,
        fileManager: FileManager = .default
    ) -> (installation: AgentInstallation, location: String?) {
        guard let data = settingsJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let packages = root["packages"] as? [Any],
              let entry = piContinuationEntry(packages: packages, agentDir: agentDir)
        else { return (.notInstalled, nil) }

        guard fileManager.fileExists(atPath: entry.path) else {
            return (.broken(cause: "source missing"), entry.path)
        }
        let disabled: Bool = {
            guard let object = entry.raw as? [String: Any],
                  let skills = object["skills"] as? [Any] else { return false }
            return skills.isEmpty
        }()
        let version = (try? Data(contentsOf: URL(fileURLWithPath: entry.path)
            .appendingPathComponent("package.json")))
            .flatMap(pluginVersion(inPluginJSON:))
        // The package is read live; it is stale only when the app's own
        // payload has not been refreshed to the bundled version.
        let ours = entry.path == payloadDir
            .appendingPathComponent("plugins/continuation").standardizedFileURL.path
        let stale = ours && bundledPluginVersion != nil && version != bundledPluginVersion
        return (.installed(version: version, disabled: disabled,
                           updateAvailable: stale),
                entry.path)
    }

    /// The continuation package entry in a pi `packages` array, with its
    /// source path resolved against the agent dir.
    static func piContinuationEntry(packages: [Any],
                                    agentDir: URL) -> (raw: Any, index: Int, path: String)? {
        for (index, package) in packages.enumerated() {
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
            return (package, index, standardized)
        }
        return nil
    }
}

/// Everything filesystem- and process-shaped. Synchronous by design; the
/// UI layer calls it from a background task.
public final class InstallerEngine {

    public struct Paths {
        public var payloadSource: URL?      // Resources/payload in the bundle
        public var payloadDest: URL         // the build's App Support umbrella
        public var claudeSettings: URL
        public var claudeInstalledPlugins: URL
        public var piAgentDir: URL
        public var localBin: URL

        public static func standard(bundle: Bundle = .main) -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Paths(
                payloadSource: bundle.resourceURL?
                    .appendingPathComponent("payload", isDirectory: true),
                payloadDest: appSupport.appendingPathComponent(
                    AppSupportUmbrella.directoryName(
                        base: "Continuation",
                        bundleID: bundle.bundleIdentifier),
                    isDirectory: true),
                claudeSettings: home.appendingPathComponent(".claude/settings.json"),
                claudeInstalledPlugins: home.appendingPathComponent(
                    ".claude/plugins/installed_plugins.json"),
                piAgentDir: home.appendingPathComponent(".pi/agent", isDirectory: true),
                localBin: home.appendingPathComponent(".local/bin", isDirectory: true))
        }

        public var pluginSource: URL {
            payloadDest.appendingPathComponent("plugins/continuation")
        }
    }

    public let paths: Paths
    public private(set) var transcript = ""

    public init(paths: Paths = .standard()) {
        self.paths = paths
    }

    // ------------------------------------------------------------- reading

    /// Detection is cheap and runs often; the agent's records are files,
    /// so status costs one `--version` subprocess per detected agent.
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

        let claudeBinary = locate(.claude)
        let piBinary = locate(.pi)

        let claudeFacts = InstallerFacts.claudeInstallation(
            installedPluginsJSON: try? Data(contentsOf: paths.claudeInstalledPlugins),
            settingsJSON: try? Data(contentsOf: paths.claudeSettings),
            bundledPluginVersion: bundledPlugin, fileManager: fm)
        let piFacts = InstallerFacts.piInstallation(
            settingsJSON: try? Data(contentsOf:
                paths.piAgentDir.appendingPathComponent("settings.json")),
            agentDir: paths.piAgentDir, payloadDir: paths.payloadDest,
            bundledPluginVersion: bundledPlugin, fileManager: fm)

        return InstallerSnapshot(
            bundledCLIVersion: bundledCLI,
            bundledPluginVersion: bundledPlugin,
            installedCLIVersion: installedCLI,
            installedPluginVersion: installedPlugin,
            payloadDir: paths.payloadDest.path,
            cliOnPath: which("continuation"),
            agents: [
                AgentStatus(kind: .claude, binaryPath: claudeBinary,
                            version: claudeBinary.flatMap { toolVersion($0) },
                            installation: claudeBinary == nil
                                ? .absent : claudeFacts.installation,
                            location: claudeFacts.location),
                AgentStatus(kind: .pi, binaryPath: piBinary,
                            version: piBinary.flatMap { toolVersion($0) },
                            installation: piBinary == nil
                                ? .absent : piFacts.installation,
                            location: piFacts.location),
            ])
    }

    public func locate(_ agent: AgentKind) -> String? {
        if let found = which(agent.command) { return found }
        switch agent {
        case .claude:
            return firstExisting(["~/.claude/local/claude",
                                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        case .pi:
            return firstExisting(["/opt/homebrew/bin/pi", "/usr/local/bin/pi"])
        }
    }

    // -------------------------------------------------------- preparation

    /// Work the app performs inside its own container: never a disclosed
    /// command, and it fails before the sheet runs anything.
    public func prepare() throws {
        try materialize()
        try linkCLI()
    }

    /// Copy the bundled payload into place atomically: build aside, swap.
    public func materialize() throws {
        guard let source = paths.payloadSource,
              FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.noPayload
        }
        let fm = FileManager.default
        let dest = paths.payloadDest
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(dest.lastPathComponent + ".staging",
                                    isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755],
                             ofItemAtPath: staging.appendingPathComponent("bin/continuation").path)
        let old = dest.deletingLastPathComponent()
            .appendingPathComponent(dest.lastPathComponent + ".previous",
                                    isDirectory: true)
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

    public func unlinkCLI() throws {
        let link = paths.localBin.appendingPathComponent("continuation")
        do {
            try FileManager.default.removeItem(at: link)
            note("removed \(link.path)")
        } catch CocoaError.fileNoSuchFile {
            note("no CLI link to remove")
        }
    }

    // ------------------------------------------------------------- running

    /// Run one disclosed step verbatim: the argument vector IS the step.
    /// Returns the tool's own exit status and its full standard error.
    @discardableResult
    public func run(argv: [String]) -> (status: Int32, stderr: String, stdout: String) {
        guard let first = argv.first else { return (0, "", "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = extra + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            note("$ \(argv.joined(separator: " "))\n\(error.localizedDescription)")
            return (127, "could not run \(first): \(error.localizedDescription)", "")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        note("$ \(argv.joined(separator: " ")) → \(process.terminationStatus)")
        return (process.terminationStatus, stderr, stdout)
    }

    // ------------------------------------------------------------- helpers

    public enum InstallerError: Error, LocalizedError {
        case noPayload
        public var errorDescription: String? {
            "This build carries no payload — run from a bundled app."
        }
    }

    private func which(_ name: String) -> String? {
        let result = run(argv: ["/bin/zsh", "-lc", "command -v \(name)"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        return result.status == 0 && path.hasPrefix("/") ? path : nil
    }

    private func firstExisting(_ candidates: [String]) -> String? {
        candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func toolVersion(_ binary: String) -> String? {
        let result = run(argv: [binary, "--version"])
        let line = result.stdout
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard result.status == 0 else { return nil }
        // "2.1.220 (Claude Code)" → "2.1.220"
        let head = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        return head.isEmpty ? nil : head
    }

    private func note(_ line: String) {
        transcript += line + "\n"
    }
}
