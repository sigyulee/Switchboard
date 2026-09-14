import Foundation

/// Coordinates recording-folder scans without sharing mutable state with file workers.
public struct LibraryRefreshState: Sendable {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let root: URL
    }

    public private(set) var current: Request?
    private var needsReload = false
    private var stopped = false

    public init() {}

    /// Periodic refreshes keep the current scan. Explicit changes request one follow-up.
    public mutating func request(root: URL, afterChange: Bool = false) -> Request? {
        guard !stopped else { return nil }
        if current?.root == root {
            needsReload = needsReload || afterChange
            return nil
        }
        needsReload = false
        let request = Request(id: UUID(), root: root)
        current = request
        return request
    }

    public func isCurrent(_ request: Request) -> Bool { current == request }
    public func canPublish(_ request: Request) -> Bool { isCurrent(request) && !needsReload }

    /// Finish even if publication was invalidated; stale completions cannot clear newer work.
    public mutating func finish(_ request: Request) -> Request? {
        guard isCurrent(request) else { return nil }
        current = nil
        if needsReload { return self.request(root: request.root) }
        return nil
    }

    public mutating func shutdown() {
        stopped = true
        current = nil
        needsReload = false
    }
}

/// The same ownership policy guards library actions and their UI controls.
public struct RecordingLibraryAccess: Sendable {
    public let preview: Bool
    public let starting: Bool
    public let recordingDirectory: URL?
    public let finalizing: Set<URL>

    public init(
        preview: Bool, starting: Bool, recordingDirectory: URL?, finalizing: Set<URL>
    ) {
        self.preview = preview
        self.starting = starting
        self.recordingDirectory = recordingDirectory
        self.finalizing = finalizing
    }

    public var canChangeFolder: Bool { !preview && !starting && recordingDirectory == nil }

    public func canEdit(_ directory: URL) -> Bool {
        !preview && !starting && directory != recordingDirectory && !finalizing.contains(directory)
    }

    public func canDisplay(_ directory: URL, status: RecordingStatus) -> Bool {
        !starting || status != .recording || directory == recordingDirectory
    }

    public func canRecover(_ directory: URL, status: RecordingStatus, busy: Bool = false) -> Bool {
        !busy && canEdit(directory)
            && (status == .recording || status == .finalizing || status == .recoverable || status == .failed)
    }
}
