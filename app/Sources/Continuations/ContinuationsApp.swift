import ContinuationsKit
import SwiftUI

@main
struct ContinuationsApp: App {
    @StateObject private var store = FleetStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 540)
                .task {
                    // Sessions run the materialized CLI and plugin, so an
                    // updated app that leaves them behind ships a version
                    // skew into other people's terminals.
                    let engine = InstallerEngine()
                    await Task.detached(priority: .utility) {
                        engine.refreshPayloadIfStale()
                    }.value
                }
        }
        #if os(macOS)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
        #endif
    }
}

/// Which object the detail column shows. Selections carry ids, not value
/// snapshots, so live refreshes never orphan the selection.
enum DetailSelection: Hashable {
    case entry(String)                       // FleetEntry.id
    case task(nodeKey: String, taskID: String)
    case review(nodeKey: String, reviewID: Int)
}

enum SidebarSelection: Hashable {
    case all
    case state(String)                       // "expired" | "invalid" | "paused"
    case review
    case activity
    case node(String)                        // NodeState.key
}

/// The piles of entries the scheduler will not act on by itself — three
/// distinct sections, each named exactly what it is, shown only when
/// non-empty. Never an umbrella.
enum StuckState {
    static let all = ["expired", "invalid", "paused"]

    static func icon(_ state: String) -> String {
        switch state {
        case "expired": return "clock.badge.exclamationmark"
        case "invalid": return "xmark.octagon"
        case "paused": return "pause.circle"
        default: return "questionmark.circle"
        }
    }
}
