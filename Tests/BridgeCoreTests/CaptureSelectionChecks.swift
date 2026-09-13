import BridgeCore
import Foundation

struct CaptureSelectionChecks {
    func matchingBundleIdentifierCannotGrantAnotherExecutableRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capture-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.app", isDirectory: true)
        let other = root.appendingPathComponent("Another copy.app", isDirectory: true)
        let relativeExecutable = "Contents/MacOS/Agent"
        let relativeHelper = "Contents/Frameworks/AgentHelper.app/Contents/MacOS/Helper"
        for bundle in [selected, other] {
            for relative in [relativeExecutable, relativeHelper] {
                let file = bundle.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("executable ownership fixture".utf8).write(to: file)
            }
            let plist = ["CFBundleIdentifier": "example.identical.agent", "CFBundleExecutable": "Agent"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        let selectedID = try ApplicationIdentity(
            bundleIdentifier: Bundle(url: selected)!.bundleIdentifier!, bundleURL: selected, name: "Selected")
        let otherID = try ApplicationIdentity(
            bundleIdentifier: Bundle(url: other)!.bundleIdentifier!, bundleURL: other, name: "Other")
        try expect(selectedID.bundleIdentifier == otherID.bundleIdentifier)
        try expect(selectedID.owns(executableURL: selected.appendingPathComponent(relativeExecutable)))
        try expect(selectedID.owns(executableURL: selected.appendingPathComponent(relativeHelper)))
        try expect(!selectedID.owns(executableURL: other.appendingPathComponent(relativeExecutable)))
        try expect(!selectedID.owns(executableURL: other.appendingPathComponent(relativeHelper)))
        try expect(otherID.owns(executableURL: other.appendingPathComponent(relativeExecutable)))
    }
}
