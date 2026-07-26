// Models of the node protocol (v1) — one type per serve payload, decoded
// with explicit CodingKeys so wire names never shift under a key strategy.

import Foundation

// MARK: - Free-form JSON (event payloads)

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - /v1/node

public struct NodeInfo: Codable, Hashable, Sendable {
    public let proto: String
    public let nodeID: String
    public let hostname: String
    public let displayName: String?
    public let version: String
    public let schemaVersions: [Int]
    public let now: String
    public let startedAt: String
    public let lastTickAt: String?
    public let tickAgentLoaded: Bool?
    public let queueCounts: QueueCounts

    public struct QueueCounts: Codable, Hashable, Sendable {
        public let due: Int
        public let scheduled: Int
        public let attention: Int
    }

    enum CodingKeys: String, CodingKey {
        case proto
        case nodeID = "node_id"
        case hostname
        case displayName = "display_name"
        case version
        case schemaVersions = "schema_versions"
        case now
        case startedAt = "started_at"
        case lastTickAt = "last_tick_at"
        case tickAgentLoaded = "tick_agent_loaded"
        case queueCounts = "queue_counts"
    }
}

// MARK: - Schedules

public struct Schedule: Codable, Hashable, Sendable {
    public let mode: String
    public let amount: Int?
    public let unit: String?
    public let at: String?
    public let datetime: String?

    public var label: String {
        switch mode {
        case "now": return "now"
        case "every":
            let unitName = ["m": "min", "h": "h", "d": "d"][unit ?? ""] ?? unit ?? "?"
            return "every \(amount ?? 0)\(unitName)"
        case "daily": return "daily at \(at ?? "?")"
        case "at": return "once at \(datetime ?? "?")"
        default: return mode
        }
    }
}

// MARK: - /v1/queue

public struct QueueSnapshot: Codable, Hashable, Sendable {
    public let generatedAt: String
    public let due: [QueueEntry]
    public let scheduled: [QueueEntry]
    public let attention: [QueueEntry]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case due, scheduled, attention
    }

    public var open: [QueueEntry] { due + scheduled + attention }
}

public struct QueueEntry: Codable, Hashable, Identifiable, Sendable {
    public let task: String
    public let run: String
    public let continuation: String
    public let status: String
    public let enabled: Bool
    public let evaluations: Int
    public let zeroReturnStreak: Int
    public let registeredAt: String
    public let origin: String
    public let schedule: Schedule?
    public let activation: String?
    public let lastSummary: String?
    public let lastActor: String?
    public let state: String

    public var id: String { "\(task)/\(run)/\(continuation)" }

    enum CodingKeys: String, CodingKey {
        case task, run, continuation, status, enabled, evaluations
        case zeroReturnStreak = "zero_return_streak"
        case registeredAt = "registered_at"
        case origin, schedule, activation
        case lastSummary = "last_summary"
        case lastActor = "last_actor"
        case state
    }
}

// MARK: - Continuation cores

public struct ContinuationCore: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let step: String
    public let task: String?
    public let whenToStop: [String]?
    public let whenToContinue: String?
    public let context: String?
    public let schedule: Schedule?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case step, task
        case whenToStop = "when_to_stop"
        case whenToContinue = "when_to_continue"
        case context, schedule
    }
}

// MARK: - /v1/tasks

public struct TaskInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let agent: String
    public let agentCommand: String?
    public let singleRun: Bool
    public let enabled: Bool
    public let mustNot: [String]
    public let continuation: ContinuationCore
    public let registeredAt: String
    public let unregisteredAt: String?
    public let activeRun: String?
    public let runCount: Int
    public let runs: [RunDetail]?

    enum CodingKeys: String, CodingKey {
        case id, agent
        case agentCommand = "agent_command"
        case singleRun = "single_run"
        case enabled
        case mustNot = "must_not"
        case continuation
        case registeredAt = "registered_at"
        case unregisteredAt = "unregistered_at"
        case activeRun = "active_run"
        case runCount = "run_count"
        case runs
    }
}

public struct RunDetail: Codable, Hashable, Identifiable, Sendable {
    public let runID: String
    public let startedAt: String
    public let leasedBy: String?
    public let leaseExpiresAt: String?
    public let settled: Bool
    public let entries: [RunEntry]

    public var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case startedAt = "started_at"
        case leasedBy = "leased_by"
        case leaseExpiresAt = "lease_expires_at"
        case settled, entries
    }
}

public struct RunEntry: Codable, Hashable, Identifiable, Sendable {
    public let cid: String
    public let status: String
    public let origin: String
    public let core: ContinuationCore
    public let activation: String?
    public let registeredAt: String
    public let lastEvaluatedAt: String?
    public let completedAt: String?
    public let evaluations: Int
    public let zeroReturnStreak: Int
    public let lastSummary: String?
    public let lastActor: String?

    public var id: String { cid }

    enum CodingKeys: String, CodingKey {
        case cid, status, origin, core, activation
        case registeredAt = "registered_at"
        case lastEvaluatedAt = "last_evaluated_at"
        case completedAt = "completed_at"
        case evaluations
        case zeroReturnStreak = "zero_return_streak"
        case lastSummary = "last_summary"
        case lastActor = "last_actor"
    }
}

// MARK: - /v1/log and /v1/events

public struct EventRow: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let ts: String
    public let cmd: String
    public let actor: String
    public let taskID: String?
    public let runID: String?
    public let continuationID: String?
    public let outcome: String?
    public let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, ts, cmd, actor
        case taskID = "task_id"
        case runID = "run_id"
        case continuationID = "continuation_id"
        case outcome, payload
    }
}

public struct EventPage: Codable, Sendable {
    public let events: [EventRow]
}

// MARK: - Prompts

public struct PromptInfo: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let size: Int
    public var id: String { name }
}

public struct PromptPage: Codable, Sendable {
    public let prompts: [PromptInfo]
}

// MARK: - Store timestamps

public enum StoreDate {
    /// UTC-aware fields (`registered_at`, event `ts`) are ISO 8601 with an
    /// offset; `activation` is the scheduler's naive local time. Both parse
    /// here, naive strings interpreted in the current calendar's zone.
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = isoFractional.date(from: string) { return date }
        if let date = iso.date(from: string) { return date }
        for formatter in naiveLocal where formatter.date(from: string) != nil {
            return formatter.date(from: string)
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let naiveLocal: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"].map { pattern in
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            return formatter
        }
    }()
}

// MARK: - Reviews

/// A moment where an interactive agent session waits on the human — a
/// question, a plan, or a stop — raised by the console plugin's hooks.
public struct ReviewItem: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let sessionRef: String
    public let agent: String
    public let kind: String            // question | plan | stopped
    public let cwd: String
    public let summary: String
    public let payload: ReviewPayload
    public let raisedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionRef = "session_ref"
        case agent
        case kind
        case cwd
        case summary
        case payload
        case raisedAt = "raised_at"
    }
}

public struct ReviewPayload: Codable, Hashable, Sendable {
    public let questions: [ReviewQuestion]?
    public let plan: String?
    /// Whether the session's hook is still waiting on this item. Only a
    /// held session can be sent a message; the rest are presence.
    public let held: Bool?

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        questions = try? container?.decodeIfPresent(
            [ReviewQuestion].self, forKey: .questions)
        plan = try? container?.decodeIfPresent(String.self, forKey: .plan)
        held = try? container?.decodeIfPresent(Bool.self, forKey: .held)
    }

    enum CodingKeys: String, CodingKey { case questions, plan, held }
}

public struct ReviewQuestion: Codable, Hashable, Sendable {
    public let question: String
    public let header: String?
    public let multiSelect: Bool?
    public let options: [ReviewOption]?
}

public struct ReviewOption: Codable, Hashable, Sendable {
    public let label: String
    public let description: String?
}

struct ReviewPage: Decodable {
    let reviews: [ReviewItem]
}

/// A supervised agent session — announced by the console plugin when the
/// session starts or resumes, so the app discovers it before it waits.
public struct SupervisedSession: Codable, Hashable, Identifiable, Sendable {
    public let sessionRef: String
    public let agent: String
    public let cwd: String
    public let source: String
    public let startedAt: String

    public var id: String { sessionRef }

    enum CodingKeys: String, CodingKey {
        case sessionRef = "session_ref"
        case agent
        case cwd
        case source
        case startedAt = "started_at"
    }
}

struct SessionPage: Decodable {
    let sessions: [SupervisedSession]
}

/// The conversation a session is having, read from the agent's own
/// transcript: counts cover all of it, entries are its tail.
public struct Transcript: Codable, Hashable, Sendable {
    public let sessionRef: String
    public let counts: TranscriptCounts
    public let entries: [TranscriptEntry]

    public init(sessionRef: String, counts: TranscriptCounts,
                entries: [TranscriptEntry]) {
        self.sessionRef = sessionRef
        self.counts = counts
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case sessionRef = "session_ref"
        case counts, entries
    }
}

public struct TranscriptCounts: Codable, Hashable, Sendable {
    public let prompts: Int
    public let replies: Int
    public let tools: Int
    public let bytes: Int

    public init(prompts: Int, replies: Int, tools: Int, bytes: Int) {
        self.prompts = prompts
        self.replies = replies
        self.tools = tools
        self.bytes = bytes
    }
}

public struct TranscriptEntry: Codable, Hashable, Sendable, Identifiable {
    public let role: String            // user | assistant
    public let text: String
    public let tools: [String]

    public init(role: String, text: String, tools: [String]) {
        self.role = role
        self.text = text
        self.tools = tools
    }

    /// Position carries the identity: the same words can be said twice.
    public var id: String { "\(role)#\(text.hashValue)#\(tools.joined())" }
}
