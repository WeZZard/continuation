import Foundation

// Commands run on the user's behalf OUTSIDE the app, through each agent's
// own CLI. Per the operation-sheet scene: nothing runs that was not
// disclosed, the step carries the argument vector and the displayed
// command derives from it, and a retry re-plans from fresh facts — so the
// second attempt is often shorter than the first.

public enum OperationVerb: String, Sendable, Equatable {
    case install
    case update
    case uninstall
    case retry

    /// The word the cell's button and the sheet both use.
    public var title: String {
        switch self {
        case .install: return "Install"
        case .update: return "Update"
        case .uninstall: return "Uninstall"
        case .retry: return "Retry"
        }
    }

    public var gerund: String {
        switch self {
        case .install: return "Installing…"
        case .update: return "Updating…"
        case .uninstall: return "Uninstalling…"
        case .retry: return "Retrying…"
        }
    }

    public var past: String {
        switch self {
        case .install: return "Installed"
        case .update: return "Updated"
        case .uninstall: return "Uninstalled"
        case .retry: return "Retried"
        }
    }

    /// Uninstalling removes; everything else puts the plugin in place.
    public var needsPreparation: Bool { self != .uninstall }
}

public struct OperationStep: Identifiable, Equatable, Sendable {
    public let id: Int
    /// The truth: run verbatim, never re-parsed from the display string.
    public let argv: [String]
    /// The one-line consequence, in the user's language.
    public let effect: String

    public init(id: Int, argv: [String], effect: String) {
        self.id = id
        self.argv = argv
        self.effect = effect
    }

    /// The disclosure derives from the argument vector, never the reverse.
    public var display: String {
        argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

public struct OperationPlan: Equatable, Sendable {
    public let verb: OperationVerb
    public let agent: AgentKind
    public let steps: [OperationStep]
    public let footnote: String

    public init(verb: OperationVerb, agent: AgentKind,
                steps: [OperationStep], footnote: String) {
        self.verb = verb
        self.agent = agent
        self.steps = steps
        self.footnote = footnote
    }
}

public enum OperationPlanner {

    /// The plan for a verb against the agent's CURRENT state: a retry
    /// discloses the converged list, which is often shorter.
    public static func plan(_ verb: OperationVerb, for status: AgentStatus,
                            paths: InstallerEngine.Paths) -> OperationPlan {
        let steps = self.steps(verb, for: status, paths: paths)
        return OperationPlan(verb: verb, agent: status.kind,
                             steps: numbered(steps),
                             footnote: footnote(verb, agent: status.kind))
    }

    private static func numbered(_ steps: [(argv: [String], effect: String)])
        -> [OperationStep] {
        steps.enumerated().map {
            OperationStep(id: $0.offset, argv: $0.element.argv,
                          effect: $0.element.effect)
        }
    }

    private static func steps(_ verb: OperationVerb, for status: AgentStatus,
                              paths: InstallerEngine.Paths)
        -> [(argv: [String], effect: String)] {
        let source = paths.payloadDest.path
        let pluginSource = paths.pluginSource.path
        let name = status.kind.displayName

        switch (status.kind, verb) {
        case (.claude, .uninstall):
            var steps: [(argv: [String], effect: String)] = [
                (["claude", "plugin", "uninstall", InstallerFacts.pluginID],
                 "Remove the plugin from \(name)"),
            ]
            if status.location != nil {
                steps.append((["claude", "plugin", "marketplace", "remove",
                               InstallerFacts.marketplaceName],
                              "Unregister the plugin source"))
            }
            return steps

        case (.claude, .update):
            return [(["claude", "plugin", "update", InstallerFacts.pluginID],
                     "Update \(name) to the version this app carries")]

        case (.claude, _):
            // Install or retry: register the source unless the agent
            // already points at ours, then install.
            var steps: [(argv: [String], effect: String)] = []
            if status.location != source {
                if status.location != nil {
                    steps.append((["claude", "plugin", "marketplace", "remove",
                                   InstallerFacts.marketplaceName],
                                  "Unregister the stale plugin source"))
                }
                steps.append((["claude", "plugin", "marketplace", "add", source],
                              "Register this app's plugin source with \(name)"))
            }
            // Claude Code keeps its own copy of a marketplace's listing and
            // it outlives an unregister, so a freshly added source can be
            // read stale and the install fails with "not found in
            // marketplace" (observed 2026-07-25). Re-reading is cheap.
            steps.append((["claude", "plugin", "marketplace", "update",
                           InstallerFacts.marketplaceName],
                          "Re-read that source so \(name) sees this version"))
            steps.append((["claude", "plugin", "install", InstallerFacts.pluginID],
                          "Install the schedule skill into \(name)"))
            return steps

        case (.pi, .uninstall):
            return [(["pi", "remove", status.location ?? pluginSource],
                     "Remove the package from \(name)")]

        case (.pi, _):
            var steps: [(argv: [String], effect: String)] = []
            if let location = status.location, location != pluginSource {
                steps.append((["pi", "remove", location],
                              "Remove the stale package from \(name)"))
            }
            steps.append((["pi", "install", pluginSource],
                          verb == .update
                            ? "Re-read the refreshed package into \(name)"
                            : "Install the schedule skill as a local package"))
            return steps
        }
    }

    private static func footnote(_ verb: OperationVerb, agent: AgentKind) -> String {
        let subject = "\(agent.displayName)'s own plugin system performs this work"
        switch verb {
        case .uninstall:
            return "\(subject); it changes \(agent.displayName)'s plugin records "
                + "only. Nothing you authored is touched, and no files are deleted."
        default:
            return "\(subject); it changes \(agent.displayName)'s plugin records "
                + "only. This app first refreshes its own copy of the plugin."
        }
    }
}

/// The agent cell's self-referential constraint, solved in closed form:
/// the icon takes 0.618 of the cell's height while the cell takes its
/// tallest content — never a measure-and-resize loop.
public enum AgentCellGeometry {
    public static let ratio: CGFloat = 0.618

    /// `verticalPadding` is the cell's total padding, above plus below.
    public static func iconHeight(textHeight: CGFloat,
                                  verticalPadding: CGFloat) -> CGFloat {
        // Regime 1 — the text column leads: the cell is as tall as the
        // text plus its padding, and the icon follows.
        let textLed = ratio * (textHeight + verticalPadding)
        if textLed <= textHeight { return textLed }
        // Regime 2 — the icon leads: h = ratio * (h + padding).
        return ratio * verticalPadding / (1 - ratio)
    }
}


/// Supervision is opt-in per session: the console plugin is injected at
/// launch, never installed. The Capture panel hands out the command.
public enum CaptureLaunch {

    /// Seconds a driven session stays reachable between turns.
    public static let holdSeconds = 1800

    /// nil when the agent has no hook surface this plugin can use.
    ///
    /// `held: true` keeps the session reachable from the console after
    /// every turn, which is what makes Send work — at the price of the
    /// terminal, since Claude Code queues anything typed while a hook
    /// runs. Use it for sessions nobody is sitting in front of.
    public static func command(for agent: AgentKind, pluginDirectory: URL,
                               held: Bool = false) -> String? {
        switch agent {
        case .claude:
            let path = pluginDirectory.path
            let quoted = path.contains(" ") ? "'\(path)'" : path
            let prefix = held ? "CONTINUATION_REVIEW_HOLD=\(holdSeconds) " : ""
            return "\(prefix)claude --plugin-dir \(quoted)"
        case .pi:
            return nil
        }
    }
}
