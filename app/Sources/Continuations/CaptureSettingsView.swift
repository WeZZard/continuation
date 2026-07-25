import AppKit
import ContinuationsKit
import SwiftUI

/// Supervision is opt-in per session: the console plugin is injected at
/// launch, never installed. This section hands out the command that does
/// it. Claude Code only — nothing like it exists for pi yet.
struct CaptureSection: View {
    @ObservedObject var model: InstallerModel
    @State private var copied = false
    @State private var failure: String?

    private var pluginDirectory: URL { model.engine.paths.consoleSource }


    private var command: String? {
        CaptureLaunch.command(for: .claude, pluginDirectory: pluginDirectory,
                              held: driveFromConsole)
    }

    @AppStorage("captureDriveFromConsole") private var driveFromConsole = false

    var body: some View {
        Section {
            if let command {
                HStack(alignment: .center, spacing: 10) {
                    AgentLogoView(kind: .claude, size: 26,
                                  dimmed: !(model.snapshot?.agent(.claude)?
                                    .detected ?? true))
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(command)
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy") { copy(command) }
                        .fixedSize()
                }
                .padding(.vertical, 4)
                Toggle("Let the console drive this session", isOn: $driveFromConsole)
                Text(driveFromConsole
                     ? "The session stays reachable between turns, so you can "
                       + "send it messages from the review box. Its terminal "
                       + "holds anything typed there until the next turn, so "
                       + "use this for sessions you are not sitting in front of."
                     : "The session reports what it waits on, and you answer "
                       + "its questions and plans from the review box. Sending "
                       + "it a message needs the option above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Launch a Supervised Session")
        } footer: {
            Text("A session started this way reports the moments it waits on "
                 + "you — a question, a plan, a stop — to the review box, and "
                 + "takes your answer back. Sessions started any other way, "
                 + "and the ones the scheduler spawns, report nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The plugin has to be on disk for the command to work: placing it is
    /// work inside the app's own container, so it happens here rather than
    /// asking the user to install something they never install.
    private func copy(_ command: String) {
        let engine = model.engine
        let directory = pluginDirectory
        Task.detached(priority: .userInitiated) {
            // Always refresh: the command names the app's copy of the
            // plugin, so that copy must be the one this app carries.
            var problem: String?
            do { try engine.materialize() } catch {
                problem = error.localizedDescription
            }
            await MainActor.run {
                failure = problem
                guard problem == nil else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                copied = true
            }
            try? await Task.sleep(for: .milliseconds(1100))
            await MainActor.run { copied = false }
        }
    }
}
