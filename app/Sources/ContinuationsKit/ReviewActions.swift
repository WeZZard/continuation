import Foundation

/// Console decisions go through the `continuation` CLI — the single
/// writer — on the node's own machine. v1 actions are local-only; a
/// remote node's reviews render read-only until nodes accept writes.
public enum ReviewActions {

    @discardableResult
    public static func answer(reviewID: Int, decision: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: decision)
        else { return false }
        return run(["review", "answer", String(reviewID), "--decision", "-"],
                   stdin: data)
    }

    @discardableResult
    public static func clear(sessionRef: String, kind: String? = nil) -> Bool {
        var arguments = ["review", "clear", "--session", sessionRef]
        if let kind { arguments += ["--kind", kind] }
        return run(arguments, stdin: nil)
    }

    private static func run(_ arguments: [String], stdin: Data?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let joined = arguments
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        process.arguments = ["-c", """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            exec continuation --actor console \(joined)
            """]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
