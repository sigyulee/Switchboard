// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Switchboard", targets: ["Switchboard"]),
        .executable(name: "BridgeChecks", targets: ["BridgeChecks"]),
    ],
    targets: [
        .target(name: "BridgeCore"),
        .target(name: "RecorderKit", dependencies: ["BridgeCore"]),
        .target(
            name: "AudioRealtime", publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]),
        .executableTarget(
            name: "Switchboard", dependencies: ["BridgeCore", "AudioRealtime", "RecorderKit"],
            exclude: ["Resources"]),
        .executableTarget(
            name: "BridgeChecks", dependencies: ["BridgeCore", "AudioRealtime", "RecorderKit"],
            path: "Tests/BridgeCoreTests"),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
