import ContinuationsKit
import SwiftUI

enum Format {
    /// Mirrors the CLI's wait formatting: "in 5h 11m" / "32m overdue".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        let magnitude = abs(seconds)
        let text: String
        switch magnitude {
        case ..<90: text = "\(magnitude)s"
        case ..<5400: text = "\(magnitude / 60)m"
        case ..<90000:
            text = "\(magnitude / 3600)h \(String(format: "%02d", magnitude % 3600 / 60))m"
        default: text = "\(magnitude / 86400)d \(magnitude % 86400 / 3600)h"
        }
        return seconds >= 0 ? "in \(text)" : "\(text) overdue"
    }

    static func activation(_ iso: String?, now: Date = Date()) -> String {
        guard let date = StoreDate.parse(iso) else { return "—" }
        return relative(date, now: now)
    }

    static func timestamp(_ iso: String?) -> String {
        guard let date = StoreDate.parse(iso) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func clock(_ iso: String?) -> String {
        guard let date = StoreDate.parse(iso) else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    static func stateColor(_ state: String) -> Color {
        switch state {
        case "due": return .blue
        case "scheduled": return .secondary.opacity(0.8)
        case "expired", "invalid": return .red
        case "paused": return .orange
        default: return .secondary
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "pending": return .blue
        case "consumed": return .green
        case "ended": return .green
        case "expired", "invalid": return .red
        default: return .secondary
        }
    }

    static func outcomeColor(_ outcome: String?) -> Color {
        switch outcome {
        case "ok", nil: return .green
        case "partial": return .orange
        default: return .red
        }
    }
}

struct NodeChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct HealthDot: View {
    let online: Bool
    var body: some View {
        Circle()
            .fill(online ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}
