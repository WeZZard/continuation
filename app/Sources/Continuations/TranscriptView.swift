import ContinuationsKit
import SwiftUI

/// The conversation a session is having, newest last. The counts describe
/// the whole transcript — which outlives compaction, so a session whose
/// context was summarized away three times still reports every prompt it
/// was given — while the entries shown are its tail.
struct TranscriptView: View {
    @EnvironmentObject private var store: FleetStore
    let row: ReviewRow

    @State private var transcript: Transcript?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let transcript, !transcript.entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcript.entries.enumerated()), id: \.offset) {
                        _, entry in
                        exchange(entry)
                    }
                }
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Text(failure ?? "No transcript yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Read again while this session is the one on screen, so a
        // session working through a turn fills in as it goes.
        .task(id: row.id) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transcript").font(.headline)
            if let counts = transcript?.counts {
                Text("\(counts.prompts) prompts · \(counts.replies) replies "
                     + "· \(counts.tools) tool calls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Read the transcript again")
        }
    }

    @ViewBuilder
    private func exchange(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.role == "user" ? "You" : row.agent)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.role == "user" ? .blue : .secondary)
            if !entry.text.isEmpty {
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.tools.isEmpty {
                Text(entry.tools.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private func load(force: Bool = false) async {
        guard let url = store.node(key: row.nodeKey)?.url else { return }
        if loading && !force { return }
        loading = transcript == nil
        do {
            let read = try await NodeClient(baseURL: url)
                .transcript(sessionRef: row.sessionRef, limit: 40)
            transcript = read
            failure = nil
        } catch {
            if transcript == nil { failure = "This node did not answer." }
        }
        loading = false
    }
}
