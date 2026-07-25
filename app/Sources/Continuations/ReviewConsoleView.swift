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

/// The actionable console for one session: answer its question, rule on
/// its plan, or send it the message that puts it back to work.
struct ReviewConsoleView: View {
    @EnvironmentObject private var store: FleetStore
    let row: ReviewRow

    @State private var selections: [String: Set<String>] = [:]
    @State private var written: [String: String] = [:]
    @State private var feedback = ""
    @State private var message = ""
    @State private var failed = false
    @State private var sending = false

    private var item: ReviewItem? { row.review }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .navigationTitle(title)
    }

    // ------------------------------------------------------------- header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.map { ReviewKindIcon.name($0.kind) }
                  ?? "circle.dashed")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(row.agent) · \(project) · \(row.nodeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var title: String {
        switch item?.kind {
        case "question": return "Question"
        case "plan": return "Plan review"
        case "stopped": return item?.summary ?? "Waiting"
        default: return "Running"
        }
    }

    private var project: String {
        row.cwd.isEmpty ? "—" : (row.cwd as NSString).lastPathComponent
    }

    // ------------------------------------------------------------ content

    @ViewBuilder private var content: some View {
        switch item?.kind {
        case "question":
            VStack(alignment: .leading, spacing: 18) {
                ForEach(item?.payload.questions ?? [], id: \.question) { question in
                    questionBlock(question)
                }
            }
        case "plan":
            VStack(alignment: .leading, spacing: 12) {
                Text(item?.payload.plan ?? item?.summary ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Feedback, if you want changes", text: $feedback,
                          axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
        case "stopped":
            messageBlock
        default:
            Text("This session is working. Nothing is waiting on you.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: ReviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question).bold()
            if question.multiSelect == true {
                Text("Choose any that apply")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(question.options ?? [], id: \.label) { option in
                Button {
                    choose(question, option.label)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: glyph(question, option.label))
                            .foregroundStyle(.tint)
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("Other — write your own answer",
                      text: Binding(get: { written[question.question] ?? "" },
                                    set: { written[question.question] = $0 }))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send this session its next message.")
                .foregroundStyle(.secondary)
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
                .disabled(!row.canReceiveMessage)
            if !row.canReceiveMessage {
                Text(row.isLocal
                     ? "This session is not holding, so a message has nowhere "
                       + "to land. Launch it with CONTINUATION_REVIEW_HOLD set "
                       + "to keep it reachable — the Agent settings panel has "
                       + "the command."
                     : "This session runs on another node; act on it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func glyph(_ question: ReviewQuestion, _ label: String) -> String {
        let chosen = selections[question.question]?.contains(label) ?? false
        if question.multiSelect == true {
            return chosen ? "checkmark.square.fill" : "square"
        }
        return chosen ? "largecircle.fill.circle" : "circle"
    }

    private func choose(_ question: ReviewQuestion, _ label: String) {
        var chosen = selections[question.question] ?? []
        if question.multiSelect == true {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        selections[question.question] = chosen
    }

    // ------------------------------------------------------------- footer

    private var footer: some View {
        HStack {
            if failed {
                Text("The decision could not be delivered — see the session.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            actions
        }
        .padding(12)
    }

    @ViewBuilder private var actions: some View {
        switch item?.kind {
        case "question":
            Button("Answer") { submitAnswers() }
                .keyboardShortcut(.defaultAction)
                .disabled(!row.isLocal || !allQuestionsAnswered || sending)
        case "plan":
            Button("Request Changes") { submitPlan(approve: false) }
                .disabled(!row.isLocal || sending)
            Button("Approve Plan") { submitPlan(approve: true) }
                .keyboardShortcut(.defaultAction)
                .disabled(!row.isLocal || sending)
        case "stopped":
            Button("Dismiss") { dismissStop() }
                .disabled(!row.isLocal || sending)
            Button("Send") { sendMessage() }
                .keyboardShortcut(.defaultAction)
                .disabled(!row.canReceiveMessage || trimmedMessage.isEmpty || sending)
        default:
            EmptyView()
        }
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A question is answered when every one of them has a choice or a
    /// written answer — the console never sends a half-filled form.
    private var allQuestionsAnswered: Bool {
        let questions = item?.payload.questions ?? []
        return !questions.isEmpty && questions.allSatisfy { question in
            !(selections[question.question]?.isEmpty ?? true)
                || !(written[question.question] ?? "")
                    .trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submitAnswers() {
        guard let item else { return }
        var answers: [String: String] = [:]
        for question in item.payload.questions ?? [] {
            let chosen = (selections[question.question] ?? []).sorted()
            let free = (written[question.question] ?? "")
                .trimmingCharacters(in: .whitespaces)
            answers[question.question] = (chosen + (free.isEmpty ? [] : [free]))
                .joined(separator: ", ")
        }
        deliver { ReviewActions.answer(reviewID: item.id,
                                       decision: ["answers": answers]) }
    }

    private func submitPlan(approve: Bool) {
        guard let item else { return }
        var decision: [String: Any] = ["approve": approve]
        if !approve, !feedback.isEmpty { decision["feedback"] = feedback }
        deliver { ReviewActions.answer(reviewID: item.id, decision: decision) }
    }

    private func sendMessage() {
        guard let item else { return }
        let text = trimmedMessage
        deliver { ReviewActions.answer(reviewID: item.id,
                                       decision: ["message": text]) }
    }

    private func dismissStop() {
        deliver { ReviewActions.clear(sessionRef: row.sessionRef,
                                      kind: "stopped") }
    }

    private func deliver(_ action: @escaping () -> Bool) {
        sending = true
        Task.detached(priority: .userInitiated) {
            let ok = action()
            await MainActor.run {
                sending = false
                failed = !ok
                if ok { message = ""; feedback = "" }
            }
        }
    }
}
