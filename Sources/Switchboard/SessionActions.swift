import AppKit
import BridgeCore
import Foundation
import RecorderKit
import UniformTypeIdentifiers

extension AppModel {
    func selectApplication(_ application: ApplicationIdentity, forAgent: Bool) {
        guard !session.active, !session.busy else { return }
        do {
            guard var profile = routeProfile else { return }
            if forAgent { profile.agent = application } else { profile.caller = application }
            try profile.validate()
            routeProfile = profile
            if !preview { defaults.set(try JSONEncoder().encode(profile), forKey: "routeProfile") }
            refresh()
        } catch { errorMessage = strings.error(error) }
    }

    func chooseApplication(forAgent: Bool) {
        guard !session.active, !session.busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
            let application = ApplicationCatalog.identity(at: url)
        else { return }
        selectApplication(application, forAgent: forAgent)
    }

    func saveSession() {
        guard session.directory != nil, !session.busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(exportedAs: "com.switchboard.main.session", conformingTo: .package)
        ]
        panel.canCreateDirectories = true
        panel.directoryURL = recordingRoot
        panel.nameFieldStringValue = (session.state?.name ?? "Session").replacingOccurrences(
            of: "/", with: "-")
        guard panel.runModal() == .OK, let destination = panel.url else {
            session.cancelEnd()
            return
        }
        endingSession = true
        sessionSaveTask = Task {
            defer {
                if session.closed || session.state == nil { restoreInput() }
                endingSession = false
                sessionSaveTask = nil
            }
            do {
                await storedProcessing.pause()
                await playback.stopAndWait()
                let replacement = try await Task.detached(priority: .utility) {
                    () throws -> SessionReplacementAuthorization? in
                    if FileManager.default.fileExists(atPath: destination.path) {
                        return try SessionStore.replacementAuthorization(for: destination)
                    }
                    return nil as SessionReplacementAuthorization?
                }.value
                await transcript.finishForSave(session: session)
                let publication = try await session.save(to: destination, replacement: replacement)
                sessionName = ""
                sessionDescription = ""
                loadDrafts()
                reloadLibrary(afterChange: true)
                if let backup = publication?.retainedReplacementBackup {
                    do { try FileManager.default.trashItem(at: backup, resultingItemURL: nil) } catch {
                        errorMessage = strings(.errorReplacementBackup, backup.path)
                    }
                }
            } catch { errorMessage = strings.error(error) }
        }
    }

    func discardSession() {
        guard session.directory != nil, !session.busy else { return }
        endingSession = true
        sessionSaveTask = Task {
            defer {
                if session.closed || session.state == nil { restoreInput() }
                endingSession = false
                sessionSaveTask = nil
            }
            do {
                await transcript.finishForSave(session: session)
                if let directory = try await session.discard() {
                    try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
                }
                sessionName = ""
                sessionDescription = ""
                loadDrafts()
            } catch { errorMessage = strings.error(error) }
        }
    }

    func addLibraryFolder() {
        guard !preview else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var folders = try LibraryFolders(defaultRoot: recordingRoot, addedRoots: addedLibraryFolders)
            for url in panel.urls { try folders.add(url) }
            addedLibraryFolders = folders.addedRoots
            defaults.set(addedLibraryFolders.map(\.path), forKey: "libraryFolders")
            reloadLibrary(afterChange: true)
        } catch { errorMessage = strings.error(error) }
    }

    func removeLibraryFolder(_ url: URL) {
        guard !preview else { return }
        addedLibraryFolders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        defaults.set(addedLibraryFolders.map(\.path), forKey: "libraryFolders")
        reloadLibrary(afterChange: true)
    }

    func chooseSessionToOpen() {
        guard canOpenSessionFile else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(exportedAs: "com.switchboard.main.session", conformingTo: .package),
            UTType(importedAs: "com.switchboard.main.recording", conformingTo: .package),
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSession(at: url)
    }

    func openSession(at url: URL) {
        guard canOpenSessionFile else {
            errorMessage = strings(.sessionBusy)
            return
        }
        guard url.isFileURL, ["switchboard", "mihrecording"].contains(url.pathExtension.lowercased()),
            url.standardizedFileURL != session.directory?.standardizedFileURL
        else { return }
        do {
            let item = try RecordingLibrary.item(at: url)
            directRecordings.removeAll { $0.id == item.id }
            directRecordings.append(item)
            if !recordings.contains(where: { $0.id == item.id }) { recordings.append(item) }
            selectedRecordingID = item.id
            navigate(to: "library")
            reloadLibrary(afterChange: true)
        } catch { errorMessage = strings.error(error) }
    }
}

extension AppModel {
    func setTranscriptionEnabled(_ enabled: Bool) {
        guard !endingSession, !masterBusy, session.active, !session.busy else { return }
        if enabled {
            transcript.openConfiguration()
        } else {
            transcript.disable(session: session)
        }
    }
}
