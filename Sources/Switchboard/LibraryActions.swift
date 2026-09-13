import AppKit
import BridgeCore
import Foundation
import RecorderKit
import TranscriptKit
import UniformTypeIdentifiers

extension AppModel {
    func exportAll(_ item: RecordingItem) {
        guard libraryMutationTask == nil else { return }
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
                        item: item, side: .agent, destination: folder.appendingPathComponent("Agent.wav"))
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { errorMessage = strings(.libraryExportError, strings.error(error)) }
            exportBusy = false
        }
    }
    func chooseRecordingFolder() {
        guard canChangeRecordingFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = recordingRoot
        if panel.runModal() == .OK, let url = panel.url, canChangeRecordingFolder {
            recordingRoot = url
            defaults.set(url.path, forKey: "recordingRoot")
            reloadLibrary()
        }
    }
    func play(_ item: RecordingItem, side: AudioSide? = nil, at seconds: Double = 0) {
        guard !preview, libraryMutationTask == nil else { return }
        playback.play(item, side: side, at: seconds) { [weak self] error in
            self?.errorMessage = self?.strings.error(error)
        }
    }
    func export(_ item: RecordingItem, side: AudioSide? = nil) {
        guard libraryMutationTask == nil else { return }
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
        guard canEdit(item) else { return }
        let alert = NSAlert()
        alert.messageText = strings(.libraryRenameTitle)
        let field = NSTextField(string: item.manifest.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: strings(.actionSave))
        alert.addButton(withTitle: strings(.actionCancel))
        if alert.runModal() == .alertFirstButtonReturn, canEdit(item) {
            do {
                try RecordingLibrary.rename(item, title: field.stringValue)
                reloadLibrary(afterChange: true)
            } catch { errorMessage = strings.error(error) }
        }
    }
    func trash(_ item: RecordingItem) {
        guard canEdit(item), libraryMutationTask == nil else { return }
        libraryMutationTask = Task {
            defer { libraryMutationTask = nil }
            if storedProcessing.itemID == item.id { await storedProcessing.pause() }
            await playback.stopAndWait()
            guard canEdit(item) else { return }
            do {
                guard try RecordingLibrary.item(at: item.directory).id == item.id else {
                    throw SessionStoreError.identityMismatch
                }
                try FileManager.default.trashItem(at: item.directory, resultingItemURL: nil)
                reloadLibrary(afterChange: true)
            } catch { errorMessage = strings.error(error) }
        }
    }
    func recover(_ item: RecordingItem) {
        guard canEdit(item) else { return }
        do {
            let recovered = try RecordingLibrary.recover(item)
            if recovered.manifest.status == .complete {
                reloadLibrary(afterChange: true)
            } else {
                finalize(recovered.directory)
            }
        } catch { errorMessage = strings.error(error) }
    }
}

extension AppModel {
    func exportTranscript(_ item: RecordingItem) {
        guard libraryMutationTask == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = item.manifest.title.replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportBusy = true
        Task {
            defer { exportBusy = false }
            do {
                try await Task.detached(priority: .utility) {
                    let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
                    let text = await journal.exportText()
                    try Data(text.utf8).write(to: destination, options: .atomic)
                }.value
            } catch { errorMessage = strings.error(error) }
        }
    }
}

extension AppModel {
    func continueProcessing(_ item: RecordingItem) {
        guard !preview, !session.active, !starting, !endingSession, libraryMutationTask == nil else { return }
        storedProcessing.start(item)
    }
}
