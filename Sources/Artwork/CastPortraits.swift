import Foundation

struct CastPortrait: Sendable {
    let url: URL
    let attribution: String
    let sourceURL: URL
    let licenseURL: URL?
}

actor CastPortraits {
    static let shared = CastPortraits()

    private var cache: [String: CastPortrait] = [:]

    func load(for names: [String]) async -> [String: CastPortrait] {
        var results: [String: CastPortrait] = [:]
        var pending: [String] = []
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            if let portrait = cache[name] {
                results[name] = portrait
            } else if !name.contains("|"), !Self.normalizedName(name).isEmpty {
                pending.append(name)
            }
        }

        // MediaWiki accepts up to 50 titles per request.
        for start in stride(from: 0, to: pending.count, by: 50) {
            guard !Task.isCancelled else { break }
            let end = min(start + 50, pending.count)
            let files = await Self.findFiles(for: pending[start..<end])

            guard !Task.isCancelled else { break }
            let portraits = await Self.loadCredits(for: Set(files.values))
            for (name, file) in files {
                if let portrait = portraits[Self.fileKey(file)] {
                    cache[name] = portrait
                    results[name] = portrait
                }
            }
        }
        return results
    }

    private static func findFiles(for names: ArraySlice<String>) async -> [String: String] {
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
        guard let response: WikipediaResponse = await fetch(endpoint.appending(queryItems: query)) else { return [:] }

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
        return files
    }

    private static func loadCredits(for files: Set<String>) async -> [String: CastPortrait] {
        guard !files.isEmpty else { return [:] }
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
        guard let response: CommonsResponse = await fetch(endpoint.appending(queryItems: query)) else { return [:] }

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
        return portraits
    }

    private static func fetch<Value: Decodable>(_ url: URL) async -> Value? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("NuvioCinema/0.1 (Apple TV cast artwork)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            return nil
        }
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

    private struct WikipediaResponse: Decodable {
        let query: Query

        struct Query: Decodable {
            let pages: [Page]
        }

        struct Page: Decodable {
            let title: String
            let terms: Terms?
            let thumbnail: Thumbnail?
            let pageimage: String?
        }

        struct Terms: Decodable {
            let description: [String]?
        }

        struct Thumbnail: Decodable {
            let source: URL
        }
    }

    private struct CommonsResponse: Decodable {
        let query: Query

        struct Query: Decodable {
            let pages: [Page]
        }

        struct Page: Decodable {
            let title: String
            let imageinfo: [ImageInfo]?
        }

        struct ImageInfo: Decodable {
            let thumburl: URL?
            let descriptionurl: URL?
            let extmetadata: [String: Metadata]?
        }

        struct Metadata: Decodable {
            let value: String
        }
    }
}
