import Foundation

/// A Sendable failure keeps its domain code for UI localization and its detail for the archive.
public struct RecorderFailure: Error, LocalizedError, Sendable {
    public let media: MediaFailure?
    public let detail: String

    public init(_ error: Error) {
        media = error as? MediaFailure
        detail = error.localizedDescription
    }

    public var errorDescription: String? { detail }
}
