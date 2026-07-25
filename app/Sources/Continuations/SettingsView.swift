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
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(node.displayName)
                                if node.isLocal {
                                    Text("(This Mac)").foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 6) {
                                HealthDot(online: node.online)
                                Text("\(node.source == .bonjour ? "discovered" : "manual") · \(node.url.absoluteString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        // Vertically centered against the whole cell.
                        if node.source == .bonjour {
                            // A discovered node re-appears on the next
                            // Bonjour tick — removal would be a lie.
                            HStack(spacing: 6) {
                                Text("Exclude")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle("Exclude", isOn: Binding(
                                    get: { node.excluded },
                                    set: { store.setExcluded($0, key: node.key) }))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                            }
                        } else {
                            Button("Remove") { store.removeNode(key: node.key) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if store.nodes.isEmpty {
                    Text("No nodes known yet.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// ---------------------------------------------------------------- agents

@MainActor
final class InstallerModel: ObservableObject {
    @Published var snapshot: InstallerSnapshot?
    @Published var busy = false
    @Published var lastError: String?
    /// A background synchronization failure — reported on the section's
    /// status line, with the cell's action left as the recovery.
    @Published var syncFailure: String?

    let engine = InstallerEngine()

    /// Status costs a subprocess per agent: on appearance, after any
    /// operation, and on a slower cadence.
    func refresh(syncing: Bool = false) {
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let snap = engine.snapshot()
            await self?.apply(snapshot: snap)
            if syncing { await self?.synchronizeInBackground(snap) }
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

    /// An app update carrying a newer plugin runs WITHOUT the sheet and
    /// reports its failure on the status line.
    private func synchronizeInBackground(_ snap: InstallerSnapshot) {
        let stale = snap.agents.filter {
            if case .installed(_, _, let update) = $0.installation { return update }
            return false
        }
        guard !stale.isEmpty else { return }
        let engine = self.engine
        Task.detached(priority: .utility) { [weak self] in
            var failures: [String] = []
            do {
                try engine.prepare()
            } catch {
                await self?.report(sync: error.localizedDescription)
                return
            }
            for agent in stale {
                let plan = OperationPlanner.plan(.update, for: agent,
                                                 paths: engine.paths)
                for step in plan.steps {
                    let result = engine.run(argv: step.argv)
                    if result.status != 0 {
                        let text = result.stderr
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        failures.append("\(agent.kind.displayName): "
                            + (text.isEmpty ? "`\(step.display)` failed" : text))
                        break
                    }
                }
            }
            let refreshed = engine.snapshot()
            await self?.apply(snapshot: refreshed)
            await self?.report(sync: failures.isEmpty
                ? nil
                : "Could not update the installed plugin — " + failures.joined(separator: "; "))
        }
    }

    private func report(sync failure: String?) {
        syncFailure = failure
    }

    /// The CLI panel's own button; the agents' plugins go through the
    /// operation sheet instead.
    private func perform(_ label: String,
                         _ work: @escaping (InstallerEngine) throws -> Bool) {
        guard !busy else { return }
        busy = true
        lastError = nil
        let engine = self.engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String?
            do {
                failure = try work(engine) ? nil : "\(label) failed."
            } catch {
                failure = error.localizedDescription
            }
            let snap = engine.snapshot()
            await self?.apply(snapshot: snap, failure: failure, endBusy: true)
        }
    }

    func installCLI() {
        perform("Install") { engine in
            try engine.prepare()
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
    @State private var operation: OperationSheetModel?

    var body: some View {
        Form {
            Section {
                ForEach(model.snapshot?.agents ?? []) { agent in
                    AgentCellView(status: agent) { verb in
                        present(verb, for: agent)
                    }
                }
                if model.snapshot == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the agents…").foregroundStyle(.secondary)
                    }
                }
                if let failure = model.syncFailure {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $operation) { sheet in
            OperationSheetView(model: sheet)
        }
        .onAppear { model.refresh(syncing: true) }
        .task {
            // The slower cadence; detection stays cheap in between.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.refresh()
            }
        }
    }

    /// The cell's action opens the sheet; nothing runs from the cell.
    private func present(_ verb: OperationVerb, for agent: AgentStatus) {
        operation = OperationSheetModel(
            plan: OperationPlanner.plan(verb, for: agent, paths: model.engine.paths),
            engine: model.engine,
            onFinish: { model.refresh() })
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
            .scrollDisabled(true)
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
