import ContinuationsKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var installer = InstallerModel()

    var body: some View {
        TabView {
            GeneralSettingsView(model: installer)
                .tabItem { Label("General", systemImage: "gearshape") }
            NodesSettingsView()
                .tabItem { Label("Nodes", systemImage: "point.3.connected.trianglepath.dotted") }
            CLISettingsView(model: installer)
                .tabItem { Label("CLI", systemImage: "terminal") }
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
                            HStack(spacing: 4) {
                                Text(node.displayName)
                                if node.isLocal {
                                    Text("(This Mac)").foregroundStyle(.secondary)
                                }
                            }
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

// ---------------------------------------------------------------- agents

/// What the banner claims about this Mac, derived from one snapshot.
enum AgentsBanner: Equatable {
    case checking
    case fresh          // a detected agent is unwired → Set Up This Mac
    case updateAvailable
    case current
    case noPayload      // not running from a bundled app
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published var snapshot: InstallerSnapshot?
    @Published var busy = false
    @Published var lastError: String?
    @Published var showLog = false

    let engine = InstallerEngine()

    var transcript: String { engine.transcript }

    var banner: AgentsBanner {
        guard let snap = snapshot else { return .checking }
        if snap.bundledCLIVersion == nil { return .noPayload }
        let detected = [snap.claude, snap.pi].filter(\.detected)
        if detected.contains(where: { $0.wiring == .notInstalled }) { return .fresh }
        if let installed = snap.installedCLIVersion,
           installed != snap.bundledCLIVersion { return .updateAvailable }
        // pi wiring is live; only Claude's version-keyed cache can lag.
        if case .installed(let version) = snap.claude.wiring,
           version != nil, version != snap.bundledPluginVersion {
            return .updateAvailable
        }
        return .current
    }

    func refresh() {
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let snap = engine.snapshot()
            await self?.apply(snapshot: snap)
        }
    }

    private func apply(snapshot snap: InstallerSnapshot,
                       failure: String? = nil, endBusy: Bool = false) {
        snapshot = snap
        if endBusy {
            lastError = failure
            busy = false
        }
    }

    /// Every mutation follows the same shape: run on a background task,
    /// re-snapshot, surface the first failure line.
    private func perform(_ label: String,
                         _ work: @escaping (InstallerEngine) throws -> Bool) {
        guard !busy else { return }
        busy = true
        lastError = nil
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String?
            do {
                failure = try work(engine) ? nil : "\(label) failed — see the log."
            } catch {
                failure = error.localizedDescription
            }
            let snap = engine.snapshot()
            await self?.apply(snapshot: snap, failure: failure, endBusy: true)
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

    func uninstallPi() {
        let wiredPath: String? = {
            if case .devCheckout(let path) = snapshot?.pi.wiring { return path }
            return nil
        }()
        perform("Uninstall") { $0.unwirePi(sourcePath: wiredPath) }
    }

    func installCLI() {
        perform("Install") { engine in
            try engine.materialize()
            try engine.linkCLI()
            return true
        }
    }

    func uninstallCLI() {
        perform("Uninstall") { engine in
            try engine.unlinkCLI()
            return true
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: InstallerModel
    @State private var confirmUninstall: AgentLogo?
    /// The second line cycles per click: indicator → location → copy the
    /// location (flash "Copied", settle back to the location) → indicator.
    @State private var revealPhase: [AgentLogo: Int] = [:]
    @State private var copiedFlash: Set<AgentLogo> = []

    /// The banner exists only when something needs doing; a healthy Mac
    /// shows no recap.
    private var showsBanner: Bool {
        switch model.banner {
        case .fresh, .updateAvailable, .noPayload: return true
        case .checking, .current: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsBanner { bannerView }
            Form {
                agentSections
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        }
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
        .confirmationDialog(
            "Uninstall the plugin from \(confirmUninstall == .pi ? "pi" : "Claude Code")?",
            isPresented: Binding(
                get: { confirmUninstall != nil },
                set: { if !$0 { confirmUninstall = nil } }),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                switch confirmUninstall {
                case .claude: model.uninstallClaude()
                case .pi: model.uninstallPi()
                case nil: break
                }
                confirmUninstall = nil
            }
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
        } message: {
            Text("Removes the wiring from the agent. No files are deleted.")
        }
        .onAppear { model.refresh() }
    }

    // ------------------------------------------------------------- banner

    @ViewBuilder private var bannerView: some View {
        HStack(spacing: 12) {
            switch model.banner {
            case .noPayload:
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text("This build carries no payload — run a bundled app to install.")
                    .foregroundStyle(.secondary)
                Spacer()
            case .fresh:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This Mac isn't fully set up for agent scheduling.")
                Spacer()
                Button("Set Up This Mac") { model.setUpThisMac() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            case .updateAvailable:
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text(updateText)
                Spacer()
                Button("Update All") { model.updateAll() }
                    .disabled(model.busy)
            case .checking, .current:
                EmptyView()
            }
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

    // ------------------------------------------------------- agent rows

    @ViewBuilder private var agentSections: some View {
        Section("Agent Plugins") {
            agentRow(logo: .claude, title: "Claude Code",
                     status: model.snapshot?.claude, install: model.installClaude)
            agentRow(logo: .pi, title: "pi",
                     status: model.snapshot?.pi, install: model.installPi)
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

    /// The agent name's cap height, rounded to whole points: the logo
    /// matches it and sits on the baseline, an inline mark, not a badge.
    private static let nameCapHeight =
        NSFont.systemFont(ofSize: NSFont.systemFontSize).capHeight.rounded()

    /// Line 1: logo + name + (version) left, the action button right.
    /// Line 2: the installed-state indicator; clicking it swaps in the
    /// plugin location, clicking again swaps back.
    @ViewBuilder
    private func agentRow(logo: AgentLogo, title: String, status: AgentStatus?,
                          install: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AgentLogoView(logo: logo, size: Self.nameCapHeight)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(title)
                    if let version = status?.binaryVersion?
                        .components(separatedBy: " ").first {
                        Text("(\(version))").foregroundStyle(.secondary)
                    }
                }
                Button {
                    let phase = ((revealPhase[logo] ?? 0) + 1) % 3
                    revealPhase[logo] = phase
                    if phase == 2 {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(locationLine(for: status), forType: .string)
                        copiedFlash.insert(logo)
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedFlash.remove(logo)
                        }
                    }
                } label: {
                    if (revealPhase[logo] ?? 0) == 0 {
                        statusIndicator(installed: isWired(status))
                    } else {
                        Text(copiedFlash.contains(logo)
                             ? "Copied" : locationLine(for: status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Vertically centered against the whole cell.
            Group {
                switch status?.wiring {
                case .installed, .devCheckout:
                    Button("Uninstall…") { confirmUninstall = logo }
                        .disabled(model.busy)
                case .notInstalled:
                    Button("Install", action: install)
                        .disabled(model.busy)
                case .agentMissing:
                    Button("Install", action: install).disabled(true)
                case nil:
                    EmptyView()
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func isWired(_ status: AgentStatus?) -> Bool {
        switch status?.wiring {
        case .installed, .devCheckout: return true
        default: return false
        }
    }

    private func statusIndicator(installed: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(installed ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(installed ? "Installed" : "Not Installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func locationLine(for status: AgentStatus?) -> String {
        switch status?.wiring {
        case .devCheckout(let path):
            return abbreviate(path)
        case .installed:
            return abbreviate((model.snapshot?.payloadDir ?? "")
                + "/plugins/continuation")
        case .notInstalled:
            return "—"
        case .agentMissing:
            return "not found on this Mac"
        case nil:
            return "—"
        }
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

private func abbreviate(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home)
        ? "~" + path.dropFirst(home.count)
        : path
}

/// The CLI panel: the command's state, and one button — Install when the
/// command is absent from PATH, Uninstall when present.
struct CLISettingsView: View {
    @ObservedObject var model: InstallerModel
    @State private var confirmUninstall = false

    private var cliInstalled: Bool { model.snapshot?.cliOnPath != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.bottom, 6)
            }
            Button(cliInstalled ? "Uninstall" : "Install") {
                if cliInstalled {
                    confirmUninstall = true
                } else {
                    model.installCLI()
                }
            }
            .disabled(model.busy
                || (!cliInstalled && model.snapshot?.bundledCLIVersion == nil))
            .padding(.bottom, 16)
        }
        .confirmationDialog(
            "Uninstall the `continuation` command?",
            isPresented: $confirmUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { model.uninstallCLI() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the command from PATH. No files are deleted.")
        }
        .onAppear { model.refresh() }
    }
}

/// Each agent is identified by its own mark: Claude Code by the Claude
/// spark (the vendor's published icon, used nominatively to identify the
/// product), pi by the π glyph — which IS its mark: pi's own app title is
/// the bare glyph.
enum AgentLogo {
    case claude
    case pi
}

struct AgentLogoView: View {
    let logo: AgentLogo
    var size: CGFloat = 22

    private var corner: CGFloat { size * 0.23 }

    var body: some View {
        switch logo {
        case .claude:
            if let url = Bundle.module.url(forResource: "claude-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(red: 0.80, green: 0.42, blue: 0.30))
                    .frame(width: size, height: size)
                    .overlay(Text("✳︎").font(.system(size: size * 0.55))
                        .foregroundStyle(.white))
            }
        case .pi:
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(white: 0.13))
                .frame(width: size, height: size)
                .overlay(
                    Text("π")
                        .font(.system(size: size * 0.64, weight: .semibold, design: .serif))
                        .foregroundStyle(.white))
        }
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
