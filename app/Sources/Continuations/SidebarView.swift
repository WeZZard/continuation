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

    private func projectName(_ path: String) -> String {
        path.isEmpty ? "—" : (path as NSString).lastPathComponent
    }

    /// One row per session: waiting rows are actionable, running rows
    /// state their presence.
    @ViewBuilder
    private func sessionRow(nodeKey: String, nodeName: String,
                            project: String, agent: String,
                            review: ReviewItem?) -> some View {
        Button {
            if let review {
                openReview = ReviewSheetTarget(nodeKey: nodeKey, item: review)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(review.map { $0.summary.isEmpty ? project : $0.summary }
                         ?? project)
                        .lineLimit(1)
                    Text(review == nil
                         ? "\(agent) · running · \(nodeName)"
                         : "\(agent) · \(project) · \(nodeName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: review.map { ReviewKindIcon.name($0.kind) }
                      ?? "circle.dashed")
                    .foregroundStyle(review == nil ? .secondary : .primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(review == nil)
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
            // Supervised sessions: idle ones are waiting on you and open
            // the console; busy ones state their presence.
            if !store.sessionRows.isEmpty || !store.orphanReviewRows.isEmpty {
                Section("Review") {
                    ForEach(store.sessionRows, id: \.session.id) { row in
                        sessionRow(nodeKey: row.nodeKey, nodeName: row.nodeName,
                                   project: projectName(row.session.cwd),
                                   agent: row.session.agent,
                                   review: row.review)
                    }
                    ForEach(store.orphanReviewRows, id: \.item.id) { row in
                        sessionRow(nodeKey: row.nodeKey, nodeName: row.nodeName,
                                   project: projectName(row.item.cwd),
                                   agent: row.item.agent, review: row.item)
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
