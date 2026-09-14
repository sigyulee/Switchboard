import AVFoundation
import Observation

@MainActor @Observable final class MicrophoneAccess {
    private(set) var status: AVAuthorizationStatus
    private(set) var isRequesting = false
    private let preview: Bool
    private let readStatus: @MainActor () -> AVAuthorizationStatus
    private let requestAccess: @MainActor () async -> Bool
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    var allowed: Bool { status == .authorized }

    init(
        preview: Bool = false,
        readStatus: @escaping @MainActor () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        requestAccess: @escaping @MainActor () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.preview = preview
        self.readStatus = readStatus
        self.requestAccess = requestAccess
        status = preview ? .authorized : readStatus()
    }

    func refresh() {
        guard !preview else { return }
        status = readStatus()
    }

    func request() {
        guard !preview, !isRequesting else { return }
        refresh()
        guard status == .notDetermined else { return }
        isRequesting = true
        requestTask = Task { [weak self, requestAccess] in
            _ = await requestAccess()
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            self.isRequesting = false
            self.requestTask = nil
        }
    }

    deinit { requestTask?.cancel() }
}
