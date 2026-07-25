import ContinuationsKit
import SwiftUI

enum ReviewKindIcon {
    static func name(_ kind: String) -> String {
        switch kind {
        case "question": return "questionmark.circle"
        case "plan": return "list.clipboard"
        default: return "pause.circle"
        }
    }
}

/// The actionable console for one review item: answer the question,
/// rule on the plan, or dismiss a stop.
struct ReviewConsoleView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss
    let nodeKey: String
    let item: ReviewItem

    @State private var selections: [String: String] = [:]
    @State private var feedback = ""
    @State private var failed = false

    private var isLocal: Bool {
        store.node(key: nodeKey)?.isLocal ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: ReviewKindIcon.name(item.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("\(item.agent) · \(projectName) · \(store.node(key: nodeKey)?.displayName ?? nodeKey)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            content
            if failed {
                Text("The decision could not be delivered — see the terminal session.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !isLocal {
                Text("This session runs on another node; act on it there. Remote actions come later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                actions
            }
        }
        .padding(16)
        .frame(width: 520)
        .frame(minHeight: 220)
    }

    private var title: String {
        switch item.kind {
        case "question": return "Question"
        case "plan": return "Plan review"
        default: return "Stopped"
        }
    }

    private var projectName: String {
        item.cwd.isEmpty ? "—"
            : (item.cwd as NSString).lastPathComponent
    }

    // ------------------------------------------------------------ content

    @ViewBuilder private var content: some View {
        switch item.kind {
        case "question":
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(item.payload.questions ?? [], id: \.question) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.question).bold()
                            ForEach(question.options ?? [], id: \.label) { option in
                                Button {
                                    selections[question.question] = option.label
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName:
                                            selections[question.question] == option.label
                                            ? "largecircle.fill.circle" : "circle")
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(option.label)
                                            if let detail = option.description {
                                                Text(detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        case "plan":
            ScrollView {
                Text(item.payload.plan ?? item.summary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            TextField("Feedback for changes (optional)", text: $feedback)
        default:
            Text(item.summary)
                .foregroundStyle(.secondary)
        }
    }

    // ------------------------------------------------------------ actions

    @ViewBuilder private var actions: some View {
        switch item.kind {
        case "question":
            Button("Answer") { submitAnswers() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isLocal || !allQuestionsAnswered)
        case "plan":
            Button("Request Changes") { submitPlan(approve: false) }
                .disabled(!isLocal)
            Button("Approve Plan") { submitPlan(approve: true) }
                .keyboardShortcut(.defaultAction)
                .disabled(!isLocal)
        default:
            Button("Dismiss") {
                dismissStop()
            }
            .disabled(!isLocal)
        }
    }

    private var allQuestionsAnswered: Bool {
        let questions = item.payload.questions ?? []
        return !questions.isEmpty
            && questions.allSatisfy { selections[$0.question] != nil }
    }

    private func submitAnswers() {
        deliver { ReviewActions.answer(reviewID: item.id,
                                       decision: ["answers": selections]) }
    }

    private func submitPlan(approve: Bool) {
        var decision: [String: Any] = ["approve": approve]
        if !approve, !feedback.isEmpty { decision["feedback"] = feedback }
        deliver { ReviewActions.answer(reviewID: item.id, decision: decision) }
    }

    private func dismissStop() {
        deliver { ReviewActions.clear(sessionRef: item.sessionRef,
                                      kind: "stopped") }
    }

    private func deliver(_ action: @escaping () -> Bool) {
        Task.detached(priority: .userInitiated) {
            let ok = action()
            await MainActor.run {
                if ok { dismiss() } else { failed = true }
            }
        }
    }
}
