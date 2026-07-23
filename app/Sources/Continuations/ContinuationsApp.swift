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
}

enum SidebarSelection: Hashable {
    case all
    case attention
    case activity
    case node(String)                        // NodeState.key
}
