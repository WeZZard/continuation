import AppKit
import SwiftUI

/// A box for prose the human writes — a message to a session, feedback on
/// a plan. What goes in it is paragraphs, so it is a text view: it wraps,
/// it grows, and Return starts a line rather than submitting.
struct ProseEditor: View {
    let prompt: String
    @Binding var text: String
    /// Where the box rests when it is empty — a couple of lines, not a
    /// pane. It grows with what is written and stops at `maxHeight`,
    /// after which it scrolls.
    var minHeight: CGFloat = 52
    var maxHeight: CGFloat = 220
    var enabled: Bool = true
    /// A height the human chose, which outranks the automatic one until
    /// they give it back. nil means the box sizes itself.
    var preferred: Binding<CGFloat?>? = nil

    @State private var written: CGFloat = 0
    @State private var dragStart: CGFloat?

    /// One inset for both layers. The text view carries no insets of its
    /// own, so the caret and the placeholder start at the same point by
    /// construction rather than by two constants agreeing.
    private let inset = EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)

    private var height: CGFloat {
        if let chosen = preferred?.wrappedValue {
            return max(chosen, minHeight)
        }
        return min(max(written, minHeight), maxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if preferred != nil { grip }
            box
        }
    }

    /// The handle: a box for writing in is a box the writer should be able
    /// to size, and the automatic height is only a good guess.
    private var grip: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 28, height: 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStart ?? height
                        dragStart = start
                        preferred?.wrappedValue = max(minHeight,
                                                      start - drag.translation.height)
                    }
                    .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { preferred?.wrappedValue = nil }
            .help("Drag to resize · double-click to fit the message")
    }

    private var box: some View {
        ZStack(alignment: .topLeading) {
            ProseTextView(text: $text, editable: enabled, written: $written)
                .frame(height: height)
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
    /// How tall the words currently are, so the box can be the size of
    /// what is in it.
    @Binding var written: CGFloat

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
        context.coordinator.report(view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, written: $written)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let written: Binding<CGFloat>

        init(text: Binding<String>, written: Binding<CGFloat>) {
            self.text = text
            self.written = written
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            report(view)
        }

        /// The laid-out height of the text, published back to the layout.
        /// Reported after the current update rather than during it, since
        /// a view may not change the state it is being built from.
        func report(_ view: NSTextView) {
            guard let manager = view.layoutManager,
                  let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            DispatchQueue.main.async { [written] in
                if abs(written.wrappedValue - height) > 0.5 {
                    written.wrappedValue = height
                }
            }
        }
    }
}
