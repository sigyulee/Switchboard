import AppKit
import BridgeCore
import Foundation
import RecorderKit
import TranscriptKit
import UniformTypeIdentifiers

extension AppModel {
    func exportAll(_ item: RecordingItem) {
        guard canEdit(item), !exportBusy, libraryMutationTask == nil else { return }
        exportBusy = true
        libraryMutationTask = Task {
            defer {
                exportBusy = false
                libraryMutationTask = nil
            }
            do {
                if storedProcessing.itemID == item.id { await storedProcessing.pause() }
                try Task.checkCancellation()
                guard canEdit(item) else { return }
                let preparation = Task.detached(priority: .utility) {
                    try SessionStore.prepareExport(of: item)
                }
                let source = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard canEdit(item) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [
                    UTType(exportedAs: "com.switchboard.main.session", conformingTo: .package)
                ]
                panel.canCreateDirectories = true
                panel.prompt = strings(.actionExport)
                panel.nameFieldStringValue =
                    source.title.replacingOccurrences(of: "/", with: "-")
                    + "." + source.fileExtension
                let validation = SessionExportPanelValidation(source: source, strings: strings)
                panel.delegate = validation
                guard withExtendedLifetime(validation, { panel.runModal() }) == .OK,
                    let destination = panel.url, canEdit(item)
                else { return }
                try Task.checkCancellation()
                let copy = Task.detached(priority: .utility) {
                    try SessionStore.exportCopy(of: source, to: destination)
                }
                let exported = try await withTaskCancellationHandler {
                    try await copy.value
                } onCancel: {
                    copy.cancel()
                }
                guard !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = strings(.libraryExportError, strings.error(error)) }
            }
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
            useRecordingFolder(url)
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
    func canRenameDraft(_ draft: StoredSession) -> Bool {
        !preview && !session.active && !starting && !endingSession && !session.busy
            && !exportBusy && libraryMutationTask == nil
    }
    func renameDraft(_ draft: StoredSession) {
        guard canRenameDraft(draft) else { return }
        let reopen = session.closed && session.sessionID == draft.manifest.id
        if reopen { closeSessionView() }
        do {
            rename(try RecordingLibrary.item(at: draft.directory))
            loadDrafts()
            if reopen,
                let refreshed = try SessionStore(draftRoot: draft.directory.deletingLastPathComponent())
                    .drafts().first(where: { $0.manifest.id == draft.manifest.id })
            {
                selectedRecordingID = refreshed.manifest.id
                openDraft(refreshed)
            }
        } catch { errorMessage = strings.error(error) }
    }
    func rename(_ item: RecordingItem) {
        guard canEdit(item), !exportBusy, libraryMutationTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = strings(.libraryRenameTitle)
        let field = NSTextField(string: item.manifest.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: strings(.actionSave))
        alert.addButton(withTitle: strings(.actionCancel))
        if alert.runModal() == .alertFirstButtonReturn, canEdit(item), !exportBusy, libraryMutationTask == nil
        {
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
        guard canStartRecovery(item) else { return }
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

@MainActor private final class SessionExportPanelValidation: NSObject, NSOpenSavePanelDelegate {
    private let source: SessionExportSource
    private let strings: AppStrings

    init(source: SessionExportSource, strings: AppStrings) {
        self.source = source
        self.strings = strings
    }

    func panel(_ sender: Any, validate url: URL) throws {
        do {
            _ = try SessionStore.validateExportDestination(url, for: source)
        } catch {
            throw NSError(
                domain: "com.switchboard.main.export", code: 1,
                userInfo: [NSLocalizedDescriptionKey: strings.error(error)])
        }
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
