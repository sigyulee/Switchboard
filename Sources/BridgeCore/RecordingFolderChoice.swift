import Foundation

public struct RecordingFolderChoice: Equatable, Sendable {
    public let url: URL
    public let requiresConfirmation: Bool

    public init(documentsDirectory: URL, savedPath: String?, previousDefault: URL? = nil) {
        if let saved = Self.savedURL(savedPath) {
            url = saved
            requiresConfirmation = false
        } else if let previousDefault {
            url = previousDefault
            requiresConfirmation = false
        } else {
            url = documentsDirectory.appendingPathComponent("Switchboard", isDirectory: true)
            requiresConfirmation = true
        }
    }

    public static func savedURL(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Prepare only after an explicit folder choice; leave existing contents untouched.
    public static func prepare(_ url: URL) throws -> URL {
        guard url.isFileURL, let folder = savedURL(url.path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Task.checkCancellation()
        let probe = folder.appendingPathComponent(".switchboard-write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: probe) }
        try Task.checkCancellation()
        return folder
    }
}
