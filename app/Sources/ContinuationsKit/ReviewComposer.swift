import Foundation

/// What the console sends a session, images included.
///
/// The channel back into a session is a hook decision, and a hook decision
/// carries text — so an image travels as a path the agent can open rather
/// than as bytes it cannot receive. The file is copied somewhere stable
/// first: a screenshot dropped from a temporary folder must still be there
/// when the agent reaches for it.
public enum ReviewComposer {

    public static let imageTypes: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff",
    ]

    public static func isImage(_ url: URL) -> Bool {
        imageTypes.contains(url.pathExtension.lowercased())
    }

    /// The message as the session will read it.
    public static func message(text: String, attachments: [URL]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return body }
        let lines = attachments.map { "- \($0.path)" }.joined(separator: "\n")
        let preamble = attachments.count == 1
            ? "The user attached an image. Read it before answering:"
            : "The user attached \(attachments.count) images. Read them before "
              + "answering:"
        return body.isEmpty
            ? "\(preamble)\n\(lines)"
            : "\(body)\n\n\(preamble)\n\(lines)"
    }

    /// Where dropped files are kept: inside this build's own umbrella, so
    /// a debug app never writes into the release app's folders, and never
    /// into the store, which belongs to the CLI.
    public static func attachmentsDirectory(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(
                AppSupportUmbrella.directoryName(base: "Continuation",
                                                 bundleID: bundle.bundleIdentifier),
                isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Copy a dropped file where it will survive, under a name that will
    /// not collide with the last drop.
    @discardableResult
    public static func keep(_ source: URL, in directory: URL,
                            fileManager: FileManager = .default) throws -> URL {
        let destination = try place(name: source.deletingPathExtension()
                                        .lastPathComponent,
                                    extension: source.pathExtension.lowercased(),
                                    in: directory, fileManager: fileManager)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// The same, for a drop that carries pixels rather than a file — an
    /// image dragged out of a browser has no path to copy from.
    @discardableResult
    public static func keep(data: Data, extension suffix: String,
                            in directory: URL,
                            fileManager: FileManager = .default) throws -> URL {
        let destination = try place(name: "dropped",
                                    extension: suffix.isEmpty ? "png" : suffix,
                                    in: directory, fileManager: fileManager)
        try data.write(to: destination)
        return destination
    }

    private static func place(name: String, extension suffix: String,
                              in directory: URL,
                              fileManager: FileManager) throws -> URL {
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true)
        let stamp = UUID().uuidString.prefix(8)
        let destination = directory
            .appendingPathComponent("\(name)-\(stamp).\(suffix)")
        try? fileManager.removeItem(at: destination)
        return destination
    }
}
