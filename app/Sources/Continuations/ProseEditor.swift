import SwiftUI

/// A box for prose the human writes — a message to a session, feedback on
/// a plan. What goes in it is paragraphs, so it is a text view: it wraps,
/// it grows, and Return starts a line rather than submitting.
struct ProseEditor: View {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = 96
    var enabled: Bool = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(minHeight: minHeight)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.55)
            if text.isEmpty {
                Text(prompt)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(enabled ? AnyShapeStyle(.background)
                              : AnyShapeStyle(.quaternary.opacity(0.4))))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator))
    }
}
