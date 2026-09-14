import Foundation

public struct ApplicationIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let bundleURL: URL
    public let name: String
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, bundleURL: URL, name: String) throws {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
            !bundleIdentifier.contains(where: { $0.isWhitespace || $0.isNewline }),
            bundleURL.isFileURL, bundleURL.pathExtension == "app",
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256
        else { throw ApplicationSelectionError.invalidApplication }
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        self.name = name
    }

    public func owns(executableURL: URL) -> Bool {
        guard executableURL.isFileURL else { return false }
        let root = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path + "/Contents/"
        return executableURL.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }

    public func validate() throws {
        _ = try Self(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, name: name)
    }
}

public enum ApplicationSelectionError: Error, Equatable, Sendable {
    case invalidApplication, sameApplication, switchboardSelected
}

public struct RouteProfile: Codable, Equatable, Sendable {
    public var agent: ApplicationIdentity
    public var caller: ApplicationIdentity

    public init(agent: ApplicationIdentity, caller: ApplicationIdentity) throws {
        self.agent = agent
        self.caller = caller
        try validate()
    }

    public func validate() throws {
        try agent.validate()
        try caller.validate()
        guard agent.id != caller.id, agent.bundleURL != caller.bundleURL else {
            throw ApplicationSelectionError.sameApplication
        }
        guard agent.id != "com.switchboard.main", caller.id != "com.switchboard.main" else {
            throw ApplicationSelectionError.switchboardSelected
        }
    }
}
