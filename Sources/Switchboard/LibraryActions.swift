import AppKit
import BridgeCore
import Foundation
import RecorderKit
import UniformTypeIdentifiers

extension AppModel {
    func exportAll(_ item: RecordingItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = strings(.actionExport)
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let base = item.manifest.title.replacingOccurrences(of: "/", with: "-")
        var destination = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        let folder = destination
        exportBusy = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    try RecordingRenderer.render(
                        item: item, destination: folder.appendingPathComponent("Conversation.m4a"))
                    try RecordingRenderer.render(
                        item: item, side: .caller, destination: folder.appendingPathComponent("Caller.wav"))
                    try RecordingRenderer.render(
                        item: item, side: .chrome, destination: folder.appendingPathComponent("Chrome.wav"))
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { errorMessage = strings(.libraryExportError, strings.error(error)) }
            exportBusy = false
        }
    }
    func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = recordingRoot
        if panel.runModal() == .OK, let url = panel.url {
            recordingRoot = url
            UserDefaults.standard.set(url.path, forKey: "recordingRoot")
            reloadLibrary()
        }
    }
    func play(_ item: RecordingItem, side: AudioSide? = nil) {
        guard !preview else { return }
        playback.play(item, side: side) { [weak self] error in self?.errorMessage = self?.strings.error(error)
        }
    }
    func export(_ item: RecordingItem, side: AudioSide? = nil) {
        let panel = NSSavePanel()
        let suffix = side.map { "-\($0.rawValue)" } ?? ""
        panel.nameFieldStringValue = item.manifest.title.replacingOccurrences(of: "/", with: "-") + suffix
        panel.allowedContentTypes = side == nil ? [.mpeg4Audio] : [.wav]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportBusy = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try RecordingRenderer.render(item: item, side: side, destination: destination)
                }.value
            } catch { errorMessage = strings.error(error) }
            exportBusy = false
        }
    }
    func rename(_ item: RecordingItem) {
        guard item.directory != recordingURL, !finalizing.contains(item.directory) else { return }
        let alert = NSAlert()
        alert.messageText = strings(.libraryRenameTitle)
        let field = NSTextField(string: item.manifest.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: strings(.actionSave))
        alert.addButton(withTitle: strings(.actionCancel))
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try RecordingLibrary.rename(item, title: field.stringValue)
                reloadLibrary()
            } catch { errorMessage = strings.error(error) }
        }
    }
    func trash(_ item: RecordingItem) {
        guard item.directory != recordingURL, !finalizing.contains(item.directory) else { return }
        playback.stop()
        do {
            try FileManager.default.trashItem(at: item.directory, resultingItemURL: nil)
            reloadLibrary()
        } catch { errorMessage = strings.error(error) }
    }
    func recover(_ item: RecordingItem) {
        do {
            _ = try RecordingLibrary.recover(item)
            finalize(item.directory)
        } catch { errorMessage = strings.error(error) }
    }
}
