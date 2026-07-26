import AppKit
import SwiftUI

/// A box for prose the human writes — a message to a session, feedback on
/// a plan. It wraps, it grows with what is written, and it can be dragged
/// to whatever height the writer prefers.
///
/// AppKit, deliberately. The first version drove the height from SwiftUI
/// state: a drag gesture wrote every delta into storage while the text
/// view reported its measured height back in, so two writers fought over
/// one layout each frame and the box jittered under the cursor. Here one
/// view owns its height, moves a constraint directly while dragging, and
/// tells SwiftUI only once the drag settles.
struct ProseEditor: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = 52
    var maxHeight: CGFloat = 240
    var enabled: Bool = true
    /// Where a dragged height is remembered; nil for a box that always
    /// sizes itself and shows no grip.
    var storageKey: String?

    func makeNSView(context: Context) -> ProseBox {
        let box = ProseBox(minHeight: minHeight, maxHeight: maxHeight,
                           storageKey: storageKey)
        box.onEdit = { written in
            // Publish on the next turn of the run loop: a view may not
            // change the state it is being built from.
            DispatchQueue.main.async { text = written }
        }
        return box
    }

    func updateNSView(_ box: ProseBox, context: Context) {
        box.apply(text: text, prompt: prompt, enabled: enabled)
    }
}

// MARK: - The box

/// The text view, its placeholder, and the grip that sizes it.
final class ProseBox: NSView {
    var onEdit: ((String) -> Void)?

    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let storageKey: String?
    private let scroll = NSScrollView()
    private let textView = PlaceholderTextView()
    private let grip = GripView()
    private var boxHeight: NSLayoutConstraint!
    private var gripHeight: CGFloat { storageKey == nil ? 0 : 12 }
    /// A height the human dragged to. While it is set the box keeps it,
    /// however much is written; double-clicking the grip gives it back.
    private var chosen: CGFloat?
    private var dragStart: CGFloat?

    init(minHeight: CGFloat, maxHeight: CGFloat, storageKey: String?) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.storageKey = storageKey
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        grip.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)

        textView.delegate = self
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        grip.isHidden = storageKey == nil
        grip.onBegin = { [weak self] in self?.beginDrag() }
        grip.onDrag = { [weak self] risen in self?.drag(risen: risen) }
        grip.onSettle = { [weak self] in self?.remember() }
        grip.onReset = { [weak self] in self?.giveTheHeightBack() }

        addSubview(grip)
        addSubview(scroll)

        chosen = storageKey.flatMap { key in
            let saved = UserDefaults.standard.double(forKey: key)
            return saved > 0 ? CGFloat(saved) : nil
        }
        boxHeight = scroll.heightAnchor.constraint(
            equalToConstant: chosen ?? minHeight)

        NSLayoutConstraint.activate([
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: gripHeight),
            scroll.topAnchor.constraint(equalTo: grip.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            boxHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func apply(text: String, prompt: String, enabled: Bool) {
        if textView.string != text {
            textView.string = text
            fitToText(animated: false)
        }
        textView.placeholder = prompt
        textView.isEditable = enabled
        textView.isSelectable = enabled
        textView.textColor = enabled ? .labelColor : .disabledControlTextColor
        grip.isEnabled = enabled
        needsDisplay = true
        textView.needsDisplay = true
    }

    // ------------------------------------------------------------ sizing

    private func beginDrag() {
        dragStart = boxHeight.constant
    }

    /// Dragging moves the constraint and nothing else — no state to
    /// publish, no storage to write — so the box tracks the cursor.
    ///
    /// `risen` is how far the cursor has climbed since the press, in
    /// window coordinates, where up is positive. Up therefore makes the
    /// box taller, which is the direction the hand expects and the
    /// opposite of what event deltas gave.
    private func drag(risen: CGFloat) {
        let height = max(minHeight, (dragStart ?? boxHeight.constant) + risen)
        chosen = height
        boxHeight.constant = height
        invalidateIntrinsicContentSize()
    }

    private func remember() {
        dragStart = nil
        guard let storageKey, let chosen else { return }
        UserDefaults.standard.set(Double(chosen), forKey: storageKey)
    }

    private func giveTheHeightBack() {
        chosen = nil
        if let storageKey { UserDefaults.standard.removeObject(forKey: storageKey) }
        fitToText(animated: true)
    }

    /// The height the words ask for, honoured only while nobody has
    /// chosen one.
    private func fitToText(animated: Bool) {
        guard chosen == nil,
              let manager = textView.layoutManager,
              let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let written = manager.usedRect(for: container).height + 14
        let height = min(max(written, minHeight), maxHeight)
        guard abs(boxHeight.constant - height) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                boxHeight.animator().constant = height
            }
        } else {
            boxHeight.constant = height
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: boxHeight.constant + gripHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width,
                          height: bounds.height - gripHeight)
        let path = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        (textView.isEditable
            ? NSColor.textBackgroundColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

extension ProseBox: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        onEdit?(textView.string)
        fitToText(animated: false)
        textView.needsDisplay = true
    }
}

// MARK: - Parts

/// The caret and the placeholder start at the same point because the same
/// text container decides where both of them go.
private final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width
                            + (textContainer?.lineFragmentPadding ?? 0),
                        y: textContainerInset.height),
            withAttributes: [
                .font: font ?? .preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
    }
}

/// The handle. It reports drags in points and never touches layout itself,
/// so one view stays in charge of the box's size.
private final class GripView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onSettle: (() -> Void)?
    var onReset: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }

    private var pressedAt: CGFloat?

    override func resetCursorRects() {
        guard isEnabled, !isHidden else { return }
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        let bar = NSRect(x: (bounds.width - 28) / 2, y: bounds.midY - 2,
                         width: 28, height: 4)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 {
            pressedAt = nil
            onReset?()
            return
        }
        pressedAt = event.locationInWindow.y
        onBegin?()
    }

    /// The window is the frame of reference. Its coordinates put up in
    /// the positive direction and, unlike this view, it does not move
    /// while the box resizes underneath the cursor — measuring against a
    /// moving view is what made the first version shake, and event deltas
    /// are what made the second one grow the wrong way.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let pressed = pressedAt else { return }
        onDrag?(event.locationInWindow.y - pressed)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressedAt != nil else { return }
        pressedAt = nil
        onSettle?()
    }
}
