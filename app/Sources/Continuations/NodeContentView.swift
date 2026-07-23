import ContinuationsKit
import SwiftUI

struct NodeContentView: View {
    @EnvironmentObject private var store: FleetStore
    let nodeKey: String
    @Binding var selection: DetailSelection?
    @State private var segment: Segment = .queue

    enum Segment: String, CaseIterable {
        case queue = "Queue"
        case tasks = "Tasks"
        case history = "History"
    }

    var body: some View {
        if let node = store.node(key: nodeKey) {
            VStack(spacing: 0) {
                header(node)
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .bottom], 10)
                Divider()
                switch segment {
                case .queue:
                    UnifiedQueueView(scope: .node(nodeKey), selection: $selection)
                case .tasks:
                    TaskListView(nodeKey: nodeKey, selection: $selection)
                case .history:
                    NodeHistoryView(nodeKey: nodeKey)
                }
            }
            .navigationTitle(node.displayName)
        } else {
            ContentUnavailableView("Node removed", systemImage: "questionmark.circle")
        }
    }

    private func header(_ node: NodeState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                HealthDot(online: node.online)
                Text(node.displayName)
                    .font(.headline)
                if node.online {
                    Text("healthy")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let seen = node.lastSeen {
                    Text("offline · as of \(seen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let info = node.info {
                HStack(spacing: 4) {
                    Text("v\(info.version)")
                    Text("·")
                    Text("last tick \(Format.timestamp(info.lastTickAt))")
                    if let loaded = info.tickAgentLoaded {
                        Text("·")
                        Text(loaded ? "tick agent loaded" : "tick agent NOT loaded")
                            .foregroundStyle(loaded ? Color.secondary : .red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(node.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct TaskListView: View {
    @EnvironmentObject private var store: FleetStore
    let nodeKey: String
    @Binding var selection: DetailSelection?
    @State private var tasks: [TaskInfo] = []
    @State private var failure: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(task.id).fontWeight(.medium)
                        if task.singleRun {
                            Text("single-run")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                        }
                        if !task.enabled {
                            Text("disabled")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(task.agent) · \(task.continuation.schedule?.label ?? "—") · \(task.runCount) run(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(DetailSelection.task(nodeKey: nodeKey, taskID: task.id))
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .overlay {
            if tasks.isEmpty && failure == nil {
                ContentUnavailableView("No tasks registered", systemImage: "square.stack.3d.up.slash")
            }
        }
        .task(id: refreshKey) { await load() }
    }

    /// Reload when this node writes task-shaped events.
    private var refreshKey: String {
        let relevant = store.activity.first {
            $0.nodeKey == nodeKey
                && ["register", "unregister", "tick.run-settled"].contains($0.event.cmd)
        }
        return "\(nodeKey)|\(relevant?.event.id ?? 0)"
    }

    private func load() async {
        guard let client = store.client(key: nodeKey) else { return }
        do {
            tasks = try await client.tasks()
            failure = nil
        } catch {
            failure = tasks.isEmpty ? error.localizedDescription : nil
        }
    }
}

struct NodeHistoryView: View {
    @EnvironmentObject private var store: FleetStore
    let nodeKey: String
    @State private var events: [EventRow] = []

    var body: some View {
        List(merged) { event in
            EventRowView(event: event, nodeName: nil)
        }
        .task { await load() }
    }

    /// Backfill (fetched once) merged with the live tail already in the
    /// fleet activity feed, deduplicated by event id.
    private var merged: [EventRow] {
        let live = store.activity.filter { $0.nodeKey == nodeKey }.map(\.event)
        var seen = Set<Int>()
        return (live + events)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id > $1.id }
    }

    private func load() async {
        guard let client = store.client(key: nodeKey) else { return }
        events = (try? await client.log(limit: 300)) ?? []
    }
}

struct EventRowView: View {
    let event: EventRow
    let nodeName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Format.clock(event.ts))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Circle()
                .fill(Format.outcomeColor(event.outcome))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.cmd).fontWeight(.medium)
                    Text(event.actor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let nodeName {
                        Spacer()
                        NodeChip(name: nodeName)
                    }
                }
                if event.taskID != nil || event.continuationID != nil {
                    Text([event.taskID, event.runID, event.continuationID]
                        .compactMap { $0 }.joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 1)
    }
}
