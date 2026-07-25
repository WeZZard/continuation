import AppKit
import SwiftUI

/// A box for prose the human writes — a message to a session, feedback on
/// a plan. What goes in it is paragraphs, so it is a text view: it wraps,
/// it grows, and Return starts a line rather than submitting.
struct ProseEditor: View {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = 96
    var enabled: Bool = true

    /// One inset for both layers. The text view carries no insets of its
    /// own, so the caret and the placeholder start at the same point by
    /// construction rather than by two constants agreeing.
    private let inset = EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ProseTextView(text: $text, editable: enabled)
                .frame(minHeight: minHeight)
            if text.isEmpty {
                Text(prompt)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .padding(inset)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(enabled ? AnyShapeStyle(.background)
                              : AnyShapeStyle(.quaternary.opacity(0.4))))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator))
    }
}

/// AppKit's text view with every inset removed, so its first glyph sits
/// exactly where the layout puts its origin. SwiftUI's own TextEditor
/// hides a line-fragment padding that no API can reach, which left the
/// caret a few points left of the placeholder (spotted 2026-07-26).
private struct ProseTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        // The clip view paints its own background and would hide the
        // placeholder drawn behind the text.
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = editable
        view.isSelectable = editable
        view.textColor = editable ? .labelColor : .disabledControlTextColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
