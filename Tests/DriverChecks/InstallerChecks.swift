// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Darwin
import Foundation

private struct CheckFailure: Error { let message: String }

@MainActor private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}

@MainActor private final class InstallationFixture {
    let fm = FileManager.default
    let root: URL
    let support: URL
    let hal: URL
    let payload: URL
    let receipt: URL
    let names = ["MIHCaller", "MIHReply", "SwitchboardAgent"]
    let legacyNames = ["MIHCaller", "MIHReply"]

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("switchboard-installer-check-" + UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        hal = root.appendingPathComponent("HAL", isDirectory: true)
        payload = root.appendingPathComponent("payload", isDirectory: true)
        receipt = support.appendingPathComponent("owned-drivers.json")
        for directory in [support, hal, payload] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in names { try makeBundle(in: payload, name: name, marker: "new") }
        try rewriteHashes()
        for name in legacyNames { try makeBundle(in: hal, name: name, marker: "old") }
        try makeBundle(in: hal, name: "Unrelated", marker: "third-party")
        try JSONEncoder().encode(legacyNames).write(to: receipt)
    }

    func cleanUp() { try? fm.removeItem(at: root) }

    func bundle(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name + ".driver", isDirectory: true)
    }

    func marker(in directory: URL, name: String) throws -> String {
        try String(
            contentsOf: bundle(in: directory, name: name).appendingPathComponent("marker"), encoding: .utf8)
    }

    func makeBundle(in directory: URL, name: String, marker: String) throws {
        let location = bundle(in: directory, name: name)
        try fm.createDirectory(
            at: location.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let ids = [
            "MIHCaller": "local.mouthinhands.Caller", "MIHReply": "local.mouthinhands.Reply",
            "SwitchboardAgent": "com.switchboard.main.agent-input",
        ]
        let info = ["CFBundleIdentifier": ids[name] ?? "third.party", "CFBundleExecutable": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: location.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: location.appendingPathComponent("marker"))
        try Data("fixture executable".utf8).write(
            to: location.appendingPathComponent("Contents/MacOS/" + name))
    }

    func rewriteHashes() throws {
        var hashes: [String: String] = [:]
        for name in names {
            let enumerator = fm.enumerator(
                at: bundle(in: payload, name: name), includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in enumerator
            where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                hashes[String(file.path.dropFirst(payload.path.count + 1))] =
                    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        try JSONEncoder().encode(hashes).write(to: payload.appendingPathComponent("hashes.json"))
    }

    func installer(command: @escaping InstallerCommand = { _, _ in }) -> DriverInstaller {
        // Only external codesign/lipo/chown/chmod commands are replaced. Identity
        // plists, hashes, actual copies/moves/removal, receipts, and rollback are real.
        DriverInstaller(support: support, hal: hal, receiptOwnerID: geteuid(), command: command)
    }

    func assertLegacyIntact() throws {
        for name in legacyNames {
            try expect(try marker(in: hal, name: name) == "old", "legacy driver restored")
        }
        let owned = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        try expect(owned == legacyNames, "legacy receipt preserved")
        try expect(try marker(in: hal, name: "Unrelated") == "third-party", "unrelated driver preserved")
    }
}

@MainActor private func expectFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch { return }
    throw CheckFailure(message: "operation should have failed")
}

@MainActor private func checkLegacyUpgradeAndRemoval() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    let installer = fixture.installer()
    try installer.install(payload: fixture.payload)
    let owned = try JSONDecoder().decode([String].self, from: Data(contentsOf: fixture.receipt))
    try expect(owned == fixture.names, "upgrade must claim all three drivers")
    for name in fixture.names {
        try expect(try fixture.marker(in: fixture.hal, name: name) == "new", "three payloads installed")
    }
    try installer.removeDrivers()
    for name in fixture.names {
        try expect(
            !fixture.fm.fileExists(atPath: fixture.bundle(in: fixture.hal, name: name).path),
            "owned driver removed")
    }
    try expect(!fixture.fm.fileExists(atPath: fixture.receipt.path), "ownership receipt removed")
    try expect(
        try fixture.marker(in: fixture.hal, name: "Unrelated") == "third-party",
        "unrelated driver survives install and removal")
}

@MainActor private func checkLegacyRemovalPreservesUnownedAgent() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    try fixture.makeBundle(in: fixture.hal, name: "SwitchboardAgent", marker: "unowned")
    try fixture.installer().removeDrivers()
    try expect(
        try fixture.marker(in: fixture.hal, name: "SwitchboardAgent") == "unowned",
        "old receipt cannot remove unowned new bus")
    try expect(
        try fixture.marker(in: fixture.hal, name: "Unrelated") == "third-party",
        "unrelated driver survives legacy removal")
}

@MainActor private func checkUnownedCollision() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    try fixture.makeBundle(in: fixture.hal, name: "SwitchboardAgent", marker: "unowned")
    try expectFailure { try fixture.installer().install(payload: fixture.payload) }
    try fixture.assertLegacyIntact()
    try expect(
        try fixture.marker(in: fixture.hal, name: "SwitchboardAgent") == "unowned",
        "unowned new bus is never replaced")
}

@MainActor private func checkThirdDriverRollback() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    let installer = fixture.installer { executable, arguments in
        if executable == "/usr/bin/codesign",
            arguments.last == fixture.bundle(in: fixture.hal, name: "SwitchboardAgent").path
        {
            throw CheckFailure(message: "injected final destination verification failure")
        }
    }
    try expectFailure { try installer.install(payload: fixture.payload) }
    try fixture.assertLegacyIntact()
    try expect(
        !fixture.fm.fileExists(atPath: fixture.bundle(in: fixture.hal, name: "SwitchboardAgent").path),
        "new third driver removed on rollback")
}

@MainActor private func checkStagedPayloadTampering() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    let installer = fixture.installer { executable, arguments in
        if executable == "/usr/bin/codesign", let path = arguments.last,
            path.hasPrefix(fixture.support.path + "/"), path.hasSuffix("SwitchboardAgent.driver")
        {
            try Data("corrupt staged payload".utf8).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("marker"))
        }
    }
    try expectFailure { try installer.install(payload: fixture.payload) }
    try fixture.assertLegacyIntact()
    try expect(
        !fixture.fm.fileExists(atPath: fixture.bundle(in: fixture.hal, name: "SwitchboardAgent").path),
        "staged validation precedes destination replacement")
}

@MainActor private func checkThreeDriverUpgradeRollback() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    try fixture.makeBundle(in: fixture.hal, name: "SwitchboardAgent", marker: "old")
    try JSONEncoder().encode(fixture.names).write(to: fixture.receipt)
    let installer = fixture.installer { executable, arguments in
        if executable == "/usr/bin/codesign",
            arguments.last == fixture.bundle(in: fixture.hal, name: "SwitchboardAgent").path
        {
            // Preflight verifies the old installed copy too; fail only after replacement.
            if try fixture.marker(in: fixture.hal, name: "SwitchboardAgent") == "new" {
                throw CheckFailure(message: "injected three-driver upgrade failure")
            }
        }
    }
    try expectFailure { try installer.install(payload: fixture.payload) }
    for name in fixture.names {
        try expect(
            try fixture.marker(in: fixture.hal, name: name) == "old", "all three previous drivers restored")
    }
    let owned = try JSONDecoder().decode([String].self, from: Data(contentsOf: fixture.receipt))
    try expect(owned == fixture.names, "three-driver ownership receipt preserved on failure")
}

@MainActor private func checkNewIdentityAndHashValidation() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    let info = fixture.bundle(in: fixture.payload, name: "SwitchboardAgent").appendingPathComponent(
        "Contents/Info.plist")
    try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": "local.mouthinhands.Reply", "CFBundleExecutable": "SwitchboardAgent",
        ], format: .xml, options: 0
    ).write(to: info)
    try fixture.rewriteHashes()
    try expectFailure { try fixture.installer().install(payload: fixture.payload) }
    try fixture.assertLegacyIntact()
}

@MainActor private func checkInvalidReceipt() throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanUp() }
    try JSONEncoder().encode(["MIHCaller", "MIHCaller"]).write(to: fixture.receipt)
    try expectFailure { _ = try fixture.installer().ownedNames() }
}

@main struct InstallerChecks {
    @MainActor static func main() {
        do {
            try checkLegacyUpgradeAndRemoval()
            try checkLegacyRemovalPreservesUnownedAgent()
            try checkUnownedCollision()
            try checkThirdDriverRollback()
            try checkStagedPayloadTampering()
            try checkThreeDriverUpgradeRollback()
            try checkNewIdentityAndHashValidation()
            try checkInvalidReceipt()
            print(
                "Installer transaction checks passed: eight scenarios, temporary paths, no privileged commands."
            )
        } catch {
            FileHandle.standardError.write(Data("Installer transaction check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
