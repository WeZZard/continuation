#if os(macOS)
import ContinuationsKit
import SwiftUI

/// Native menu items (.menu style) — rendered by NSMenu, so it looks and
/// behaves like every other menu bar extra. Informational rows are
/// action-less buttons-as-text (disabled items); content re-renders each
/// time the menu opens.
struct MenuBarView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        headline
        ForEach(store.stuckCounts, id: \.state) { pile in
            Label("\(pile.count) \(pile.state)",
                  systemImage: StuckState.icon(pile.state))
        }
        Divider()
        ForEach(store.nodes.filter { !$0.excluded }) { node in
            Label(nodeLine(node),
                  systemImage: node.online ? "circle.fill" : "circle.dotted")
        }
        if store.nodes.isEmpty {
            Text("No nodes discovered yet")
        }
        Divider()
        Button("Open Continuations") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Continuations") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var headline: some View {
        if store.dueCount > 0 {
            Label("\(store.dueCount) due now", systemImage: "tray.full")
        } else if let next = store.nextScheduled,
                  let date = next.activationDate {
            Label("Next due \(Format.relative(date))", systemImage: "clock")
            Text("\(next.entry.continuation) · \(next.nodeName)")
        } else {
            Label("Queue is quiet", systemImage: "moon.zzz")
        }
    }

    private func nodeLine(_ node: NodeState) -> String {
        if node.online {
            return "\(node.displayName) — \(node.pendingCount) open"
        }
        let seen = node.lastSeen?.formatted(date: .omitted, time: .shortened) ?? "—"
        return "\(node.displayName) — offline, as of \(seen)"
    }
}
#endif
