// SPDX-License-Identifier: AGPL-3.0-only
import CoreAudio
import Darwin
import Foundation

private struct ConfigurationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ConfigurationFailure(description: message) }
}

@main struct ConfigurationChecks {
    static func main() {
        do {
            // Construct descriptions only. No HAL tap/device creation or property queries.
            let selections: [[AudioObjectID]] = [[], [41], [41, 42, 43]]
            for processes in selections {
                for mute in [false, true] {
                    let description = ProcessTapConfiguration.make(
                        processes: processes, name: "Switchboard · Selected Agent", mute: mute)
                    try require(
                        !description.isProcessRestoreEnabled, "bundle-ID process restoration must be disabled"
                    )
                    try require(
                        description.bundleIDs.isEmpty,
                        "bundle IDs must never select additional capture processes")
                    try require(
                        !description.isExclusive, "an empty inclusion list must not become an all-process tap"
                    )
                    try require(
                        description.processes == processes,
                        "only the supplied verified object IDs may be selected")
                    try require(description.isPrivate, "the tap must remain private")
                    try require(
                        description.isMixdown && !description.isMono, "the tap must remain a stereo mixdown")
                    try require(
                        description.name == "Switchboard · Selected Agent",
                        "the display name must be preserved")
                    try require(
                        description.muteBehavior == (mute ? .mutedWhenTapped : .unmuted),
                        "mute behavior must be preserved")
                }
            }
            var processes: [AudioObjectID] = [41]
            let fixed = ProcessTapConfiguration.make(processes: processes, name: "Selected", mute: true)
            processes.append(99)
            try require(fixed.processes == [41], "later array changes must not add an unverified member")
            print(
                "Tap configuration checks passed: explicit members, empty selection, no restoration, privacy and mute controls."
            )
        } catch {
            FileHandle.standardError.write(Data("Tap configuration check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
