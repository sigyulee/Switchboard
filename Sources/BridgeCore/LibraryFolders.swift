import Foundation

public enum LibraryFolderError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot
    public var errorDescription: String? { "Choose a local filesystem folder for the library." }
}

/// Folder registration is explicit. Saving a session never changes this value.
public struct LibraryFolders: Codable, Equatable, Sendable {
    public private(set) var defaultRoot: URL
    public private(set) var addedRoots: [URL]
    public var roots: [URL] { [defaultRoot] + addedRoots.filter { $0 != defaultRoot } }

    public init(defaultRoot: URL, addedRoots: [URL] = []) throws {
        self.defaultRoot = try Self.normalizedRoot(defaultRoot)
        self.addedRoots = []
        for root in addedRoots { try add(root) }
    }

    public mutating func setDefaultRoot(_ root: URL) throws {
        defaultRoot = try Self.normalizedRoot(root)
    }

    public mutating func add(_ root: URL) throws {
        let root = try Self.normalizedRoot(root)
        if !addedRoots.contains(root) { addedRoots.append(root) }
    }

    public mutating func removeAdded(_ root: URL) throws {
        let root = try Self.normalizedRoot(root)
        addedRoots.removeAll { $0 == root }
    }

    public func contains(_ root: URL) -> Bool {
        guard let root = try? Self.normalizedRoot(root) else { return false }
        return roots.contains(root)
    }

    /// Normalizes URL spelling without performing filesystem I/O or following symbolic links.
    public static func normalizedRoot(_ root: URL) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
            root.query == nil, root.fragment == nil,
            root.host == nil || root.host == "" || root.host == "localhost"
        else { throw LibraryFolderError.invalidRoot }
        return URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
    }

    private enum CodingKeys: CodingKey { case defaultRoot, addedRoots }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            defaultRoot: values.decode(URL.self, forKey: .defaultRoot),
            addedRoots: values.decode([URL].self, forKey: .addedRoots))
    }
}
