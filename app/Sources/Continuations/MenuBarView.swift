#if os(macOS)
import ContinuationsKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                headline(now: timeline.date)
                if store.attentionCount > 0 {
                    Label("\(store.attentionCount) need attention",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Divider()
                ForEach(store.nodes) { node in
                    HStack(spacing: 8) {
                        HealthDot(online: node.online)
                        Text(node.displayName)
                        Spacer()
                        Text(node.online
                             ? "\(node.pendingCount) open"
                             : "as of \(node.lastSeen?.formatted(date: .omitted, time: .shortened) ?? "—")")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if store.nodes.isEmpty {
                    Text("No nodes discovered yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button("Open Continuations") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .font(.callout)
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func headline(now: Date) -> some View {
        Group {
            if store.dueCount > 0 {
                Label("\(store.dueCount) due now", systemImage: "tray.full.fill")
                    .foregroundStyle(.blue)
            } else if let next = store.nextScheduled,
                      let date = next.activationDate {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("next due \(Format.relative(date, now: now))")
                        Text("\(next.entry.continuation) · \(next.nodeName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            } else {
                Label("queue is quiet", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
    }
}
#endif
