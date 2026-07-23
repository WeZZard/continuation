import ContinuationsKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: FleetStore
    @State private var sidebar: SidebarSelection? = .all
    @State private var detail: DetailSelection?
    @State private var showAddNode = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar, showAddNode: $showAddNode)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            detailColumn
        }
        .sheet(isPresented: $showAddNode) {
            AddNodeSheet()
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch sidebar ?? .all {
        case .all:
            UnifiedQueueView(scope: .all, selection: $detail)
                .navigationTitle("All Continuations")
        case .attention:
            UnifiedQueueView(scope: .attention, selection: $detail)
                .navigationTitle("Needs Attention")
        case .activity:
            ActivityView()
                .navigationTitle("Activity")
        case .node(let key):
            NodeContentView(nodeKey: key, selection: $detail)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch detail {
        case .entry(let id):
            if let fleetEntry = store.entry(id: id) {
                ContinuationDetailView(fleetEntry: fleetEntry)
                    .id(fleetEntry.id)
            } else {
                ContentUnavailableView(
                    "Entry left the queue",
                    systemImage: "checkmark.circle",
                    description: Text("It was consumed, ended, or its node was removed."))
            }
        case .task(let nodeKey, let taskID):
            TaskDetailView(nodeKey: nodeKey, taskID: taskID)
                .id("\(nodeKey)/\(taskID)")
        case nil:
            ContentUnavailableView(
                "No selection",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Select a continuation, task, or node."))
        }
    }
}

extension FleetStore {
    func entry(id: String) -> FleetEntry? {
        (dueEntries + scheduledEntries + attentionEntries).first { $0.id == id }
    }
}
