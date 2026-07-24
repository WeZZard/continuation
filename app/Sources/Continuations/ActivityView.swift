import ContinuationsKit
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var store: FleetStore

    var body: some View {
        List(store.activity) { item in
            EventRowView(event: item.event, nodeName: item.nodeName)
        }
        .overlay {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Events stream in live from every reachable node."))
            }
        }
    }
}

struct AddNodeSheet: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "7787"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Node").font(.headline)
            Text("Nodes on this network appear automatically via Bonjour. "
                 + "Add one by address when it lives elsewhere — a tunnel "
                 + "hostname works too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Host", text: $host, prompt: Text("mini-4.local or 192.168.50.4"))
                TextField("Port", text: $port)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    store.addManualNode(
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: Int(port) ?? 7787)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

