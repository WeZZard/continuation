import ContinuationsKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            NodesSettingsView()
                .tabItem { Label("Nodes", systemImage: "point.3.connected.trianglepath.dotted") }
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "command") }
        }
        .frame(width: 560)
    }
}

struct NodesSettingsView: View {
    @EnvironmentObject private var store: FleetStore

    var body: some View {
        Form {
            Section("Known Nodes") {
                ForEach(store.nodes) { node in
                    HStack {
                        HealthDot(online: node.online)
                        VStack(alignment: .leading) {
                            Text(node.displayName)
                            Text("\(node.source.rawValue) · \(node.url.absoluteString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { store.removeNode(key: node.key) }
                    }
                }
                if store.nodes.isEmpty {
                    Text("No nodes known yet.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}

// ---------------------------------------------------------------- agents

/// What the banner claims about this Mac, derived from one snapshot.
enum AgentsBanner: Equatable {
    case checking
    case fresh          // nothing installed → Set Up This Mac
    case updateAvailable
    case current
    case devOnly        // every detected agent is wired to a checkout
    case noPayload      // not running from a bundled app
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published var snapshot: InstallerSnapshot?
    @Published var busy = false
    @Published var lastError: String?
    @Published var showLog = false

    let engine = InstallerEngine()

    /// Debug builds render everything but mutate nothing: a debug app must
    /// never fight the release wiring (hard rule in CLAUDE.md).
    let actionsAllowed = Bundle.main.bundleIdentifier?.hasSuffix(".debug") != true

    var transcript: String { engine.transcript }

    var banner: AgentsBanner {
        guard let snap = snapshot else { return .checking }
        if snap.bundledCLIVersion == nil { return .noPayload }
        let detected = [snap.claude, snap.pi].filter(\.detected)
        let actionable = detected.filter {
            if case .devCheckout = $0.wiring { return false } else { return true }
        }
        if actionable.isEmpty && !detected.isEmpty && snap.installedCLIVersion == nil {
            return .devOnly
        }
        if snap.installedCLIVersion == nil { return .fresh }
        if snap.installedCLIVersion != snap.bundledCLIVersion { return .updateAvailable }
        for agent in [snap.claude] {   // pi is live; only Claude's cache lags
            if case .installed(let version) = agent.wiring,
               version != nil, version != snap.bundledPluginVersion {
                return .updateAvailable
            }
        }
        if actionable.contains(where: { $0.wiring == .notInstalled }) { return .fresh }
        return .current
    }

    func refresh() {
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let snap = engine.snapshot()
            await MainActor.run { self?.snapshot = snap }
        }
    }

    /// Every mutation follows the same shape: run on a background task,
    /// re-snapshot, surface the first failure line.
    private func perform(_ label: String,
                         _ work: @escaping (InstallerEngine) throws -> Bool) {
        guard actionsAllowed, !busy else { return }
        busy = true
        lastError = nil
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            do {
                if try !work(engine) { failure = "\(label) failed — see the log." }
            } catch {
                failure = error.localizedDescription
            }
            let snap = engine.snapshot()
            await MainActor.run {
                self?.snapshot = snap
                self?.lastError = failure
                self?.busy = false
            }
        }
    }

    func setUpThisMac() {
        let wireable = snapshot.map { snap in
            (claude: snap.claude.wiring == .notInstalled,
             pi: snap.pi.wiring == .notInstalled)
        } ?? (claude: false, pi: false)
        perform("Set up") { engine in
            try engine.materialize()
            try engine.linkCLI()
            var ok = true
            if wireable.claude { ok = engine.wireClaude() && ok }
            if wireable.pi { ok = engine.wirePi() && ok }
            return ok
        }
    }

    func updateAll() {
        let claudeInstalled = snapshot.map { snap in
            if case .installed = snap.claude.wiring { return true } else { return false }
        } ?? false
        perform("Update") { engine in
            try engine.materialize()
            try engine.linkCLI()
            return claudeInstalled ? engine.updateClaude() : true
        }
    }

    func installClaude() {
        perform("Install") { engine in
            try engine.materialize()
            try engine.linkCLI()
            return engine.wireClaude()
        }
    }

    func installPi() {
        perform("Install") { engine in
            try engine.materialize()
            try engine.linkCLI()
            return engine.wirePi()
        }
    }

    func uninstallClaude() { perform("Uninstall") { $0.unwireClaude() } }
    func uninstallPi() { perform("Uninstall") { $0.unwirePi() } }
}

struct AgentsSettingsView: View {
    @StateObject private var model = InstallerModel()

    var body: some View {
        VStack(spacing: 0) {
            bannerView
            Form {
                commandLineSection
                agentSections
                if !model.actionsAllowed {
                    Section {
                        Label("Debug build: installation is disabled so it can't fight the release wiring.",
                              systemImage: "ladybug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 480)
        .overlay(alignment: .bottomTrailing) {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .padding(10)
            .disabled(model.busy)
        }
        .sheet(isPresented: $model.showLog) { logSheet }
        .onAppear { model.refresh() }
    }

    // ------------------------------------------------------------- banner

    @ViewBuilder private var bannerView: some View {
        HStack(spacing: 12) {
            switch model.banner {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking this Mac…").foregroundStyle(.secondary)
            case .noPayload:
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text("This build carries no payload — run a bundled app to install.")
                    .foregroundStyle(.secondary)
            case .devOnly:
                Image(systemName: "flag").foregroundStyle(.orange)
                Text("Development wiring — this Mac is driven from a checkout, left alone.")
            case .fresh:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This Mac isn't fully set up for agent scheduling.")
                Spacer()
                Button("Set Up This Mac") { model.setUpThisMac() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.actionsAllowed || model.busy)
            case .updateAvailable:
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text(updateText)
                Spacer()
                Button("Update All") { model.updateAll() }
                    .disabled(!model.actionsAllowed || model.busy)
            case .current:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Everything is installed and current.")
            }
            if model.banner != .fresh && model.banner != .updateAvailable { Spacer() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4))
    }

    private var updateText: String {
        let bundled = model.snapshot?.bundledCLIVersion ?? "?"
        let installed = model.snapshot?.installedCLIVersion
            ?? model.snapshot?.installedPluginVersion ?? "?"
        return "Update available — this app carries \(bundled); this Mac runs \(installed)."
    }

    // ------------------------------------------------- command-line tool

    @ViewBuilder private var commandLineSection: some View {
        Section("Command-Line Tool") {
            LabeledContent("Bundled with this app") {
                Text(model.snapshot?.bundledCLIVersion ?? "—")
            }
            LabeledContent("Installed on this Mac") {
                if let version = model.snapshot?.installedCLIVersion {
                    HStack(spacing: 6) {
                        Text(version)
                        if version == model.snapshot?.bundledCLIVersion {
                            StatusMark(ok: true, text: "current")
                        } else {
                            Text("↑ will update").foregroundStyle(.blue)
                        }
                    }
                } else {
                    Text("not installed").foregroundStyle(.secondary)
                }
            }
            if model.snapshot?.installedCLIVersion != nil,
               let dir = model.snapshot?.payloadDir {
                Text(abbreviate(dir))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("On PATH") {
                if let path = model.snapshot?.cliOnPath {
                    HStack(spacing: 6) {
                        StatusMark(ok: true, text: nil)
                        Text(abbreviate(path)).font(.caption)
                    }
                } else {
                    Text("not on PATH").foregroundStyle(.secondary)
                }
            }
        }
    }

    // ------------------------------------------------------- agent rows

    @ViewBuilder private var agentSections: some View {
        Section("Agent Plugins") {
            agentRow(
                title: "Claude Code",
                status: model.snapshot?.claude,
                wiringLine: { wiring in
                    switch wiring {
                    case .installed(let version):
                        return "continuation@continuation · \(version ?? "?")"
                    default:
                        return "continuation:schedule"
                    }
                },
                install: model.installClaude,
                uninstall: model.uninstallClaude,
                footnote: "New sessions pick up changes after restart.")
            agentRow(
                title: "pi",
                status: model.snapshot?.pi,
                wiringLine: { wiring in
                    if case .installed = wiring {
                        return "package · live from the installed copy"
                    }
                    return "continuation:schedule"
                },
                install: model.installPi,
                uninstall: model.uninstallPi,
                footnote: nil)
            if let error = model.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(.caption)
                    Spacer()
                    Button("Show Log") { model.showLog = true }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func agentRow(title: String, status: AgentStatus?,
                          wiringLine: (PluginWiring) -> String,
                          install: @escaping () -> Void,
                          uninstall: @escaping () -> Void,
                          footnote: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                if let version = status?.binaryVersion {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            switch status?.wiring {
            case .none:
                Text("—").foregroundStyle(.secondary)
            case .agentMissing:
                HStack {
                    Text("not found on this Mac — install it, then Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install") {}.disabled(true)
                }
            case .devCheckout(let path):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("wired to a development checkout — left alone")
                            .font(.caption)
                        Text(abbreviate(path)).font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "flag.fill").foregroundStyle(.orange)
                }
            case .notInstalled:
                HStack {
                    Text(wiringLine(.notInstalled)).font(.caption)
                    Text("not installed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Install", action: install)
                        .disabled(!model.actionsAllowed || model.busy)
                }
            case .installed(let version):
                HStack(spacing: 6) {
                    Text(wiringLine(.installed(version: version))).font(.caption)
                    if claudeLags(version) {
                        Text("→ \(model.snapshot?.bundledPluginVersion ?? "?")")
                            .font(.caption).foregroundStyle(.blue)
                    } else {
                        StatusMark(ok: true, text: "current")
                    }
                    Spacer()
                    Button("Uninstall", action: uninstall)
                        .disabled(!model.actionsAllowed || model.busy)
                }
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Only a version-carrying (Claude) wiring can lag; pi's is live.
    private func claudeLags(_ version: String?) -> Bool {
        guard let version, let bundled = model.snapshot?.bundledPluginVersion
        else { return false }
        return version != bundled
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count)
            : path
    }

    // ---------------------------------------------------------------- log

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installer Log").font(.headline)
            ScrollView {
                Text(model.transcript.isEmpty ? "Nothing run yet." : model.transcript)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { model.showLog = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
    }
}

struct StatusMark: View {
    let ok: Bool
    let text: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .imageScale(.small)
            if let text {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
