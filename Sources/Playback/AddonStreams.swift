import CryptoKit
import Foundation

struct AddonStream: Identifiable, Sendable {
    typealias FocusKey = SHA256.Digest

    enum Destination: Hashable, Sendable {
        case video(URL), external(URL)
    }

    let id: UUID
    let addon: String
    let name: String
    let description: String?
    let filename: String?
    let videoHash: String?
    let videoSize: Int64?
    let notWebReady: Bool
    let subtitles: [AddonSubtitle]
    let destination: Destination
    let requestHeaders: [String: String]
    var focusKeys: [FocusKey] = []

    var prefersAether: Bool {
        guard case .video(let url) = destination else { return false }
        if notWebReady || !requestHeaders.isEmpty { return true }
        let additionalFormats = ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mpd", "iso"]
        let extensions = [filename.map { ($0 as NSString).pathExtension }, url.pathExtension]
        return extensions.compactMap { $0?.lowercased() }.contains { additionalFormats.contains($0) }
    }
}

struct AddonSubtitle: Decodable, Sendable {
    let url: URL
    let lang: String?
    var name: String?
    var source: String?

    private enum CodingKeys: String, CodingKey {
        case url, lang, language, name, title, label, filename
    }

    init(url: URL, lang: String?, name: String?, source: String? = nil) {
        self.url = url
        self.lang = lang
        self.name = name
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(for key: CodingKeys) -> String? {
            let value = try? values.decode(String.self, forKey: key)
            let words = value?.split(whereSeparator: \.isWhitespace) ?? []
            return words.isEmpty ? nil : String(words.joined(separator: " ").prefix(160))
        }
        url = try values.decode(URL.self, forKey: .url)
        lang = text(for: .lang) ?? text(for: .language)
        name = text(for: .name) ?? text(for: .title) ?? text(for: .label) ?? text(for: .filename)
    }

    var isHTTPS: Bool {
        url.scheme?.lowercased() == "https" && url.host() != nil && url.user() == nil && url.password() == nil
    }
}

struct AddonStreamResults: Sendable {
    let streams: [AddonStream]
    let failedAddons: Int
    let unsupportedStreams: Int

    func focusKeys(for stream: AddonStream) -> [AddonStream.FocusKey] {
        // Remember only keys that distinguish this row in the old list. The replacement list
        // must also contain exactly one match before focus can be restored.
        stream.focusKeys.filter { uniqueStream(with: $0)?.id == stream.id }
    }

    func stream(matching focusKeys: [AddonStream.FocusKey]) -> AddonStream? {
        for key in focusKeys {
            if let stream = uniqueStream(with: key) { return stream }
        }
        return nil
    }

    private func uniqueStream(with key: AddonStream.FocusKey) -> AddonStream? {
        let matches = streams.lazy.filter { $0.focusKeys.contains(key) }.prefix(2)
        return matches.count == 1 ? matches.first : nil
    }
}

struct AddonStreams: Sendable {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func subtitles(
        addons: [NuvioAddon], kind: CinemetaKind, videoIDs: [String], stream: AddonStream? = nil
    ) async -> [AddonSubtitle] {
        let extra = subtitleExtra(for: stream)
        return await withTaskGroup(of: [AddonSubtitle].self) { group in
            for addon in addons where addon.enabled {
                group.addTask {
                    guard let url = manifestURL(addon), let manifest: Manifest = try? await fetch(url) else { return [] }
                    let provider = clean(manifest.name) ?? clean(addon.name)
                    for id in videoIDs where manifest.supports(kind: kind, id: id, resourceName: "subtitles") {
                        guard !Task.isCancelled,
                              let base = subtitleEndpoint(manifest: url, kind: kind, id: id) else { continue }
                        if let extra, let matching = subtitleEndpoint(manifest: url, kind: kind, id: id, extra: extra) {
                            async let matchedTracks = subtitleTracks(at: matching, source: provider)
                            async let baseTracks = subtitleTracks(at: base, source: provider)
                            let tracks = await matchedTracks + baseTracks
                            if !tracks.isEmpty { return tracks }
                        } else {
                            let tracks = await subtitleTracks(at: base, source: provider)
                            if !tracks.isEmpty { return tracks }
                        }
                    }
                    return []
                }
            }
            var tracks: [AddonSubtitle] = []
            var seen: Set<URL> = []
            for await batch in group {
                tracks += batch.filter { $0.isHTTPS && seen.insert($0.url).inserted }
            }
            return tracks
        }
    }

    func load(addons: [NuvioAddon], kind: CinemetaKind, videoIDs: [String]) async -> AddonStreamResults {
        let active = addons.filter(\.enabled).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        var results: [ProviderResult] = []

        // Limit concurrent requests while keeping the user's configured source order.
        for batchStart in stride(from: 0, to: active.count, by: 4) {
            if Task.isCancelled { break }
            let batchEnd = min(batchStart + 4, active.count)
            let batch = await withTaskGroup(of: (Int, ProviderResult).self) { group in
                for index in batchStart..<batchEnd {
                    let addon = active[index]
                    group.addTask { (index, await load(addon: addon, kind: kind, videoIDs: videoIDs)) }
                }
                var values: [(Int, ProviderResult)] = []
                for await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            results.append(contentsOf: batch)
        }

        var seen = Set<StreamIdentity>()
        let streams = results.flatMap(\.streams).filter {
            seen.insert(StreamIdentity(destination: $0.destination, requestHeaders: $0.requestHeaders)).inserted
        }
        return AddonStreamResults(streams: streams, failedAddons: results.filter(\.failed).count,
                                  unsupportedStreams: results.reduce(0) { $0 + $1.unsupported })
    }

    private func load(addon: NuvioAddon, kind: CinemetaKind, videoIDs: [String]) async -> ProviderResult {
        guard let manifestURL = manifestURL(addon) else { return ProviderResult(failed: true) }

        do {
            let manifest: Manifest = try await fetch(manifestURL)
            let provider = clean(manifest.name) ?? clean(addon.name) ?? String(localized: "Add-on")
            var unsupported = 0
            var failed = false
            for id in videoIDs where manifest.supports(kind: kind, id: id) {
                try Task.checkCancellation()
                let url = manifestURL.deletingLastPathComponent()
                    .appendingPathComponent("stream")
                    .appendingPathComponent(kind.rawValue)
                    .appendingPathComponent(id + ".json")
                let response: Streams
                do {
                    response = try await fetch(url)
                } catch {
                    try Task.checkCancellation()
                    failed = true
                    continue
                }
                let streams = response.streams.compactMap { stream -> AddonStream? in
                    guard let (destination, requestHeaders) = stream.playbackSource else { return nil }
                    let name = clean(stream.name)
                    let description = clean(stream.description ?? stream.title, limit: 240)
                    return AddonStream(id: UUID(), addon: provider, name: name ?? String(localized: "Source"),
                                       description: description, filename: stream.behaviorHints?.filename,
                                       videoHash: stream.behaviorHints?.videoHash,
                                       videoSize: stream.behaviorHints?.videoSize,
                                       notWebReady: stream.behaviorHints?.notWebReady == true,
                                       subtitles: stream.subtitles?.compactMap(\.value).filter(\.isHTTPS) ?? [],
                                       destination: destination, requestHeaders: requestHeaders,
                                       focusKeys: stream.focusKeys(providerID: addon.id, destination: destination,
                                                                    headers: requestHeaders, name: name,
                                                                    description: description))
                }
                unsupported += response.entriesCount - streams.count
                if !streams.isEmpty { return ProviderResult(streams: streams, unsupported: unsupported) }
            }
            return ProviderResult(unsupported: unsupported, failed: failed)
        } catch {
            return ProviderResult(failed: true)
        }
    }

    private func fetch<Value: Decodable>(_ url: URL) async throws -> Value {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: AddonRedirects())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func subtitleTracks(at endpoint: URL, source: String?) async -> [AddonSubtitle] {
        guard !Task.isCancelled, let response: Subtitles = try? await fetch(endpoint) else { return [] }
        return response.tracks.filter(\.isHTTPS).map { track in
            var track = track
            track.source = source
            return track
        }
    }

    private func subtitleExtra(for stream: AddonStream?) -> String? {
        guard let stream else { return nil }
        var values: [String] = []
        if let hash = stream.videoHash.flatMap({ encodedSubtitleValue($0, limit: 128) }) {
            values.append("videoHash=\(hash)")
        }
        if let size = stream.videoSize, size > 0 {
            values.append("videoSize=\(size)")
        }
        if let filename = stream.filename.flatMap({ encodedSubtitleValue($0, limit: 512) }) {
            values.append("filename=\(filename)")
        }
        return values.isEmpty ? nil : values.joined(separator: "&")
    }

    private func subtitleEndpoint(manifest: URL, kind: CinemetaKind, id: String, extra: String? = nil) -> URL? {
        let base = manifest.deletingLastPathComponent().appendingPathComponent("subtitles")
            .appendingPathComponent(kind.rawValue)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let encodedID = encodedSubtitleValue(id, limit: 256) else { return nil }
        // Stremio expects extras in a path segment before .json, with encoded values and literal delimiters.
        let tail = extra.map { "/\($0)" } ?? ""
        components.percentEncodedPath += "/\(encodedID)\(tail).json"
        return components.url.flatMap(Self.httpsURL)
    }

    private func encodedSubtitleValue(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limit,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return trimmed.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    private func manifestURL(_ addon: NuvioAddon) -> URL? {
        guard var parts = URLComponents(string: addon.url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if parts.scheme?.lowercased() == "stremio" { parts.scheme = "https" }
        guard var url = parts.url.flatMap(Self.httpsURL) else { return nil }
        if url.lastPathComponent != "manifest.json" { url.appendPathComponent("manifest.json") }
        return url
    }

    private static func httpsURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host() != nil,
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private func clean(_ value: String?, limit: Int = 70) -> String? {
        guard let value else { return nil }
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    private struct ProviderResult: Sendable {
        var streams: [AddonStream] = []
        var unsupported = 0
        var failed = false
    }

    private struct StreamIdentity: Hashable {
        let destination: AddonStream.Destination
        let requestHeaders: [String: String]
    }

    private struct Manifest: Decodable {
        let name: String?
        let resources: [Resource]
        let types: [String]
        let idPrefixes: [String]?

        func supports(kind: CinemetaKind, id: String, resourceName: String = "stream") -> Bool {
            resources.contains { resource in
                guard resource.name == resourceName else { return false }
                let types = resource.isNamed ? self.types : resource.types ?? self.types
                let prefixes = resource.isNamed ? idPrefixes : resource.idPrefixes
                return types.contains(kind.rawValue) && (prefixes?.contains { id.hasPrefix($0) } ?? true)
            }
        }
    }

    private struct Resource: Decodable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        let isNamed: Bool

        private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

        init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
                types = nil
                idPrefixes = nil
                isNamed = true
            } else {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                name = try fields.decode(String.self, forKey: .name)
                types = try fields.decodeIfPresent([String].self, forKey: .types)
                idPrefixes = try fields.decodeIfPresent([String].self, forKey: .idPrefixes)
                isNamed = false
            }
        }
    }

    private struct Streams: Decodable {
        private let entries: [Entry<Stream>]
        var streams: [Stream] { entries.compactMap(\.value) }
        var entriesCount: Int { entries.count }

        enum CodingKeys: String, CodingKey { case entries = "streams" }
    }

    private struct Subtitles: Decodable {
        let subtitles: [Entry<AddonSubtitle>]?
        var tracks: [AddonSubtitle] { subtitles?.compactMap(\.value) ?? [] }
    }

    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Stream: Decodable {
        let name: String?
        let title: String?
        let description: String?
        let url: String?
        let externalUrl: String?
        let subtitles: [Entry<AddonSubtitle>]?
        let behaviorHints: BehaviorHints?

        struct BehaviorHints: Decodable {
            let filename: String?
            let videoHash: String?
            let videoSize: Int64?
            let notWebReady: Bool?
            let proxyHeaders: Headers?

            private enum CodingKeys: String, CodingKey { case filename, videoHash, videoSize, notWebReady, proxyHeaders }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                filename = try? fields.decode(String.self, forKey: .filename)
                videoHash = try? fields.decode(String.self, forKey: .videoHash)
                if let bytes = try? fields.decode(Int64.self, forKey: .videoSize) {
                    videoSize = bytes
                } else {
                    videoSize = (try? fields.decode(String.self, forKey: .videoSize)).flatMap(Int64.init)
                }
                notWebReady = try? fields.decode(Bool.self, forKey: .notWebReady)
                proxyHeaders = try fields.decodeIfPresent(Headers.self, forKey: .proxyHeaders)
            }
        }

        struct Headers: Decodable {
            let request: [String: String]?
            let response: [String: String]?

            private static let supported: Set<String> = ["accept", "accept-language", "origin", "referer", "user-agent"]

            var supportedRequest: [String: String]? {
                guard response?.isEmpty != false else { return nil }
                var result: [String: String] = [:]
                for (name, rawValue) in request ?? [:] {
                    let key = name.lowercased()
                    let value = rawValue.trimmingCharacters(in: .whitespaces)
                    guard Self.supported.contains(key), result[key] == nil, !value.isEmpty,
                          value.utf8.count <= 1_024,
                          rawValue.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
                    // AVFoundation can replay HLS headers on other hosts, including redirects.
                    if key == "origin" || key == "referer" {
                        guard let components = URLComponents(string: value), let url = components.url,
                              AddonStreams.httpsURL(url) != nil, components.query == nil,
                              components.fragment == nil, components.path.isEmpty || components.path == "/" else {
                            return nil
                        }
                    }
                    result[key] = value
                }
                return result
            }
        }

        var playbackSource: (AddonStream.Destination, [String: String])? {
            if let url = url.flatMap(URL.init(string:)).flatMap(AddonStreams.httpsURL) {
                if let headers = behaviorHints?.proxyHeaders {
                    if let request = headers.supportedRequest { return (.video(url), request) }
                } else {
                    return (.video(url), [:])
                }
            }
            if let url = externalUrl.flatMap(URL.init(string:)).flatMap(AddonStreams.httpsURL) {
                return (.external(url), [:])
            }
            return nil
        }

        func focusKeys(providerID: String, destination: AddonStream.Destination, headers: [String: String],
                       name: String?, description: String?) -> [AddonStream.FocusKey] {
            let (type, url): (String, URL)
            switch destination {
            case let .video(value): (type, url) = ("video", value)
            case let .external(value): (type, url) = ("external", value)
            }

            func key(_ field: String, _ parts: [String]) -> AddonStream.FocusKey {
                let value = ([providerID, type, field] + parts).map { "\($0.utf8.count):\($0)" }.joined()
                return SHA256.hash(data: Data(value.utf8))
            }

            let headerParts = headers.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
            var keys = [key("exact", [url.absoluteString] + headerParts)]
            if let hash = behaviorHints?.videoHash, !hash.isEmpty {
                keys.append(key("hash", [hash.lowercased()]))
            }
            if let filename = behaviorHints?.filename, !filename.isEmpty {
                let size = behaviorHints?.videoSize.map(String.init) ?? ""
                keys.append(key("file", [filename, size]))
            }

            // A fresh signed URL may change its query or its entire path.
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.percentEncodedQuery = nil
                components.percentEncodedFragment = nil
                if let address = components.string { keys.append(key("address", [address] + headerParts)) }
            }
            if let description {
                keys.append(key("label", [name ?? "", description]))
            }
            return keys
        }
    }
}

private final class AddonRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host() == task.originalRequest?.url?.host()
            && url?.user() == nil && url?.password() == nil
        completionHandler(allowed ? request : nil)
    }
}
