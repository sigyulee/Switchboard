import Foundation

struct AppBuildVersion {
    let release: String?
    let build: String?
    let beta: Bool

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        beta = info["SwitchboardReleaseChannel"] as? String == "beta"
        release = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
    }

    var display: String {
        guard let release, !release.isEmpty else { return "—" }
        let version = beta ? "\(release) beta" : release
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}
