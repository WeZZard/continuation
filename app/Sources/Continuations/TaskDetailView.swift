import ContinuationsKit
import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: FleetStore
    let nodeKey: String
    let taskID: String

    @State private var task: TaskInfo?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let task {
                    header(task)
                    if !task.mustNot.isEmpty {
                        section("Must Not") {
                            ForEach(task.mustNot, id: \.self) { rule in
                                Label(rule, systemImage: "hand.raised")
                                    .font(.callout)
                            }
                        }
                    }
                    section("Runs (\(task.runCount))") {
                        ForEach(task.runs ?? []) { run in
                            runView(run)
                        }
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .navigationTitle(taskID)
        .task(id: "\(nodeKey)/\(taskID)") { await load() }
    }

    private func header(_ task: TaskInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("Agent").foregroundStyle(.secondary)
                Text(task.agent)
            }
            GridRow {
                Text("Registered").foregroundStyle(.secondary)
                Text(Format.timestamp(task.registeredAt))
            }
            GridRow {
                Text("Mode").foregroundStyle(.secondary)
                Text((task.singleRun ? "single-run" : "recurring")
                     + (task.enabled ? "" : " · disabled"))
            }
            GridRow {
                Text("Schedule").foregroundStyle(.secondary)
                Text(task.continuation.schedule?.label ?? "—")
            }
            if let active = task.activeRun {
                GridRow {
                    Text("Active run").foregroundStyle(.secondary)
                    Text(active).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }

    private func runView(_ run: RunDetail) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(run.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Format.statusColor(entry.status))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(entry.cid).fontWeight(.medium)
                                Text(entry.status)
                                    .font(.caption)
                                    .foregroundStyle(Format.statusColor(entry.status))
                                Text("· \(entry.evaluations) evaluation(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let summary = entry.lastSummary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(run.runID).font(.callout.monospacedDigit())
                Text(run.settled ? "settled" : "open")
                    .font(.caption)
                    .foregroundStyle(run.settled ? .green : .blue)
                if run.leasedBy != nil {
                    Text("evaluating…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func load() async {
        guard let client = store.client(key: nodeKey) else { return }
        do {
            task = try await client.taskDetail(taskID)
            failure = nil
        } catch {
            failure = "Could not load the task: \(error.localizedDescription)"
        }
    }
}
