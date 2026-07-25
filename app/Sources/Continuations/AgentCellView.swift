import AppKit
import ContinuationsKit
import SwiftUI

/// Each agent is identified by its own mark: Claude Code by the Claude
/// spark (the vendor's published icon, used nominatively to identify the
/// product), pi by the π glyph — which IS its mark: pi's own app title is
/// the bare glyph. Never a generic glyph.
struct AgentLogoView: View {
    let kind: AgentKind
    var size: CGFloat = 22
    var dimmed = false

    private var corner: CGFloat { size * 0.23 }

    var body: some View {
        mark
            .frame(width: size, height: size)
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.45 : 1)
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .claude:
            if let url = Bundle.module.url(forResource: "claude-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(red: 0.80, green: 0.42, blue: 0.30))
                    .overlay(Text("✳︎").font(.system(size: size * 0.55))
                        .foregroundStyle(.white))
            }
        case .pi:
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(white: 0.13))
                .overlay(
                    Text("π")
                        .font(.system(size: size * 0.64, weight: .semibold, design: .serif))
                        .foregroundStyle(.white))
        }
    }
}

/// One row per agent, present or not: a missing agent says so rather than
/// disappearing.
struct AgentCellView: View {
    let status: AgentStatus
    let onAction: (OperationVerb) -> Void

    /// The inlined detail button's three-click cycle: status → location →
    /// (copy, flash Copied, back to location) → status.
    @State private var facade = 0
    @State private var flashingCopied = false

    private static let lineSpacing: CGFloat = 3
    private static let verticalPadding: CGFloat = 12   // total, above + below

    /// The text column's own height, from the two lines it stacks.
    private static let textHeight: CGFloat = {
        func height(_ font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading)
        }
        return height(NSFont.preferredFont(forTextStyle: .headline))
            + lineSpacing
            + height(NSFont.preferredFont(forTextStyle: .caption1))
    }()

    private static let iconSize = AgentCellGeometry.iconHeight(
        textHeight: textHeight, verticalPadding: verticalPadding)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentLogoView(kind: status.kind, size: Self.iconSize,
                          dimmed: !status.detected)
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(status.kind.displayName).font(.headline)
                    if let version = status.version {
                        Text("(\(version))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                detailButton
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, Self.verticalPadding / 2)
    }

    // ------------------------------------------------- inlined detail

    @ViewBuilder private var detailButton: some View {
        Button(action: advance) {
            if facade == 0 || status.location == nil {
                HStack(spacing: 5) {
                    indicatorGlyph
                    Text(indicatorText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(flashingCopied ? "Copied" : abbreviate(status.location ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(status.location ?? "")
    }

    private func advance() {
        guard status.location != nil else { return }
        let next = (facade + 1) % 3
        facade = next
        if next == 2 {
            // Copy the FULL location even though the display abbreviates.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(status.location ?? "", forType: .string)
            flashingCopied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1100))
                // A click during the flash counts as the exit click; the
                // recovery only clears the flash, never the facade.
                flashingCopied = false
            }
        } else {
            flashingCopied = false
        }
    }

    @ViewBuilder private var indicatorGlyph: some View {
        switch status.installation {
        case .installed(_, let disabled, let update):
            Circle()
                .fill(disabled ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .opacity(update && !disabled ? 0.9 : 1)
        case .broken:
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(.orange)
        case .notInstalled, .absent:
            Circle().fill(Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
        }
    }

    private var indicatorText: String {
        switch status.installation {
        case .installed(_, let disabled, let update):
            if disabled { return "Installed — disabled" }
            if update { return "Installed — update available" }
            return "Installed"
        case .broken(let cause): return "Broken — \(cause)"
        case .notInstalled, .absent: return "Not installed"
        }
    }

    // -------------------------------------------------------- action

    private var verb: OperationVerb? {
        switch status.installation {
        case .absent: return nil
        case .notInstalled: return .install
        case .broken: return .retry
        case .installed(_, let disabled, let update):
            if disabled { return .uninstall }
            return update ? .update : .uninstall
        }
    }

    @ViewBuilder private var action: some View {
        if let verb {
            Button(verb.title) { onAction(verb) }
                .fixedSize()
        } else {
            // The absent agent states its absence in the action's place.
            Text("Not found on this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
