import Foundation

/// One supervised session as the review box sees it: who it is, where it
/// runs, and what it is waiting on. A row without a review is running —
/// present, asking nothing.
public struct ReviewRow: Identifiable, Hashable, Sendable {
    public let nodeKey: String
    public let nodeName: String
    public let isLocal: Bool
    public let agent: String
    public let sessionRef: String
    public let cwd: String
    public let review: ReviewItem?
    /// Whether the node this session lives on is answering. An offline
    /// node's rows are the last thing it said, not what is true now.
    public let nodeOnline: Bool
    public let lastSeen: Date?

    public init(nodeKey: String, nodeName: String, isLocal: Bool,
                agent: String, sessionRef: String, cwd: String,
                review: ReviewItem?, nodeOnline: Bool = true,
                lastSeen: Date? = nil) {
        self.nodeKey = nodeKey
        self.nodeName = nodeName
        self.isLocal = isLocal
        self.agent = agent
        self.sessionRef = sessionRef
        self.cwd = cwd
        self.review = review
        self.nodeOnline = nodeOnline
        self.lastSeen = lastSeen
    }

    public var id: String { "\(nodeKey)#\(sessionRef)" }

    public var isWaiting: Bool { review != nil }

    /// Whether a message sent from here would reach the session. Only a
    /// held session is listening; the rest are watched, not driven.
    public var canReceiveMessage: Bool {
        isLocal && review?.kind == "stopped" && review?.payload.held == true
    }

    public var title: String {
        guard let review else { return "Running" }
        return review.summary.isEmpty ? review.kind.capitalized : review.summary
    }

    /// What the row can honestly claim. An offline node's session was
    /// running when we last heard; it may have finished, stopped, or
    /// died since, and saying "running" flat would be a guess.
    public var stateLine: String {
        if !nodeOnline {
            guard let lastSeen else { return "last seen — node offline" }
            return "as of " + lastSeen.formatted(date: .omitted,
                                                 time: .shortened)
        }
        if canReceiveMessage { return "can be messaged" }
        return isWaiting ? "" : "running"
    }
}

/// The sessions of one project. The project is the directory the work
/// happens in — the unit a person thinks in — and it may span nodes.
public struct ReviewGroup: Identifiable, Hashable, Sendable {
    public let path: String
    public let rows: [ReviewRow]

    public init(path: String, rows: [ReviewRow]) {
        self.path = path
        self.rows = rows
    }

    public var id: String { path }

    public var project: String {
        path.isEmpty ? "—" : (path as NSString).lastPathComponent
    }

    public var waitingCount: Int { rows.filter(\.isWaiting).count }
}
