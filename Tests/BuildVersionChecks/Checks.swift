import Foundation

@main struct BuildVersionChecks {
    static func main() {
        let version = AppBuildVersion(info: [
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "45",
            "SourceCommit": "private-commit", "GitBranch": "private-branch",
        ])
        precondition(version.display == "1.1.0 (45)", "Version display must contain only release and build")
        precondition(
            AppBuildVersion(info: [:]).display == "—", "Missing metadata must not invent an identity")
        precondition(
            AppBuildVersion(info: ["CFBundleShortVersionString": "1.1.0"]).display == "1.1.0",
            "Legacy metadata must remain readable")
        precondition(
            AppBuildVersion(info: [
                "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "5",
                "SwitchboardReleaseChannel": "beta",
            ]).display == "1.1.0 beta (5)")
        print("4 build-version display checks passed; Git metadata is not displayed.")
    }
}
