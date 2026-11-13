import AetherEngine
import CryptoKit
import Foundation

@MainActor
enum PlaybackTrackPreferences {
    struct Key: Hashable, Sendable {
        fileprivate let storageID: String

        init(accountID: String? = nil, profileID: Int?, contentID: String, kind: CinemetaKind) {
            let account = accountID ?? ""
            storageID = PlaybackTrackPreferences.fingerprint(
                "\(account.utf8.count):\(account):\(profileID.map(String.init) ?? "guest"):\(kind.rawValue):\(contentID)"
            )
        }
    }

    enum SubtitleChoice: Codable, Equatable, Sendable {
        case off
        case embedded(TrackPreference)
        case addon(TrackPreference)
    }

    struct TrackPreference: Codable, Equatable, Sendable {
        private let nameFingerprint: String?
        private let language: String?
        private let codec: String
        private let channels: Int
        private let isExternal: Bool
        private let isForced: Bool
        private let isHearingImpaired: Bool
        private let isCommentary: Bool
        private let isVisualImpaired: Bool

        init(_ track: TrackInfo) {
            let name = track.name
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            let generatedName = name.range(of: #"^(track|audio|subtitle|external)\s*\d+$"#, options: .regularExpression) != nil
            // Labels can be provider-controlled, so persist only their fingerprint.
            nameFingerprint = name.isEmpty || generatedName ? nil : PlaybackTrackPreferences.fingerprint(name)
            language = Self.languageIdentifier(track.language)
            codec = track.codec.lowercased()
            channels = track.channels
            isExternal = track.isExternal
            isForced = track.isForced
            isHearingImpaired = track.isHearingImpaired
            isCommentary = track.isCommentary
            isVisualImpaired = track.isVisualImpaired
        }

        func match(in tracks: [TrackInfo]) -> TrackInfo? {
            let candidates = tracks.compactMap { track in
                score(for: TrackPreference(track)).map { (track, $0) }
            }
            guard let best = candidates.map(\.1).max() else { return nil }
            let matches = candidates.filter { $0.1 == best }
            return matches.count == 1 ? matches.first?.0 : nil
        }

        private func score(for track: TrackPreference) -> Int? {
            guard track.isExternal == isExternal, track.isForced == isForced,
                  track.isHearingImpaired == isHearingImpaired, track.isCommentary == isCommentary,
                  track.isVisualImpaired == isVisualImpaired else { return nil }
            let nameMatches = nameFingerprint != nil && track.nameFingerprint == nameFingerprint
            let languageScore = Self.languageScore(language, track.language)
            guard languageScore >= 0, nameMatches || languageScore > 0 else { return nil }

            var score = languageScore
            if nameMatches { score += 8 }
            if !codec.isEmpty, track.codec == codec { score += 2 }
            if channels > 0, track.channels == channels { score += 1 }
            return score
        }

        private static func languageIdentifier(_ value: String?) -> String? {
            guard let value else { return nil }
            let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !code.isEmpty, code.count <= 24,
                  code.range(of: #"^[a-z]{2,3}([_-][a-z0-9]{2,8}){0,2}$"#, options: .regularExpression) != nil else {
                return nil
            }
            let locale = Locale.Language(identifier: code)
            guard let language = locale.languageCode?.identifier(.alpha2), language != "und" else { return nil }
            return [language, locale.script?.identifier, locale.region?.identifier]
                .compactMap { $0 }.joined(separator: "-").lowercased()
        }

        private static func languageScore(_ first: String?, _ second: String?) -> Int {
            guard let first, let second else { return 0 }
            if first == second { return 4 }
            let firstParts = first.split(separator: "-")
            let secondParts = second.split(separator: "-")
            if firstParts.first == secondParts.first, firstParts.count == 1 || secondParts.count == 1 { return 3 }
            return -1
        }
    }

    private struct Entry: Codable {
        let key: String
        var audio: TrackPreference?
        var subtitle: SubtitleChoice?
    }

    private static let storageKey = "playback.trackPreferences.v1"
    private static let limit = 250

    static func audio(for key: Key) -> TrackPreference? {
        entries.first { $0.key == key.storageID }?.audio
    }

    static func subtitle(for key: Key) -> SubtitleChoice? {
        entries.first { $0.key == key.storageID }?.subtitle
    }

    static func saveAudio(_ track: TrackInfo, for key: Key) {
        update(key) { $0.audio = TrackPreference(track) }
    }

    static func saveSubtitle(_ track: TrackInfo?, for key: Key) {
        let choice = track.map { $0.isExternal ? SubtitleChoice.addon(TrackPreference($0)) : .embedded(TrackPreference($0)) } ?? .off
        update(key) { $0.subtitle = choice }
    }

    private static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private static func update(_ key: Key, changes: (inout Entry) -> Void) {
        var entries = entries
        var entry = entries.first { $0.key == key.storageID } ?? Entry(key: key.storageID)
        changes(&entry)
        entries.removeAll { $0.key == key.storageID }
        entries.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    nonisolated private static func fingerprint(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}
