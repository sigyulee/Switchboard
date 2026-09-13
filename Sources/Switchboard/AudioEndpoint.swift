import AudioRealtime
import Foundation
import RecorderKit

final class AudioEndpoint {
    let deviceID: UInt32
    let queue: OpaquePointer
    let handle: OpaquePointer
    let rate: Double
    let converter: SampleConverter
    var needsRestart: Bool {
        let heartbeat = sb_endpoint_heartbeat(handle)
        let now = sb_host_time()
        return sb_endpoint_error(handle) != 0 || (now >= heartbeat && sb_host_seconds(now - heartbeat) > 3)
    }

    init(deviceID: UInt32, capture: Bool) throws {
        self.deviceID = deviceID
        guard let queue = sb_queue_create(131_072) else { throw MediaFailure.invalidBuffer }
        var error: Int32 = 0
        let pointer =
            capture ? sb_capture_create(deviceID, queue, &error) : sb_output_create(deviceID, queue, &error)
        guard let pointer else {
            sb_queue_destroy(queue)
            throw AudioFailure(operation: .errorConnectDevice, code: error)
        }
        let rate = sb_endpoint_rate(pointer)
        do {
            converter = try SampleConverter(from: capture ? rate : PCM.rate, to: capture ? PCM.rate : rate)
            let status = sb_endpoint_start(pointer)
            guard status == 0 else { throw AudioFailure(operation: .errorStartDevice, code: status) }
        } catch {
            sb_endpoint_destroy(pointer)
            sb_queue_destroy(queue)
            throw error
        }
        self.queue = queue
        handle = pointer
        self.rate = rate
    }
    func push(_ samples: [Float]) throws {
        let converted = try converter.convert(samples)
        guard !converted.isEmpty else { return }
        converted.withUnsafeBufferPointer { buffer in
            _ = sb_queue_write(queue, buffer.baseAddress, UInt32(buffer.count / 2), sb_host_time())
        }
    }
    func packets() throws -> [(samples: [Float], seconds: Double)] {
        var result: [(samples: [Float], seconds: Double)] = []
        var buffer = [Float](repeating: 0, count: 16_384)
        for _ in 0..<32 {
            var host: UInt64 = 0
            let count = buffer.withUnsafeMutableBufferPointer {
                sb_queue_read_packet(queue, $0.baseAddress, 8192, &host)
            }
            guard count > 0 else { break }
            let converted = try converter.convert(Array(buffer.prefix(Int(count) * 2)))
            if !converted.isEmpty { result.append((converted, sb_host_seconds(host))) }
        }
        return result
    }
    deinit {
        sb_endpoint_destroy(handle)
        sb_queue_destroy(queue)
    }
}
