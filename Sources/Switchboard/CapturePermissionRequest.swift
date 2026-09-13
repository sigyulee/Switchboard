import AudioRealtime

final class CapturePermissionRequest {
    private let tap: ChromeTap
    private let capture: OpaquePointer
    init() throws {
        let tap = ChromeTap()
        try tap.start(requireRunningProcess: false, mute: false)
        var error: Int32 = 0
        guard let capture = sb_discard_capture_start(tap.deviceID, &error) else {
            tap.stop()
            throw AudioFailure(operation: .errorRequestAudio, code: error)
        }
        self.tap = tap
        self.capture = capture
    }
    deinit {
        sb_discard_capture_destroy(capture)
        tap.stop()
    }
}
