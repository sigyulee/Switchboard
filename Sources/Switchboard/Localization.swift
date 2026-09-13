import BridgeCore
import Foundation
import RecorderKit
import SwiftUI

struct AppStrings: Sendable {
    private static let bundles: [String: Bundle] = Dictionary(
        uniqueKeysWithValues:
            ApplicationLanguage.allCases.compactMap { language in
                guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                    let bundle = Bundle(path: path)
                else { return nil }
                return (language.rawValue, bundle)
            })
    let language: ApplicationLanguage
    var locale: Locale { language.locale }

    func callAsFunction(_ key: TextKey, _ arguments: CVarArg...) -> String {
        let bundle = Self.bundles[language.rawValue]
        let english = Self.bundles["en"]
        let fallback =
            english?.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil) ?? key.rawValue
        let template = bundle?.localizedString(forKey: key.rawValue, value: fallback, table: nil) ?? fallback
        return arguments.isEmpty ? template : String(format: template, locale: locale, arguments: arguments)
    }

    func error(_ error: Error) -> String {
        if let failure = error as? AppFailure { return failure.message(using: self) }
        if let failure = error as? RecorderFailure {
            return failure.media.map { self.error($0) } ?? failure.detail
        }
        if let failure = error as? AudioFailure {
            let summary = "\(self(failure.operation)) (\(failure.code))"
            return failure.detail.map { summary + "\n" + $0 } ?? summary
        }
        if let failure = error as? MediaFailure {
            let key: TextKey =
                switch failure {
                case .invalidFormat: .errorFormat
                case .invalidBuffer: .errorBuffer
                case .noRecording: .errorNoRecording
                case .overrun: .errorOverrun
                case .invalidPath: .errorPath
                case .interrupted: .errorInterrupted
                }
            return self(key)
        }
        if let failure = error as? RecordingManifestError {
            let key: TextKey =
                switch failure {
                case .unsupportedVersion: .errorVersion
                case .invalidSampleRate: .errorSampleRate
                case .invalidTimeline: .errorTimeline
                case .invalidSegment: .errorSegment
                }
            return self(key)
        }
        return error.localizedDescription
    }
}

/// Translate at presentation time so a language change also updates existing route errors.
enum AppFailure: Error, Equatable, Sendable {
    case audio(TextKey, Int32, String?)
    case media(MediaFailure)
    case manifest(RecordingManifestError)
    case detail(String)

    init(_ error: Error) {
        switch error {
        case let value as AudioFailure: self = .audio(value.operation, value.code, value.detail)
        case let value as MediaFailure: self = .media(value)
        case let value as RecordingManifestError: self = .manifest(value)
        case let value as RecorderFailure: self = value.media.map(Self.media) ?? .detail(value.detail)
        default: self = .detail(error.localizedDescription)
        }
    }

    func message(using strings: AppStrings) -> String {
        switch self {
        case .audio(let key, let code, let detail):
            let summary = "\(strings(key)) (\(code))"
            return detail.map { summary + "\n" + $0 } ?? summary
        case .media(let error): return strings.error(error)
        case .manifest(let error): return strings.error(error)
        case .detail(let message): return message
        }
    }
}

private struct AppStringsKey: EnvironmentKey {
    static let defaultValue = AppStrings(language: .english)
}

extension EnvironmentValues {
    var appStrings: AppStrings {
        get { self[AppStringsKey.self] }
        set { self[AppStringsKey.self] = newValue }
    }
}
