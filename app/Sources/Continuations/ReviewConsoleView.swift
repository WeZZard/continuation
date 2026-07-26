import AppKit
import ContinuationsKit
import SwiftUI
import UniformTypeIdentifiers

enum ReviewKindIcon {
    static func name(_ kind: String) -> String {
        switch kind {
        case "question": return "questionmark.circle"
        case "plan": return "list.clipboard"
        default: return "pause.circle"
        }
    }
}

/// One session, shaped like the conversation it is: what was said fills
/// the view, and what you can do about it sits at the bottom where a
/// chat's controls belong — never scrolling away in the feed.
struct ReviewConsoleView: View {
    @EnvironmentObject private var store: FleetStore
    let row: ReviewRow

    @State private var selections: [String: Set<String>] = [:]
    @State private var written: [String: String] = [:]
    @State private var feedback = ""
    @State private var message = ""
    @State private var attachments: [URL] = []
    @State private var failed = false
    @State private var sending = false
    @State private var dropping = false
    @State private var dropNote: String?

    private var item: ReviewItem? { row.review }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TranscriptView(row: row)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            dock
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    // --------------------------------------------------------------- dock

    /// Everything the human acts through, pinned. Its own content scrolls
    /// when a plan or a question runs long, so the buttons never move.
    private var dock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                pending
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: dockContentHeight)
            HStack(spacing: 8) {
                if failed {
                    Text("The decision could not be delivered — see the session.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let note = dropNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
        }
        .padding(12)
        .background(.bar)
        // The whole dock takes a drop, not the text view alone: an image
        // released an inch below the box was landing on nothing while the
        // box still lit up, which promised something it could not do.
        .onDrop(of: [.fileURL, .image, .png, .jpeg, .tiff],
                isTargeted: canAttach ? $dropping : .constant(false)) { providers in
            receive(providers)
        }
        .overlay {
            if dropping && canAttach {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Text("Drop images to attach")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint))
                    .allowsHitTesting(false)
            }
        }
    }

    private var canAttach: Bool {
        item?.kind == "stopped" && row.canReceiveMessage
    }

    private var dockContentHeight: CGFloat {
        switch item?.kind {
        case "question": return 260
        case "plan": return 300
        case "stopped": return 200
        default: return 60
        }
    }

    @ViewBuilder private var pending: some View {
        switch item?.kind {
        case "question":
            VStack(alignment: .leading, spacing: 18) {
                ForEach(item?.payload.questions ?? [], id: \.question) { question in
                    questionBlock(question)
                }
            }
        case "plan":
            VStack(alignment: .leading, spacing: 10) {
                Text(item?.payload.plan ?? item?.summary ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProseEditor(prompt: "Feedback, if you want changes",
                            text: $feedback, minHeight: 64)
            }
        case "stopped":
            composer
        default:
            Text("This session is working. Nothing is waiting on you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // ----------------------------------------------------------- composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.self) { url in
                            thumbnail(url)
                        }
                    }
                }
                .frame(height: 62)
            }
            ProseEditor(prompt: "Message — drop images anywhere below",
                        text: $message, minHeight: 96,
                        enabled: row.canReceiveMessage)
            if !row.canReceiveMessage {
                unreachableNotice
            }
        }
    }

    private func thumbnail(_ url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.title3)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            Button {
                attachments.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
        .help(url.lastPathComponent)
    }

    /// A dropped image is copied somewhere stable before it is named to
    /// the session: screenshots arrive from folders that do not last.
    ///
    /// Finder hands over a file URL as data under `public.file-url`, and a
    /// browser hands over pixels with no path at all — loading it as an
    /// object returns neither, which is why an accepted drop used to
    /// vanish.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard canAttach else { return false }
        let directory = ReviewComposer.attachmentsDirectory()
        var taken = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                taken = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
                    item, _ in
                    let url: URL? = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0,
                                                         relativeTo: nil) }
                    guard let url, ReviewComposer.isImage(url),
                          let kept = try? ReviewComposer.keep(url, in: directory)
                    else {
                        Task { @MainActor in
                            dropNote = "That file is not an image."
                        }
                        return
                    }
                    Task { @MainActor in attach(kept) }
                }
            } else if let identifier = provider.registeredTypeIdentifiers.first(
                where: { UTType($0)?.conforms(to: .image) == true }) {
                taken = true
                provider.loadDataRepresentation(forTypeIdentifier: identifier) {
                    data, _ in
                    guard let data,
                          let kept = try? ReviewComposer.keep(
                            data: data,
                            extension: UTType(identifier)?
                                .preferredFilenameExtension ?? "png",
                            in: directory)
                    else { return }
                    Task { @MainActor in attach(kept) }
                }
            }
        }
        if !taken { dropNote = "Only images can be attached." }
        return taken
    }

    @MainActor
    private func attach(_ url: URL) {
        attachments.append(url)
        dropNote = nil
    }

    @ViewBuilder private var unreachableNotice: some View {
        if row.isLocal {
            Text("This session is no longer holding — its window ran out, or "
                 + "it was launched with holding off. Type into its terminal "
                 + "and it becomes reachable again at the next stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("This session runs on another node; act on it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // ---------------------------------------------------------- questions

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

    // ------------------------------------------------------------ actions

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
            // Return belongs to the text view, so sending is ⌘↩ — the
            // same key that sends a message everywhere else on this Mac.
            Button("Send") { sendMessage() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!row.canReceiveMessage || !hasSomethingToSend || sending)
        default:
            EmptyView()
        }
    }

    private var hasSomethingToSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
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
        let text = ReviewComposer.message(text: message, attachments: attachments)
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
                if ok {
                    message = ""
                    feedback = ""
                    attachments = []
                }
            }
        }
    }
}
