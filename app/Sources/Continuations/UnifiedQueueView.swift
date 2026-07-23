import ContinuationsKit
import SwiftUI

struct UnifiedQueueView: View {
    enum Scope {
        case all              // due + scheduled across the fleet
        case state(String)    // one stuck pile: expired | invalid | paused
        case node(String)     // one node, all sections
    }

    @EnvironmentObject private var store: FleetStore
    let scope: Scope
    @Binding var selection: DetailSelection?
    @State private var search = ""

    var body: some View {
        let sections = self.sections
        List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) { rows(section.entries) }
            }
            if sections.isEmpty {
                ContentUnavailableView(
                    "The queue is empty",
                    systemImage: "tray",
                    description: Text("Nothing is pending on the reachable nodes."))
            }
        }
        .searchable(text: $search, prompt: "Task, step, or summary")
    }

    private func rows(_ entries: [FleetEntry]) -> some View {
        ForEach(entries) { fleetEntry in
            EntryRow(fleetEntry: fleetEntry)
                .tag(DetailSelection.entry(fleetEntry.id))
        }
    }

    private var sections: [(title: String, entries: [FleetEntry])] {
        let raw: [(String, [FleetEntry])]
        switch scope {
        case .all:
            raw = [("Due", store.dueEntries), ("Scheduled", store.scheduledEntries)]
        case .state(let state):
            raw = [(state.capitalized, store.entries(state: state))]
        case .node(let key):
            raw = ([("Due", store.dueEntries), ("Scheduled", store.scheduledEntries)]
                   + StuckState.all.map { ($0.capitalized, store.entries(state: $0)) })
                .map { ($0.0, $0.1.filter { $0.nodeKey == key }) }
        }
        return raw
            .map { (title: $0.0, entries: filter($0.1)) }
            .filter { !$0.entries.isEmpty }
    }

    private func filter(_ entries: [FleetEntry]) -> [FleetEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.entry.task.localizedCaseInsensitiveContains(search)
                || $0.entry.continuation.localizedCaseInsensitiveContains(search)
                || ($0.entry.lastSummary ?? "").localizedCaseInsensitiveContains(search)
        }
    }
}

struct EntryRow: View {
    let fleetEntry: FleetEntry

    var body: some View {
        let entry = fleetEntry.entry
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Format.stateColor(entry.state))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.continuation)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    NodeChip(name: fleetEntry.nodeName)
                }
                HStack(spacing: 4) {
                    Text(entry.task)
                    Text("·")
                    Text(entry.schedule?.label ?? "—")
                    Text("·")
                    Text(timing)
                        .foregroundStyle(entry.state == "due" ? .primary : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let summary = entry.lastSummary, !summary.isEmpty {
                    Text("“\(summary)”")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(fleetEntry.nodeOnline ? 1 : 0.55)
    }

    private var timing: String {
        let entry = fleetEntry.entry
        switch entry.state {
        case "due":
            if let date = StoreDate.parse(entry.activation) {
                return Format.relative(date)  // "32m overdue"
            }
            return "due now"
        case "scheduled":
            return Format.activation(entry.activation)
        default:
            return entry.state
        }
    }
}
