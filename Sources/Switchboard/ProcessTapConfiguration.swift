import CoreAudio
import Foundation

enum ProcessTapConfiguration {
    static func make(processes: [AudioObjectID], name: String, mute: Bool) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        // An empty verified inclusion list must stay empty. New processes are
        // admitted only after the catalog verifies their executable ownership.
        description.isExclusive = false
        description.bundleIDs = []
        description.isProcessRestoreEnabled = false
        description.name = name
        description.isPrivate = true
        description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        return description
    }
}
