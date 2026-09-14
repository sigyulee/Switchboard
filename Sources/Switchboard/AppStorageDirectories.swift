import Foundation

struct AppStorageDirectories: Sendable {
    let documents: URL
    let music: URL
    let applicationSupport: URL

    static var system: Self {
        let manager = FileManager.default
        return Self(
            documents: manager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            music: manager.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Music"),
            applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory)
    }
}
