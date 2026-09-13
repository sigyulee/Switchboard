import AVFAudio
import BridgeCore
import Foundation
import Observation
import RecorderKit

@MainActor @Observable final class PlaybackController {
    private var player: AVAudioPlayer?
    var playing = false
    var position: Double = 0
    var duration: Double = 0
    var title = ""
    var waveform: [Float] = []
    private(set) var preparing = false
    private var generation = UUID()
    private var waveformTask: Task<[Float], Error>?
    private var requestTask: Task<Void, Never>?
    private var renderTask: Task<URL, Error>?

    func play(
        _ item: RecordingItem, side: AudioSide?, at seconds: Double = 0,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        stop()
        let current = generation
        preparing = true
        requestTask = Task { [weak self] in
            guard let self, generation == current, !Task.isCancelled else { return }
            defer {
                if generation == current {
                    preparing = false
                    requestTask = nil
                    renderTask = nil
                }
            }
            do {
                let url: URL
                if let side {
                    let render = Task.detached(priority: .utility) {
                        let target = item.directory.appendingPathComponent("Preview-\(side.rawValue).caf")
                        try RecordingRenderer.render(item: item, side: side, destination: target)
                        return target
                    }
                    renderTask = render
                    url = try await render.value
                } else {
                    url = item.mixURL
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                try load(url: url, title: item.manifest.title, at: seconds)
            } catch is CancellationError {
                // A different selection or Stop invalidated this request.
            } catch {
                if generation == current { onError(error) }
            }
        }
    }

    private func load(url: URL, title: String, at seconds: Double) throws {
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.currentDevice = nil
        guard newPlayer.prepareToPlay() else { throw AudioFailure(operation: .errorPlayback, code: -1) }
        player = newPlayer
        duration = newPlayer.duration
        self.title = title
        newPlayer.currentTime = seconds.isFinite ? max(0, min(duration, seconds)) : 0
        position = newPlayer.currentTime
        playing = newPlayer.play()
        let current = generation
        let task = Task.detached(priority: .utility) { try Waveform.read(url: url) }
        waveformTask = task
        Task {
            do {
                let result = try await task.value
                if generation == current { waveform = result }
            } catch { if generation == current { waveform = [] } }
        }
    }
    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { _ = player.play() }
        playing = player.isPlaying
    }
    func seek(_ value: Double) {
        guard value.isFinite else { return }
        player?.currentTime = max(0, min(duration, value))
        refresh()
    }
    func refresh() {
        position = player?.currentTime ?? 0
        playing = player?.isPlaying ?? false
    }
    func stopAndWait() async {
        let request = requestTask
        let render = renderTask
        let waveform = waveformTask
        stop()
        await request?.value
        _ = try? await render?.value
        _ = try? await waveform?.value
    }

    func stop() {
        requestTask?.cancel()
        requestTask = nil
        renderTask?.cancel()
        renderTask = nil
        preparing = false
        waveformTask?.cancel()
        waveformTask = nil
        generation = UUID()
        waveform = []
        player?.stop()
        player = nil
        position = 0
        duration = 0
        playing = false
        title = ""
    }
}
