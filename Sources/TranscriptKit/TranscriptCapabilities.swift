import BridgeCore
import Foundation
import Speech
import Translation

@available(macOS 26.0, *)
public struct TranscriptCapabilities: Sendable {
    public let states: [AudioSide: TranscriptSideState]
    public let speechLocaleIdentifiers: [AudioSide: String]
    public let maximumReservedLocales: Int

    public static func supportedSpeechLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    public static func supportedTranslationLanguageIdentifiers() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier).sorted()
    }

    /// Call only from an explicit user download action. Live engine startup never calls this.
    public static func installSpeechModels(configuration: TranscriptConfiguration) async throws {
        try configuration.validate()
        var locales: [Locale] = []
        for side in AudioSide.allCases {
            if let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: configuration.sourceLocaleIdentifier(for: side))),
                !locales.contains(locale)
            {
                locales.append(locale)
            }
        }
        guard !locales.isEmpty else { throw TranscriptFailure.invalidConfiguration }
        for locale in locales {
            try Task.checkCancellation()
            let lease = try await SpeechLocaleReservations.shared.acquire(locale: locale)
            do {
                try Task.checkCancellation()
                let transcriber = SpeechTranscriber(
                    locale: locale, preset: .timeIndexedProgressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try await request.downloadAndInstall()
                    } onCancel: {
                        request.progress.cancel()
                    }
                }
                await SpeechLocaleReservations.shared.release(lease)
            } catch {
                await SpeechLocaleReservations.shared.release(lease)
                throw error
            }
        }
    }

    public static func check(configuration: TranscriptConfiguration) async -> Self {
        let installed = await SpeechTranscriber.installedLocales
        var states: [AudioSide: TranscriptSideState] = [:]
        var identifiers: [AudioSide: String] = [:]
        let availability = LanguageAvailability()
        for side in AudioSide.allCases {
            let source = configuration.sourceLocaleIdentifier(for: side)
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: source))
            let speech: TranscriptModelState
            if let locale, SpeechTranscriber.isAvailable {
                identifiers[side] = locale.identifier
                speech = installed.contains(locale) ? .ready : .downloadRequired
            } else {
                speech = .unsupported
            }
            let translation: TranscriptModelState
            if configuration.skipsTranslation(for: side) {
                translation = .notNeeded
            } else {
                switch await availability.status(
                    from: Locale.Language(identifier: source),
                    to: Locale.Language(identifier: configuration.targetLocaleIdentifier))
                {
                case .installed: translation = .ready
                case .supported: translation = .downloadRequired
                case .unsupported: translation = .unsupported
                @unknown default: translation = .unsupported
                }
            }
            states[side] = TranscriptSideState(side: side, speech: speech, translation: translation)
        }
        return Self(
            states: states, speechLocaleIdentifiers: identifiers,
            maximumReservedLocales: AssetInventory.maximumReservedLocales)
    }
}

struct SpeechLocaleLease: Sendable {
    let id: UUID
    let key: String
}

/// Serializes app-wide reservation changes across engine instances and shares equal locales.
@available(macOS 26.0, *)
actor SpeechLocaleReservations {
    static let shared = SpeechLocaleReservations()
    private struct Reservation {
        let locale: Locale
        let owned: Bool
        var holders: Set<UUID>
    }
    private var reservations: [String: Reservation] = [:]
    private var tail: Task<Void, Never>?

    func acquire(locale: Locale) async throws -> SpeechLocaleLease {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await self.acquireSerial(locale)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func release(_ lease: SpeechLocaleLease) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await self.releaseSerial(lease)
        }
        tail = task
        await task.value
    }

    private func acquireSerial(_ locale: Locale) async throws -> SpeechLocaleLease {
        let key = Locale.identifier(.bcp47, from: locale.identifier)
        let lease = SpeechLocaleLease(id: UUID(), key: key)
        if var reservation = reservations[key] {
            reservation.holders.insert(lease.id)
            reservations[key] = reservation
            return lease
        }
        // Apple enforces maximumReservedLocales, including reservations made elsewhere in this app.
        // A false return means somebody else owns the reservation; never release that reservation.
        let owned = try await AssetInventory.reserve(locale: locale)
        reservations[key] = Reservation(locale: locale, owned: owned, holders: [lease.id])
        return lease
    }

    private func releaseSerial(_ lease: SpeechLocaleLease) async {
        guard var reservation = reservations[lease.key], reservation.holders.remove(lease.id) != nil else {
            return
        }
        guard reservation.holders.isEmpty else {
            reservations[lease.key] = reservation
            return
        }
        reservations[lease.key] = nil
        if reservation.owned { await AssetInventory.release(reservedLocale: reservation.locale) }
    }
}
