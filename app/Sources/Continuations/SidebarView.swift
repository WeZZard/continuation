import ContinuationsKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: FleetStore
    @Binding var selection: SidebarSelection?
    @Binding var showAddNode: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Fleet") {
                Label("All Continuations", systemImage: "tray.full")
                    .badge(store.dueCount)
                    .tag(SidebarSelection.all)
                // One row per stuck pile, present only while non-empty.
                ForEach(store.stuckCounts, id: \.state) { pile in
                    Label(pile.state.capitalized,
                          systemImage: StuckState.icon(pile.state))
                        .badge(pile.count)
                        .tag(SidebarSelection.state(pile.state))
                }
                Label("Activity", systemImage: "waveform.path.ecg")
                    .tag(SidebarSelection.activity)
            }
            Section("Nodes") {
                ForEach(store.nodes.filter { !$0.excluded }) { node in
                    HStack(spacing: 8) {
                        HealthDot(online: node.online)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.displayName)
                            if node.isLocal {
                                Text("This Mac")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !node.online, let seen = node.lastSeen {
                                Text("as of \(seen.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .badge(node.pendingCount)
                    .tag(SidebarSelection.node(node.key))
                    .contextMenu {
                        Button("Remove Node", role: .destructive) {
                            store.removeNode(key: node.key)
                        }
                    }
                }
                Button {
                    showAddNode = true
                } label: {
                    Label("Add Node…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .overlay(alignment: .bottom) {
            if store.nodes.isEmpty {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Scanning the local network…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 24)
            }
        }
    }
}
