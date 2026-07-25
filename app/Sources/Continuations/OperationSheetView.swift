import ContinuationsKit
import SwiftUI

/// The disclosure list IS the progress list: one surface, first a promise,
/// then a running account. Each line acquires state in place.
@MainActor
final class OperationSheetModel: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    enum Phase: Equatable { case confirming, running, succeeded, failed }

    enum StepState: Equatable {
        case pending, running, succeeded, skipped
        case failed(String)          // the tool's own standard error
    }

    @Published private(set) var plan: OperationPlan
    @Published private(set) var states: [Int: StepState] = [:]
    @Published private(set) var phase: Phase = .confirming
    /// Work inside the app's own container fails before anything runs.
    @Published private(set) var preparationError: String?

    private let engine: InstallerEngine
    private let agentKind: AgentKind
    private let onFinish: () -> Void

    init(plan: OperationPlan, engine: InstallerEngine,
         onFinish: @escaping () -> Void) {
        self.plan = plan
        self.engine = engine
        self.agentKind = plan.agent
        self.onFinish = onFinish
        resetStates()
    }

    private func resetStates() {
        states = Dictionary(uniqueKeysWithValues:
            plan.steps.map { ($0.id, StepState.pending) })
        preparationError = nil
    }

    func state(_ step: OperationStep) -> StepState {
        states[step.id] ?? .pending
    }

    // ------------------------------------------------------------- running

    func start() {
        guard phase == .confirming else { return }
        phase = .running
        let engine = self.engine
        let plan = self.plan
        Task.detached(priority: .userInitiated) { [weak self] in
            if plan.verb.needsPreparation {
                do {
                    try engine.prepare()
                } catch {
                    await self?.failPreparation(error.localizedDescription)
                    return
                }
            }
            for step in plan.steps {
                await self?.mark(step.id, .running)
                let result = engine.run(argv: step.argv)
                if result.status == 0 {
                    await self?.mark(step.id, .succeeded)
                    continue
                }
                // A failure belongs to its line, carrying the tool's own
                // text; the steps after it are skipped, never dropped.
                let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let output = text.isEmpty
                    ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : text
                await self?.mark(step.id, .failed(output.isEmpty
                    ? "exited with status \(result.status)" : output))
                await self?.skipRemaining(after: step.id)
                await self?.finish(.failed)
                return
            }
            await self?.finish(.succeeded)
        }
    }

    /// A failed attempt may have changed the world: re-plan from fresh
    /// facts and disclose the converged list before running it again.
    func replan() {
        let engine = self.engine
        let kind = agentKind
        let verb = plan.verb
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = engine.snapshot()
            guard let status = snapshot.agent(kind) else { return }
            let next = OperationPlanner.plan(verb, for: status, paths: engine.paths)
            await self?.adopt(next)
        }
    }

    private func adopt(_ next: OperationPlan) {
        plan = next
        phase = .confirming
        resetStates()
    }

    private func mark(_ id: Int, _ state: StepState) {
        states[id] = state
    }

    private func skipRemaining(after id: Int) {
        for step in plan.steps where step.id > id {
            states[step.id] = .skipped
        }
    }

    private func failPreparation(_ message: String) {
        preparationError = message
        for step in plan.steps { states[step.id] = .skipped }
        phase = .failed
        onFinish()
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
        onFinish()
    }

    // ------------------------------------------------------------- copy

    var title: String {
        switch phase {
        case .confirming: return "\(plan.verb.title) \(plan.agent.displayName)'s plugin?"
        case .running: return plan.verb.gerund
        case .succeeded: return plan.verb.past
        case .failed: return "\(plan.verb.title) failed"
        }
    }

    var leadIn: String {
        switch phase {
        case .confirming: return "These commands will run:"
        case .running: return "These commands are running:"
        case .succeeded: return "These commands ran:"
        case .failed: return "These commands ran:"
        }
    }
}

struct OperationSheetView: View {
    @ObservedObject var model: OperationSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.leadIn).font(.subheadline).foregroundStyle(.secondary)

            if let failure = model.preparationError {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.plan.steps) { step in
                    stepRow(step)
                }
            }

            Text(model.plan.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(18)
        .frame(width: 540)
        .interactiveDismissDisabled(model.phase == .running)
    }

    // --------------------------------------------------------------- step

    @ViewBuilder private func stepRow(_ step: OperationStep) -> some View {
        let state = model.state(step)
        // The glyph centers on the step, not on its first line.
        HStack(alignment: .center, spacing: 10) {
            glyph(state)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.display)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(state == .skipped ? .secondary : .primary)
                Text(step.effect)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let output) = state {
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08)))
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(state == .pending ? 0.55 : 1)
    }

    @ViewBuilder private func glyph(_ state: OperationSheetModel.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // ------------------------------------------------------------ buttons

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .confirming:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(model.plan.verb.title) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.plan.steps.isEmpty)
        case .running:
            // No mid-run exit: stopping between two steps leaves the
            // half-state the disclosure promised never to leave.
            Button("Cancel") {}.disabled(true)
        case .succeeded:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Retry") { model.replan() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
