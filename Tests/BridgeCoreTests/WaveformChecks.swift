import BridgeCore

struct WaveformChecks {
    func livePeaksAndSilence() throws {
        var caller = LiveWaveformHistory()
        let chrome = LiveWaveformHistory()
        caller.insert(peak: 0.2, seconds: 1.01)
        caller.insert(peak: 0.7, seconds: 1.02)
        try expect(caller.samples(endingAt: 1.04).last == 0.7)
        try expect(chrome.samples(endingAt: 1.04).allSatisfy { $0 == 0 })
        try expect(caller.samples(endingAt: 6).allSatisfy { $0 == 0 })
        caller.insert(peak: 0.4, seconds: 6)
        let wrapped = caller.samples(endingAt: 6)
        try expect(wrapped.last == 0.4)
        try expect(wrapped.filter { $0 != 0 }.count == 1)
    }
}
