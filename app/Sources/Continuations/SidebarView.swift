import ContinuationsKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: FleetStore
    @Binding var selection: SidebarSelection?
    @Binding var showAddNode: Bool
    @State private var openReview: ReviewSheetTarget?

    struct ReviewSheetTarget: Identifiable {
        let nodeKey: String
        let item: ReviewItem
        var id: String { "\(nodeKey)#\(item.id)" }
    }

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
            // Sessions waiting on the human, present only while any are.
            if !store.reviewRows.isEmpty {
                Section("Review") {
                    ForEach(store.reviewRows, id: \.item.id) { row in
                        Button {
                            openReview = ReviewSheetTarget(
                                nodeKey: row.nodeKey, item: row.item)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.item.summary.isEmpty
                                         ? row.item.kind : row.item.summary)
                                        .lineLimit(1)
                                    Text("\(row.item.agent) · \(row.nodeName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName:
                                    ReviewKindIcon.name(row.item.kind))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
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
        .sheet(item: $openReview) { target in
            ReviewConsoleView(nodeKey: target.nodeKey, item: target.item)
        }
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
