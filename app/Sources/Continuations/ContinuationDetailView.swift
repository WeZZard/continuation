import ContinuationsKit
import SwiftUI

struct ContinuationDetailView: View {
    @EnvironmentObject private var store: FleetStore
    let fleetEntry: FleetEntry

    @State private var taskInfo: TaskInfo?
    @State private var runEntry: RunEntry?
    @State private var evaluations: [EventRow] = []
    @State private var prompts: [PromptInfo] = []
    @State private var openPrompt: PromptInfo?
    @State private var failure: String?

    var body: some View {
        let entry = fleetEntry.entry
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(entry)
                Divider()
                if let core = runEntry?.core ?? taskInfo?.continuation {
                    coreSections(core)
                }
                evaluationSection
                if let mustNot = taskInfo?.mustNot, !mustNot.isEmpty {
                    section("Task Constraints") {
                        ForEach(mustNot, id: \.self) { rule in
                            Label(rule, systemImage: "hand.raised")
                                .font(.callout)
                        }
                    }
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .navigationTitle(entry.continuation)
        .task(id: fleetEntry.id) { await load() }
        .sheet(item: $openPrompt) { prompt in
            PromptViewer(nodeKey: fleetEntry.nodeKey, task: entry.task,
                         run: entry.run, prompt: prompt)
        }
    }

    private func header(_ entry: QueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Task").foregroundStyle(.secondary)
                    Text(entry.task).fontWeight(.medium)
                }
                GridRow {
                    Text("Node").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        HealthDot(online: fleetEntry.nodeOnline)
                        Text(fleetEntry.nodeName)
                        if !fleetEntry.nodeOnline {
                            Text("(cached)").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Run").foregroundStyle(.secondary)
                    Text(entry.run).textSelection(.enabled)
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(entry.status)
                            .foregroundStyle(Format.statusColor(entry.status))
                        if entry.state != entry.status {
                            Text(entry.state).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Next").foregroundStyle(.secondary)
                    Text("\(Format.activation(entry.activation)) · \(entry.schedule?.label ?? "—")")
                }
                GridRow {
                    Text("Evaluations").foregroundStyle(.secondary)
                    Text("\(entry.evaluations)"
                         + (entry.zeroReturnStreak > 0
                            ? " · streak \(entry.zeroReturnStreak)" : ""))
                }
                GridRow {
                    Text("Origin").foregroundStyle(.secondary)
                    Text(entry.origin)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func coreSections(_ core: ContinuationCore) -> some View {
        if let task = core.task {
            section("Task") { Text(task).font(.callout).textSelection(.enabled) }
        }
        if let context = core.context {
            section("Context") { Text(context).font(.callout).textSelection(.enabled) }
        }
        if let stops = core.whenToStop, !stops.isEmpty {
            section("When to Stop") {
                ForEach(stops, id: \.self) { stop in
                    Label(stop, systemImage: "octagon").font(.callout)
                }
            }
        }
        if let wtc = core.whenToContinue, !wtc.isEmpty {
            section("When to Continue") {
                Text(wtc).font(.callout).textSelection(.enabled)
            }
        }
    }

    private var evaluationSection: some View {
        section("Evaluations (\(evaluations.count))") {
            if evaluations.isEmpty {
                Text("Not evaluated yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(evaluations) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Format.outcomeColor(event.outcome))
                            .frame(width: 7, height: 7)
                        Text(Format.timestamp(event.ts))
                        Text(event.actor).foregroundStyle(.secondary)
                        if let outcome = event.outcome, outcome != "ok" {
                            Text(outcome).foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
                    if let summary = event.payload["summary"]?.stringValue,
                       !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
            if !prompts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(prompts) { prompt in
                        Button(prompt.name) { openPrompt = prompt }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
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
        guard let client = store.client(key: fleetEntry.nodeKey) else { return }
        let entry = fleetEntry.entry
        do {
            let detail = try await client.taskDetail(entry.task)
            taskInfo = detail
            runEntry = detail.runs?
                .first { $0.runID == entry.run }?
                .entries.first { $0.cid == entry.continuation }
            let log = try await client.log(task: entry.task, run: entry.run,
                                           after: 0, limit: 1000)
            evaluations = log
                .filter {
                    $0.continuationID == entry.continuation
                        && ["continue", "tick.evaluate"].contains($0.cmd)
                }
                .sorted { $0.id > $1.id }
            prompts = (try await client.prompts(task: entry.task, run: entry.run))
                .filter { $0.name.hasPrefix("prompt--\(entry.continuation)--") }
            failure = nil
        } catch {
            failure = "Could not load details: \(error.localizedDescription)"
        }
    }
}

struct PromptViewer: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss
    let nodeKey: String
    let task: String
    let run: String
    let prompt: PromptInfo
    @State private var text = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(prompt.name).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            guard let client = store.client(key: nodeKey) else { return }
            text = (try? await client.promptText(task: task, run: run,
                                                 name: prompt.name))
                ?? "Could not load the prompt archive."
        }
    }
}
