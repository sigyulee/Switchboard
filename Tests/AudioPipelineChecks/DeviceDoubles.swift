import AudioRealtime
import Foundation
import Synchronization

// Substitute only the hardware boundary. The checks compile the production pipeline,
// recording worker, error model, queues and session code without opening audio devices.
enum TestDevices {
    struct State {
        var captures = 0
        var outputs = 0
        var taps = 0
        var rejectedCapture: UInt32?
        var rejectedOutput: UInt32?
    }
    static let state = Mutex(State())
}

final class AudioEndpoint {
    let deviceID: UInt32
    let queue: OpaquePointer
    let handle: OpaquePointer
    let capture: Bool
    var needsRestart: Bool { false }

    init(deviceID: UInt32, capture: Bool) throws {
        let rejected = TestDevices.state.withLock {
            capture ? $0.rejectedCapture == deviceID : $0.rejectedOutput == deviceID
        }
        if rejected { throw AudioFailure(operation: .errorConnectDevice, code: Int32(deviceID)) }
        guard let queue = sb_queue_create(16) else { throw CocoaError(.fileReadUnknown) }
        self.deviceID = deviceID
        self.capture = capture
        self.queue = queue
        handle = queue
        TestDevices.state.withLock {
            if capture { $0.captures += 1 } else { $0.outputs += 1 }
        }
    }

    func packets() throws -> [(samples: [Float], hostTime: UInt64)] { [] }
    func push(_ samples: [Float]) throws {}

    deinit {
        sb_queue_destroy(queue)
        TestDevices.state.withLock {
            if capture { $0.captures -= 1 } else { $0.outputs -= 1 }
        }
    }
}

final class AppAudioTap {
    let target: AppAudioTarget
    let deviceID: UInt32 = 42
    private var active = false
    init(target: AppAudioTarget) { self.target = target }
    func start() throws {
        active = true
        TestDevices.state.withLock { $0.taps += 1 }
    }
    deinit { if active { TestDevices.state.withLock { $0.taps -= 1 } } }
}

final class CapturePermissionRequest {
    init(target: AppAudioTarget) throws {}
}
