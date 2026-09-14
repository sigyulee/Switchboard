import CryptoKit
import Darwin
import Foundation

enum InstallError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

@MainActor func executeInstallerCommand(_ executable: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw InstallError.invalid("Operation failed: \(executable)")
    }
}
typealias InstallerCommand = @MainActor (String, [String]) throws -> Void

@MainActor final class DriverInstaller {
    let fm = FileManager.default
    let support: URL
    let hal: URL
    let receipt: URL
    let names = ["MIHCaller", "MIHReply", "SwitchboardAgent"]
    private let identifiers = [
        "MIHCaller": "local.mouthinhands.Caller",
        "MIHReply": "local.mouthinhands.Reply",
        "SwitchboardAgent": "com.switchboard.main.agent-input",
    ]
    private let receiptOwnerID: UInt32
    private let command: InstallerCommand

    init(
        support: URL, hal: URL, receiptOwnerID: UInt32 = 0,
        command: @escaping InstallerCommand = executeInstallerCommand
    ) {
        self.support = support
        self.hal = hal
        self.receipt = support.appendingPathComponent("owned-drivers.json")
        self.receiptOwnerID = receiptOwnerID
        self.command = command
    }

    func requireSafePath(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            if fm.fileExists(atPath: current.path),
                (try current.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
            {
                throw InstallError.invalid("Symbolic links are not accepted: \(current.path)")
            }
            current.deleteLastPathComponent()
        }
    }
    func requireRootDirectory(_ url: URL) throws {
        try requireSafePath(url)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o022 == 0
        else { throw InstallError.invalid("Unsafe installation directory: \(url.path)") }
    }
    func identity(_ bundle: URL, name: String) throws {
        try requireSafePath(bundle)
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let expectedIdentifier = identifiers[name],
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == expectedIdentifier,
            info["CFBundleExecutable"] as? String == name
        else { throw InstallError.invalid("Unexpected driver identity") }
        try command("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        try command(
            "/usr/bin/lipo",
            ["-verify_arch", "arm64", bundle.appendingPathComponent("Contents/MacOS/\(name)").path])
    }
    func ownedNames() throws -> [String] {
        guard fm.fileExists(atPath: receipt.path) else { return [] }
        try requireSafePath(receipt)
        guard
            (try fm.attributesOfItem(atPath: receipt.path)[.ownerAccountID] as? NSNumber)?.uint32Value
                == receiptOwnerID
        else {
            throw InstallError.invalid("Invalid ownership receipt")
        }
        let owned = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        guard Set(owned).count == owned.count, Set(owned).isSubset(of: Set(names)) else {
            throw InstallError.invalid("Invalid ownership receipt entries")
        }
        return owned
    }
    func verifyPayload(_ root: URL) throws {
        let hashes = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: root.appendingPathComponent("hashes.json")))
        for name in names {
            let bundle = root.appendingPathComponent(name + ".driver")
            try identity(bundle, name: name)
            guard
                let enumerator = fm.enumerator(
                    at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else { throw InstallError.invalid("Missing payload") }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw InstallError.invalid("Symlink in payload") }
                if values.isRegularFile == true {
                    let relative = String(file.path.dropFirst(root.path.count + 1))
                    let digest = SHA256.hash(data: try Data(contentsOf: file)).map {
                        String(format: "%02x", $0)
                    }
                    .joined()
                    guard hashes[relative] == digest else {
                        throw InstallError.invalid("Payload checksum mismatch")
                    }
                }
            }
        }
    }
    func install(payload: URL) throws {
        try verifyPayload(payload)
        let owned = try ownedNames()
        for name in names {
            let destination = hal.appendingPathComponent(name + ".driver")
            try requireSafePath(destination)
            if fm.fileExists(atPath: destination.path) {
                guard owned.contains(name) else {
                    throw InstallError.invalid("Refusing to replace an unowned driver")
                }
                try identity(destination, name: name)
            }
        }
        let stage = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(
            at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var replaced: [String] = []
        do {
            for name in names {
                let staged = stage.appendingPathComponent(name + ".driver")
                try fm.copyItem(at: payload.appendingPathComponent(name + ".driver"), to: staged)
            }
            try fm.copyItem(
                at: payload.appendingPathComponent("hashes.json"),
                to: stage.appendingPathComponent("hashes.json")
            )
            // Verify the root-owned snapshot; the source app may be writable by its owner.
            try verifyPayload(stage)
            for name in names {
                let staged = stage.appendingPathComponent(name + ".driver")
                try command("/usr/sbin/chown", ["-R", "root:wheel", staged.path])
                try command("/bin/chmod", ["-R", "u=rwX,go=rX", staged.path])
                let destination = hal.appendingPathComponent(name + ".driver")
                if fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: destination, to: stage.appendingPathComponent(name + ".backup"))
                }
                replaced.append(name)
                try fm.moveItem(at: staged, to: destination)
                try identity(destination, name: name)
            }
            try JSONEncoder().encode(names).write(to: receipt, options: .atomic)
        } catch {
            for name in replaced.reversed() {
                let destination = hal.appendingPathComponent(name + ".driver")
                if fm.fileExists(atPath: destination.path) {
                    do { try fm.removeItem(at: destination) } catch {
                        FileHandle.standardError.write(Data("Rollback removal failed: \(error)\n".utf8))
                        continue
                    }
                }
                let backup = stage.appendingPathComponent(name + ".backup")
                if fm.fileExists(atPath: backup.path) {
                    do { try fm.moveItem(at: backup, to: destination) } catch {
                        FileHandle.standardError.write(
                            Data("Backup retained at \(backup.path): \(error)\n".utf8))
                    }
                }
            }
            throw error
        }
        // Receipt writing commits the transaction. Cleanup must never trigger rollback.
        do { try fm.removeItem(at: stage) } catch {
            FileHandle.standardError.write(
                Data("Installed successfully; cleanup remains at \(stage.path): \(error)\n".utf8))
        }
    }
    func removeDrivers() throws {
        let owned = try ownedNames()
        for name in names where owned.contains(name) {
            let destination = hal.appendingPathComponent(name + ".driver")
            if fm.fileExists(atPath: destination.path) {
                try identity(destination, name: name)
                try fm.removeItem(at: destination)
            }
        }
        if fm.fileExists(atPath: receipt.path) { try fm.removeItem(at: receipt) }
    }
}

#if !INSTALLER_TESTING
    @main struct InstallerMain {
        @MainActor static func main() {
            do {
                guard geteuid() == 0, CommandLine.arguments.count == 2,
                    ["install", "remove"].contains(CommandLine.arguments[1])
                else {
                    throw InstallError.invalid(
                        "Administrator authorization and a fixed operation are required")
                }
                let support = URL(
                    fileURLWithPath: "/Library/Application Support/MouthInHands", isDirectory: true)
                let hal = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
                let installer = DriverInstaller(support: support, hal: hal)
                let fm = FileManager.default
                try installer.requireSafePath(support)
                try installer.requireSafePath(hal)
                try fm.createDirectory(
                    at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                try fm.createDirectory(
                    at: hal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                try installer.requireRootDirectory(support)
                try installer.requireRootDirectory(hal)
                let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                    .deletingLastPathComponent()
                if CommandLine.arguments[1] == "install" {
                    try installer.install(payload: resources.appendingPathComponent("Drivers"))
                } else {
                    try installer.removeDrivers()
                }
                try executeInstallerCommand("/usr/bin/killall", ["-TERM", "coreaudiod"])
                print("Operation complete. Waiting for Core Audio to load the devices.")
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }
#endif
