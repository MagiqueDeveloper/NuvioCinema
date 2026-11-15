import Foundation

struct CastPortrait: Sendable {
    let url: URL
    let attribution: String
    let sourceURL: URL
    let licenseURL: URL?
}

actor CastPortraits {
    static let shared = CastPortraits()

    private final class CachedPortrait {
        let value: CastPortrait
        let expiresAt: Date

        init(_ value: CastPortrait, expiresAt: Date) {
            self.value = value
            self.expiresAt = expiresAt
        }
    }

    private let cache = NSCache<NSString, CachedPortrait>()

    init() {
        cache.countLimit = 256
    }

    func load(for names: [String]) async -> [String: CastPortrait] {
        var results: [String: CastPortrait] = [:]
        var pending: [String] = []
        for name in Set(names).sorted() where !name.contains("|") && !Self.normalizedName(name).isEmpty {
            if let cached = cache.object(forKey: name as NSString), cached.expiresAt > .now {
                results[name] = cached.value
            } else {
                pending.append(name)
            }
        }

        // MediaWiki accepts up to 50 titles per request.
        for start in stride(from: 0, to: pending.count, by: 50) {
            guard !Task.isCancelled else { break }
            let end = min(start + 50, pending.count)
            let (files, filesExpiry) = await Self.findFiles(for: pending[start..<end])

            guard !Task.isCancelled else { break }
            let (portraits, creditsExpiry) = await Self.loadCredits(for: Set(files.values))
            let now = Date.now
            let expiresAt = min(filesExpiry ?? now, creditsExpiry ?? now, now.addingTimeInterval(3600))
            for (name, file) in files {
                if let portrait = portraits[Self.fileKey(file)] {
                    if expiresAt > now {
                        cache.setObject(CachedPortrait(portrait, expiresAt: expiresAt), forKey: name as NSString)
                    }
                    results[name] = portrait
                }
            }
        }
        return results
    }

    private static func findFiles(for names: ArraySlice<String>) async -> ([String: String], Date?) {
        let endpoint = URL(string: "https://en.wikipedia.org/w/api.php")!
        let query = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "prop", value: "pageimages|pageterms"),
            URLQueryItem(name: "titles", value: names.joined(separator: "|")),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "piprop", value: "thumbnail|name"),
            URLQueryItem(name: "pithumbsize", value: "120"),
            URLQueryItem(name: "pilicense", value: "free"),
            URLQueryItem(name: "wbptterms", value: "description")
        ]
        guard let (response, freshUntil) = await fetch(WikipediaPage.self, from: endpoint.appending(queryItems: query))
        else { return ([:], nil) }

        let creditOccupations: Set<String> = [
            "actor", "actress", "director", "screenwriter", "filmmaker", "playwright",
            "producer", "composer", "cinematographer", "editor", "writer",
        ]
        let people = response.query.pages.filter { page in
            let occupations = (page.terms?.description ?? []).joined(separator: " ").lowercased().split { !$0.isLetter }
            return occupations.contains { creditOccupations.contains(String($0)) }
        }
        let matches = Dictionary(grouping: people) { page in
            let title = page.title.replacingOccurrences(of: #"\s+\([^()]+\)$"#, with: "", options: .regularExpression)
            return normalizedName(title)
        }

        var files: [String: String] = [:]
        for name in names {
            guard let candidates = matches[normalizedName(name)], candidates.count == 1,
                  let page = candidates.first, let file = page.pageimage, !file.contains("|"),
                  let url = page.thumbnail?.source, isCommonsArtwork(url) else { continue }
            files[name] = "File:\(file)"
        }
        return (files, freshUntil)
    }

    private static func loadCredits(for files: Set<String>) async -> ([String: CastPortrait], Date?) {
        guard !files.isEmpty else { return ([:], nil) }
        let endpoint = URL(string: "https://commons.wikimedia.org/w/api.php")!
        let query = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "titles", value: files.sorted().joined(separator: "|")),
            URLQueryItem(name: "iiprop", value: "url|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "360"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseShortName|LicenseUrl|Attribution")
        ]
        guard let (response, freshUntil) = await fetch(CommonsPage.self, from: endpoint.appending(queryItems: query))
        else { return ([:], nil) }

        var portraits: [String: CastPortrait] = [:]
        for page in response.query.pages {
            guard let image = page.imageinfo?.first,
                  let url = image.thumburl, isCommonsArtwork(url),
                  let sourceURL = image.descriptionurl, sourceURL.scheme == "https",
                  sourceURL.host() == "commons.wikimedia.org",
                  let license = creditText(image.extmetadata?["LicenseShortName"]?.value) else { continue }

            let author = creditText(image.extmetadata?["Attribution"]?.value)
                ?? creditText(image.extmetadata?["Artist"]?.value)
            guard let author else { continue }
            let licenseURL = image.extmetadata?["LicenseUrl"].flatMap { URL(string: $0.value) }
            portraits[fileKey(page.title)] = CastPortrait(
                url: url,
                attribution: "\(author) · \(license)",
                sourceURL: sourceURL,
                licenseURL: licenseURL?.scheme == "https" ? licenseURL : nil
            )
        }
        return (portraits, freshUntil)
    }

    private static func fetch<Page: Decodable & Sendable>(
        _: Page.Type, from url: URL
    ) async -> (value: MediaWikiResponse<Page>, freshUntil: Date?)? {
        let url = url.appending(queryItems: [
            URLQueryItem(name: "maxage", value: "3600"),
            URLQueryItem(name: "smaxage", value: "3600"),
        ])
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("NuvioCinema/0.1 (https://github.com/MagiqueDeveloper/NuvioCinema)", forHTTPHeaderField: "User-Agent")
        return await CinemaMetadataCache.shared.loadWithFreshness(
            MediaWikiResponse<Page>.self, request: request, policy: .reference, canStore: { $0.isComplete }
        )
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func fileKey(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").precomposedStringWithCanonicalMapping
    }

    private static func isCommonsArtwork(_ url: URL) -> Bool {
        let hosts = ["upload.wikimedia.org", "thumb.wikimedia.org"]
        return url.scheme == "https" && url.host().map(hosts.contains) == true && url.path.hasPrefix("/wikipedia/commons/")
    }

    private static func creditText(_ value: String?) -> String? {
        guard let value else { return nil }
        var plainText = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            plainText = plainText.replacingOccurrences(of: entity, with: character)
        }
        let credit = plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return credit.isEmpty ? nil : credit
    }

    private struct MediaWikiResponse<Page: Decodable & Sendable>: Decodable, Sendable {
        let query: Query
        let isComplete: Bool

        private enum CodingKeys: String, CodingKey { case query, `continue`, warnings }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            query = try fields.decode(Query.self, forKey: .query)
            isComplete = !fields.contains(.`continue`) && !fields.contains(.warnings)
        }

        struct Query: Decodable, Sendable {
            let pages: [Page]
        }
    }

    private struct WikipediaPage: Decodable, Sendable {
        let title: String
        let terms: Terms?
        let thumbnail: Thumbnail?
        let pageimage: String?

        struct Terms: Decodable, Sendable {
            let description: [String]?
        }

        struct Thumbnail: Decodable, Sendable {
            let source: URL
        }
    }

    private struct CommonsPage: Decodable, Sendable {
        let title: String
        let imageinfo: [ImageInfo]?

        struct ImageInfo: Decodable, Sendable {
            let thumburl: URL?
            let descriptionurl: URL?
            let extmetadata: [String: Metadata]?
        }

        struct Metadata: Decodable, Sendable {
            let value: String
        }
    }
}
