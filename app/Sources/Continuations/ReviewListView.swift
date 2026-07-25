import ContinuationsKit
import SwiftUI

/// Every supervised session, gathered under the project it runs in.
/// Sessions waiting on a human are selectable and open the console;
/// running ones state their presence and nothing more.
struct ReviewListView: View {
    @EnvironmentObject private var store: FleetStore
    @Binding var selection: DetailSelection?

    var body: some View {
        Group {
            if store.reviewGroups.isEmpty {
                ContentUnavailableView(
                    "No supervised sessions",
                    systemImage: "person.crop.square.filled.and.at.rectangle",
                    description: Text("Launch an agent with the console plugin "
                                      + "and it appears here."))
            } else {
                List(selection: $selection) {
                    ForEach(store.reviewGroups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                sessionRow(row)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(group.project)
                                if group.waitingCount > 0 {
                                    Text("\(group.waitingCount) waiting")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .help(group.path)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ row: ReviewRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.review.map { ReviewKindIcon.name($0.kind) }
                  ?? "circle.dashed")
                .foregroundStyle(row.isWaiting ? .primary : .secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(2)
                    .foregroundStyle(row.isWaiting ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(row.agent)
                    if row.canReceiveMessage {
                        Text("· can be messaged")
                    } else if !row.isWaiting {
                        Text("· running")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(row.nodeName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
        .tag(row.review.map {
            DetailSelection.review(nodeKey: row.nodeKey, reviewID: $0.id)
        } ?? DetailSelection.review(nodeKey: row.nodeKey, reviewID: 0))
        .selectionDisabled(!row.isWaiting)
    }
}
