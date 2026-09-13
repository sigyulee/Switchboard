import Foundation

enum PrivilegedInstaller {
    static func run(remove: Bool = false) async throws -> String {
        guard let resources = Bundle.main.resourceURL else {
            throw AudioFailure(operation: .errorResources, code: -1)
        }
        let helper = resources.appendingPathComponent("InstallerTool")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AudioFailure(operation: .errorBundledApp, code: -1)
        }
        let operation = remove ? "remove" : "install"
        return try await Task.detached(priority: .userInitiated) {
            let source = """
                on open filePath
                    set commandText to "exec " & quoted form of filePath & " \(operation)"
                    do shell script commandText with administrator privileges
                end open
                """
            guard let script = NSAppleScript(source: source) else {
                throw AudioFailure(operation: .errorInstaller, code: -1)
            }
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(
                NSAppleEventDescriptor(string: helper.path), forKeyword: AEKeyword(keyDirectObject))
            var error: NSDictionary?
            let result = script.executeAppleEvent(event, error: &error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? -1
                throw AudioFailure(
                    operation: code == -128 ? .errorInstallCancelled : .errorInstallFailed,
                    code: code, detail: error[NSAppleScript.errorMessage] as? String)
            }
            return result.stringValue ?? "Installation finished"
        }.value
    }
}
