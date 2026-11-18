import Foundation

enum CinemetaKind: String, CaseIterable, Identifiable, Sendable {
    case movie, series

    var id: Self { self }
}

struct CinemetaTitle: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    private let metadataType: String?
    let description: String?
    let releaseInfo: String?
    let imdbID: String?
    let tmdbID: String?
    let poster: URL?
    let background: URL?
    let logo: URL?
    let genres: [String]?
    let runtime: String?
    let imdbRating: Double?
    let released: Date?
    let contentRating: String?
    let countries: [String]
    let languages: [String]
    let status: String?
    let awards: String?
    let episodes: [CinemetaEpisode]
    let cast: [String]
    let directors: [String]
    let writers: [String]
    let trailers: [CinemaTrailer]

    private enum CodingKeys: String, CodingKey {
        case id, name, type, description, releaseInfo, poster, background, logo, genres, runtime
        case imdbID = "imdb_id"
        case tmdbID = "tmdb_id"
        case alternateTMDBID = "tmdbId"
        case imdbRating
        case released, contentRating, certification, ratings, country, countries, language, languages, status, awards
        case videos
        case cast, director, writer, links, trailers, trailerStreams
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        metadataType = try? fields.decode(String.self, forKey: .type)
        description = Self.text(in: fields, key: .description)
        releaseInfo = Self.text(in: fields, key: .releaseInfo)
        let providedIMDbID = try? fields.decode(String.self, forKey: .imdbID)
        let links = (try? fields.decode([CreditLink].self, forKey: .links)) ?? []
        imdbID = Self.validIMDbID(id) ?? Self.validIMDbID(providedIMDbID) ?? links.compactMap(\.imdbID).first
        tmdbID = Self.validTMDBID(id, requiresPrefix: true) ?? [CodingKeys.tmdbID, .alternateTMDBID].lazy.compactMap { key in
            let value = (try? fields.decode(String.self, forKey: key))
                ?? (try? fields.decode(Int.self, forKey: key)).map(String.init)
            return Self.validTMDBID(value)
        }.first
        poster = Self.artworkURL(try? fields.decode(String.self, forKey: .poster))
        background = Self.artworkURL(try? fields.decode(String.self, forKey: .background))
        logo = Self.artworkURL(try? fields.decode(String.self, forKey: .logo))
        genres = try? fields.decode([String].self, forKey: .genres)
        runtime = Self.text(in: fields, key: .runtime)
        let score = (try? fields.decode(Double.self, forKey: .imdbRating))
            ?? (try? fields.decode(String.self, forKey: .imdbRating)).flatMap(Double.init)
        imdbRating = score.flatMap { (1...10).contains($0) ? $0 : nil }
        released = Self.text(in: fields, key: .released).flatMap { value in
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value))
        }
        let ratings = (try? fields.decode([ContentRatingEntry].self, forKey: .ratings)) ?? []
        contentRating = Self.text(in: fields, key: .contentRating) ?? Self.text(in: fields, key: .certification)
            ?? ratings.compactMap(\.value).first
        countries = Self.names(in: fields, keys: [.country, .countries])
        languages = Self.names(in: fields, keys: [.language, .languages])
        status = Self.text(in: fields, key: .status)
        awards = Self.text(in: fields, key: .awards)
        let videos = (try? fields.decode([EpisodeEntry].self, forKey: .videos)) ?? []
        var seenEpisodes = Set<String>()
        episodes = videos.compactMap(\.episode).filter { seenEpisodes.insert($0.id).inserted }

        cast = Self.credits(in: fields, key: .cast, categories: ["cast", "actor"], links: links)
        directors = Self.credits(in: fields, key: .director, categories: ["director", "directors"], links: links)
        writers = Self.credits(in: fields, key: .writer, categories: ["writer", "writers"], links: links)

        let streams = (try? fields.decode([TrailerEntry].self, forKey: .trailerStreams)) ?? []
        let legacyTrailers = (try? fields.decode([TrailerEntry].self, forKey: .trailers)) ?? []
        var seenTrailers = Set<String>()
        trailers = (streams + legacyTrailers).compactMap(\.trailer).filter { seenTrailers.insert($0.id).inserted }
    }

    var displayReleaseInfo: String? {
        guard let release = releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !release.isEmpty else { return nil }
        if let last = release.last, "-–—".contains(last) {
            let year = release.dropLast().trimmingCharacters(in: .whitespaces)
            if year.utf8.count == 4, year.utf8.allSatisfy({ (48...57).contains($0) }) {
                return String(localized: "Since \(year)")
            }
        }
        return release
    }

    var releaseYear: String? {
        guard let release = releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let digits = release.utf8.prefix { (48...57).contains($0) }
        guard digits.count == 4 else { return nil }
        return String(decoding: digits, as: UTF8.self)
    }

    private static func validIMDbID(_ imdbID: String?) -> String? {
        guard let imdbID, imdbID.hasPrefix("tt") else { return nil }
        let digits = imdbID.utf8.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return imdbID
    }

    private static func validTMDBID(_ value: String?, requiresPrefix: Bool = false) -> String? {
        guard let value else { return nil }
        let hasPrefix = value.hasPrefix("tmdb:")
        guard !requiresPrefix || hasPrefix else { return nil }
        let digits = hasPrefix ? value.utf8.dropFirst(5) : value.utf8.dropFirst(0)
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let significant = digits.drop(while: { $0 == 48 })
        guard !significant.isEmpty else { return nil }
        return "tmdb:" + String(decoding: significant, as: UTF8.self)
    }

    func matchesDetails(for contentID: String, kind: CinemetaKind) -> Bool {
        guard metadataType == nil || metadataType == kind.rawValue else { return false }
        if let requestedTMDB = Self.validTMDBID(contentID, requiresPrefix: true) {
            return tmdbID == requestedTMDB
        }
        return imdbID == contentID
    }

    fileprivate static func artworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host() != nil,
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private static func text(in fields: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        (try? fields.decode(String.self, forKey: key)).flatMap(cleanText)
    }

    private static func cleanText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("N/A") == .orderedSame ? nil : trimmed
    }

    private static func names(in fields: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> [String] {
        let values = keys.flatMap { key in
            (try? fields.decode([String].self, forKey: key))
                ?? text(in: fields, key: key)?.components(separatedBy: ",") ?? []
        }
        var seen = Set<String>()
        return values.compactMap(cleanText).filter { seen.insert($0).inserted }
    }

    private struct ContentRatingEntry: Decodable {
        let value: String?

        private enum CodingKeys: String, CodingKey { case value }

        init(from decoder: any Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            value = (try? fields?.decode(String.self, forKey: .value)).flatMap(CinemetaTitle.cleanText)
        }
    }

    private static func credits(
        in fields: KeyedDecodingContainer<CodingKeys>, key: CodingKeys, categories: Set<String>, links: [CreditLink]
    ) -> [String] {
        let names = (try? fields.decode([String].self, forKey: key)) ?? []
        let linkedNames = links.compactMap { link in
            guard let category = link.category?.lowercased(), categories.contains(category) else { return nil as String? }
            return link.name
        }
        var seen = Set<String>()
        return (names + linkedNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private struct CreditLink: Decodable {
        let name: String?
        let category: String?
        let url: String?

        private enum CodingKeys: String, CodingKey { case name, category, url }

        init(from decoder: any Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            name = try? fields?.decode(String.self, forKey: .name)
            category = try? fields?.decode(String.self, forKey: .category)
            url = try? fields?.decode(String.self, forKey: .url)
        }

        var imdbID: String? {
            guard category?.lowercased() == "imdb", let url = CinemetaTitle.artworkURL(url),
                  let host = url.host(), ["imdb.com", "www.imdb.com"].contains(host),
                  url.pathComponents.count == 3, url.pathComponents[1] == "title" else { return nil }
            return CinemetaTitle.validIMDbID(url.lastPathComponent)
        }
    }

    private struct TrailerEntry: Decodable {
        let trailer: CinemaTrailer?

        private enum CodingKeys: String, CodingKey { case ytId, source, title }

        init(from decoder: any Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            let title = try? fields?.decode(String.self, forKey: .title)
            let videoID = try? fields?.decode(String.self, forKey: .ytId)
            let legacyID = try? fields?.decode(String.self, forKey: .source)
            trailer = videoID.flatMap { CinemaTrailer(id: $0, title: title) }
                ?? legacyID.flatMap { CinemaTrailer(id: $0, title: title) }
        }
    }

    private struct EpisodeEntry: Decodable {
        let episode: CinemetaEpisode?

        init(from decoder: any Decoder) throws {
            episode = try? CinemetaEpisode(from: decoder)
        }
    }
}

struct CinemaTrailer: Identifiable, Sendable {
    let id: String
    let title: String?
    let youtubeURL: URL

    fileprivate init?(id: String, title: String?) {
        guard id.utf8.count == 11, id.utf8.allSatisfy(Self.isYouTubeIDCharacter),
              let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return nil }
        self.id = id
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle?.isEmpty == false ? trimmedTitle : nil
        youtubeURL = url
    }

    private static func isYouTubeIDCharacter(_ character: UInt8) -> Bool {
        switch character {
        case 45, 48...57, 65...90, 95, 97...122: true
        default: false
        }
    }
}

struct CinemetaEpisode: Decodable, Identifiable, Sendable {
    let id: String
    let season: Int
    let episode: Int
    let name: String
    let overview: String?
    let thumbnail: URL?
    let releasedAt: Date?

    func isUpcoming(at date: Date = .now) -> Bool {
        releasedAt.map { $0 > date } ?? false
    }

    static func displayAirDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    private enum CodingKeys: String, CodingKey {
        case id, season, episode, number, name, title, overview, description, thumbnail, released
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        season = try fields.decode(Int.self, forKey: .season)
        episode = try fields.decodeIfPresent(Int.self, forKey: .episode) ?? fields.decode(Int.self, forKey: .number)
        name = Self.firstNonemptyText(in: fields, keys: [.name, .title]) ?? String(localized: "Episode \(episode)")
        overview = Self.firstNonemptyText(in: fields, keys: [.overview, .description])
        thumbnail = CinemetaTitle.artworkURL(try? fields.decode(String.self, forKey: .thumbnail))
        releasedAt = (try? fields.decode(String.self, forKey: .released)).flatMap { value in
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value))
                ?? (try? Date.ISO8601FormatStyle().year().month().day().parse(value))
        }
    }

    private static func firstNonemptyText(in fields: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> String? {
        for key in keys {
            if let text = try? fields.decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

struct CinemetaCatalog: Sendable {
    let movies: [CinemetaTitle]?
    let series: [CinemetaTitle]?

    subscript(kind: CinemetaKind) -> [CinemetaTitle] {
        (kind == .movie ? movies : series) ?? []
    }

    var hasFailure: Bool { movies == nil || series == nil }

    func rankedResults(for query: String) -> [CinemetaSearchResult] {
        let queryWords = Self.searchWords(in: query)
        guard !queryWords.isEmpty else { return [] }
        let queryPhrase = queryWords.joined(separator: " ")

        let ranked = CinemetaKind.allCases.flatMap { kind in
            self[kind].enumerated().map { position, title in
                let words = Self.searchWords(in: title.name)
                let phrase = words.joined(separator: " ")
                let relevance: Int

                if phrase == queryPhrase {
                    relevance = 0
                } else if phrase.hasPrefix(queryPhrase + " ") {
                    relevance = 1
                } else if (" " + phrase + " ").contains(" " + queryPhrase + " ") {
                    relevance = 2
                } else if queryWords.allSatisfy({ words.contains($0) }) {
                    relevance = 3
                } else if phrase.hasPrefix(queryPhrase) {
                    relevance = 4
                } else if queryWords.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) {
                    relevance = 5
                } else {
                    relevance = 6
                }

                return (result: CinemetaSearchResult(title: title, kind: kind), relevance: relevance, position: position)
            }
        }

        // Interleave equally relevant matches by their original Cinemeta positions.
        return ranked.sorted { ($0.relevance, $0.position) < ($1.relevance, $1.position) }.map(\.result)
    }

    private static func searchWords(in text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
    }
}

struct CinemetaSearchResult: Identifiable, Sendable {
    let title: CinemetaTitle
    let kind: CinemetaKind

    var id: String { "\(kind.rawValue):\(title.id)" }
    fileprivate var catalogID: String { title.imdbID ?? id }

    private var nameKey: String {
        title.name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func disambiguatedNames(for results: [Self]) -> [ID: String] {
        let byName = Dictionary(grouping: results, by: \.nameKey)
        var names: [ID: String] = [:]
        for group in byName.values where group.count > 1 {
            for result in group {
                if let year = result.title.releaseYear {
                    names[result.id] = String(localized: "\(result.title.name) (\(year))")
                }
            }
        }
        return names
    }
}

struct HomeCatalog: Sendable {
    let rows: [HomeCollection]
    let featuredEntries: [CinemetaSearchResult]
    let collections: [HomeCollection]
    let genrePreviews: [HomeGenre: [CinemetaSearchResult]]
    let isComplete: Bool
    let shelfOrder: [HomeCollection.ID]
    private let rowOrder: [HomeCollection.ID]

    var hasFailure: Bool { rows.contains(where: \.hasFailure) }
    var isEmpty: Bool { collections.isEmpty && featuredEntries.isEmpty }

    init(rows: [HomeCollection], featuredEntries: [CinemetaSearchResult],
         rowOrder: [HomeCollection.ID], isComplete: Bool) {
        self.rows = rows
        self.featuredEntries = featuredEntries
        self.rowOrder = rowOrder
        self.isComplete = isComplete

        // Allocate chart and release titles first so broader rows can fill from deeper in their feeds.
        var used = Set(featuredEntries.map(\.catalogID))
        var selection: [HomeCollection.ID: HomeCollection] = [:]
        for row in rows.sorted(by: { $0.id.selectionPriority < $1.id.selectionPriority }) {
            let entries = row.isRanked
                ? row.entries
                : Array(row.entries.lazy.filter { !used.contains($0.catalogID) }.prefix(row.id.entryLimit))
            if !entries.isEmpty {
                used.formUnion(entries.map(\.catalogID))
                selection[row.id] = HomeCollection(id: row.id, entries: entries, hasFailure: row.hasFailure)
            }
        }
        collections = rows.compactMap { selection[$0.id] }
        shelfOrder = Self.withGenreBrowser(rowOrder).filter { selection[$0] != nil || ($0 == .genres && !selection.isEmpty) }
        genrePreviews = Self.makeGenrePreviews(rows: rows, visibleRows: collections)
    }

    func preservingAvailableCollections(from previous: Self?) -> Self {
        guard (!isComplete || hasFailure), let previous else { return self }
        let currentRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let previousRows = Dictionary(uniqueKeysWithValues: previous.rows.map { ($0.id, $0) })
        let rows = rowOrder.compactMap { id -> HomeCollection? in
            guard let row = currentRows[id] else { return isComplete ? nil : previousRows[id] }
            guard row.hasFailure, row.entries.isEmpty, let cached = previousRows[id] else { return row }
            return HomeCollection(id: id, entries: cached.entries, hasFailure: true)
        }
        let featured = featuredEntries.isEmpty ? previous.featuredEntries : featuredEntries
        return HomeCatalog(rows: rows, featuredEntries: featured, rowOrder: rowOrder, isComplete: isComplete)
    }

    func preservingFocus(on shelf: HomeCollection.ID, entryID: String, from previous: Self) -> Self? {
        guard let previousIndex = previous.shelfOrder.firstIndex(of: shelf) else { return nil }
        let prefix = Array(previous.shelfOrder.prefix(through: previousIndex))
        let scheduled = Self.withGenreBrowser(rowOrder)
        let suffix = if let index = shelfOrder.firstIndex(of: shelf) {
            Array(shelfOrder.suffix(from: index + 1))
        } else if let index = scheduled.firstIndex(of: shelf) {
            Array(scheduled.suffix(from: index + 1)).filter { shelfOrder.contains($0) }
        } else {
            shelfOrder.filter { previous.shelfOrder.suffix(from: previousIndex + 1).contains($0) }
        }
        let preservedOrder = prefix + suffix.filter { !prefix.contains($0) }
        let updated = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let former = Dictionary(uniqueKeysWithValues: previous.collections.map { ($0.id, $0) })
        var preservedEntries = false
        let preservedCollections = preservedOrder.compactMap { id -> HomeCollection? in
            guard id == shelf, let row = former[id] else { return updated[id] ?? former[id] }
            let entries = updated[id]?.entries ?? []
            guard let index = row.entries.firstIndex(where: { $0.id == entryID }),
                  entries.firstIndex(where: { $0.id == entryID }) != index else { return updated[id] ?? row }
            preservedEntries = true
            let prefix = row.entries.prefix(through: index)
            let replacements = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            let heldIDs = Set(prefix.map(\.id))
            return HomeCollection(id: id, entries: prefix.map { replacements[$0.id] ?? $0 }
                + entries.filter { !heldIDs.contains($0.id) }, hasFailure: updated[id]?.hasFailure ?? row.hasFailure)
        }
        guard preservedOrder != shelfOrder || preservedEntries else { return nil }
        return HomeCatalog(base: self, collections: preservedCollections, shelfOrder: preservedOrder)
    }

    private init(base: Self, collections: [HomeCollection], shelfOrder: [HomeCollection.ID]) {
        rows = base.rows
        rowOrder = base.rowOrder
        isComplete = base.isComplete
        featuredEntries = base.featuredEntries
        self.collections = collections
        self.shelfOrder = shelfOrder
        genrePreviews = Self.makeGenrePreviews(rows: rows, visibleRows: collections)
    }

    private static func withGenreBrowser(_ rowOrder: [HomeCollection.ID]) -> [HomeCollection.ID] {
        var order = rowOrder
        order.insert(.genres, at: min(3, order.count))
        return order
    }

    private static func makeGenrePreviews(
        rows: [HomeCollection], visibleRows: [HomeCollection]
    ) -> [HomeGenre: [CinemetaSearchResult]] {
        let editorial = visibleRows.compactMap { row -> HomeGenre? in
            if case .genre(let genre) = row.id { return genre }
            return nil
        }
        let genres = editorial + HomeGenre.allCases.filter { !editorial.contains($0) }
        let candidates = visibleRows.flatMap(\.entries) + rows.flatMap(\.entries)
        var featuredBackdrops = Set<URL>()
        var previews: [HomeGenre: [CinemetaSearchResult]] = [:]

        for genre in genres {
            let curated = visibleRows.first(where: { $0.id == .genre(genre) })?.entries ?? []
            let matching = candidates.filter { genre.matches($0.title.genres) }
            var ids = Set<String>()
            var entries = (curated + matching).filter { ids.insert($0.catalogID).inserted }
            if let index = entries.firstIndex(where: { entry in
                entry.title.background.map { !featuredBackdrops.contains($0) } ?? false
            }) {
                let cover = entries.remove(at: index)
                entries.insert(cover, at: 0)
                if let url = cover.title.background { featuredBackdrops.insert(url) }
            }
            previews[genre] = Array(entries.prefix(8))
        }
        return previews
    }
}

struct HomeCollection: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case continueWatching, watching, today, newReleases, newSeries, topRated
        case genres, genre(HomeGenre), popularMovies, popularSeries

        var title: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .watching: String(localized: "What We’re Watching")
            case .today: String(localized: "Popular Today")
            case .newReleases: String(localized: "New Movies")
            case .newSeries: String(localized: "New TV Shows")
            case .topRated: String(localized: "Top Rated")
            case .genres: String(localized: "Browse by Genre")
            case .genre(let genre): genre.title
            case .popularMovies: String(localized: "Popular Movies")
            case .popularSeries: String(localized: "Popular TV Shows")
            }
        }

        fileprivate var selectionPriority: Int {
            switch self {
            case .today: 0
            case .newReleases, .newSeries: 1
            case .topRated: 2
            case .watching: 3
            case .genre: 4
            case .popularMovies, .popularSeries: 5
            case .genres, .continueWatching: 6
            }
        }

        fileprivate var entryLimit: Int {
            switch self {
            case .newReleases, .newSeries: 14
            default: 16
            }
        }
    }

    let id: ID
    let entries: [CinemetaSearchResult]
    let hasFailure: Bool

    var isRanked: Bool { id == .today }
}

enum HomeGenre: String, CaseIterable, Sendable {
    case action = "Action"
    case adventure = "Adventure"
    case animation = "Animation"
    case comedy = "Comedy"
    case crime = "Crime"
    case documentary = "Documentary"
    case drama = "Drama"
    case family = "Family"
    case fantasy = "Fantasy"
    case horror = "Horror"
    case mystery = "Mystery"
    case romance = "Romance"
    case scienceFiction = "Sci-Fi"
    case thriller = "Thriller"

    var name: String {
        switch self {
        case .action: String(localized: "Action")
        case .adventure: String(localized: "Adventure")
        case .animation: String(localized: "Animation")
        case .comedy: String(localized: "Comedy")
        case .crime: String(localized: "Crime")
        case .documentary: String(localized: "Documentary")
        case .drama: String(localized: "Drama")
        case .family: String(localized: "Family")
        case .fantasy: String(localized: "Fantasy")
        case .horror: String(localized: "Horror")
        case .mystery: String(localized: "Mystery")
        case .romance: String(localized: "Romance")
        case .scienceFiction: String(localized: "Science Fiction")
        case .thriller: String(localized: "Thriller")
        }
    }

    var title: String {
        switch self {
        case .comedy: String(localized: "Comedy Night")
        case .crime: String(localized: "Crime Stories")
        case .documentary: String(localized: "Documentaries")
        case .family: String(localized: "Family Time")
        default: name
        }
    }

    fileprivate func matches(_ genres: [String]?) -> Bool {
        genres?.contains { value in
            value.caseInsensitiveCompare(rawValue) == .orderedSame
                || (self == .scienceFiction && value.caseInsensitiveCompare("Science Fiction") == .orderedSame)
        } ?? false
    }

    static func rotation(on date: Date) -> [Self] {
        let week = Int(floor(date.timeIntervalSince1970 / (7 * 86_400)))
        let lineup: [Self] = [
            .action, .comedy, .documentary, .horror,
            .romance, .scienceFiction, .crime, .animation,
            .fantasy, .drama, .family, .thriller, .adventure, .mystery
        ]
        let count = lineup.count
        let first = (week % count + count) % count
        return (0..<4).map { lineup[(first + $0) % count] }
    }
}

struct CinemetaClient: Sendable {
    private static let searchSession = URLSession(configuration: .ephemeral)

    private let session: URLSession
    private let cache: CinemaMetadataCache?

    init(session: URLSession = .shared, cache: CinemaMetadataCache? = nil) {
        self.session = session
        self.cache = cache ?? (session === URLSession.shared ? .shared : nil)
    }

    func load(query: String? = nil) async -> CinemetaCatalog {
        let filter = query.map { ("search", $0) }
        async let movies = catalog(kind: .movie, filter: filter)
        async let series = catalog(kind: .series, filter: filter)
        return await CinemetaCatalog(movies: movies, series: series)
    }

    func retrySearch(query: String, retaining previous: CinemetaCatalog) async -> CinemetaCatalog {
        let filter = ("search", query)
        async let movies = previous.movies == nil ? catalog(kind: .movie, filter: filter) : previous.movies
        async let series = previous.series == nil ? catalog(kind: .series, filter: filter) : previous.series
        return await CinemetaCatalog(movies: movies, series: series)
    }

    private enum HomeFeed: Hashable, Sendable {
        case popular, favorites, watching, today, releases, genre(HomeGenre)
    }

    private struct HomeFeedResponse: Sendable {
        let feed: HomeFeed
        let kind: CinemetaKind
        let titles: [CinemetaTitle]?
    }

    func loadHome(on date: Date = .now, onProgress: @MainActor (HomeCatalog) -> Void) async -> HomeCatalog {
        let genres = HomeGenre.rotation(on: date)
        let feeds: [HomeFeed] = [.popular, .favorites, .watching, .today, .releases] + genres.map(HomeFeed.genre)
        return await withTaskGroup(of: HomeFeedResponse.self) { group in
            for feed in feeds {
                for kind in CinemetaKind.allCases {
                    group.addTask {
                        HomeFeedResponse(feed: feed, kind: kind, titles: await loadHomeFeed(feed, kind: kind))
                    }
                }
            }
            var responses: [HomeFeed: [CinemetaKind: HomeFeedResponse]] = [:]
            var remaining = feeds.count * CinemetaKind.allCases.count
            for await response in group {
                guard !Task.isCancelled else { break }
                responses[response.feed, default: [:]][response.kind] = response
                remaining -= 1
                if remaining > 0 {
                    await onProgress(Self.homeCatalog(responses, genres: genres, on: date, isComplete: false))
                }
            }
            return Self.homeCatalog(responses, genres: genres, on: date, isComplete: true)
        }
    }

    private func loadHomeFeed(_ feed: HomeFeed, kind: CinemetaKind) async -> [CinemetaTitle]? {
        switch feed {
        case .popular:
            await catalog(kind: kind, filter: nil)
        case .favorites:
            await catalog(kind: kind, filter: nil, id: "trakt-popular", source: .betterPosters)
        case .watching:
            await catalog(kind: kind, filter: nil, id: "trakt-trending", source: .betterPosters)
        case .today:
            await catalog(kind: kind, filter: nil, id: kind == .movie ? "tmdb-today" : "tmdb-today-shows", source: .betterPosters)
        case .releases:
            await catalog(kind: kind, filter: nil, id: kind == .movie ? "tmdb-latest" : "tmdb-latest-shows", source: .betterPosters)
        case .genre(let genre):
            await loadGenre(genre, kind: kind, skip: 0)
        }
    }

    private static func homeCatalog(_ responses: [HomeFeed: [CinemetaKind: HomeFeedResponse]],
                                    genres: [HomeGenre], on date: Date, isComplete: Bool) -> HomeCatalog {
        func catalog(_ feed: HomeFeed) -> CinemetaCatalog {
            CinemetaCatalog(movies: responses[feed]?[.movie]?.titles, series: responses[feed]?[.series]?.titles)
        }

        func failed(_ feed: HomeFeed, kind: CinemetaKind? = nil) -> Bool {
            if let kind, let response = responses[feed]?[kind] { return response.titles == nil }
            if kind != nil { return false }
            return responses[feed]?.values.contains { $0.titles == nil } ?? false
        }

        let popularCatalog = catalog(.popular)
        let favoriteCatalog = catalog(.favorites)
        let watchingCatalog = catalog(.watching)
        let todayCatalog = catalog(.today)
        let releaseCatalog = catalog(.releases)
        let genreRows = genres.compactMap { genre -> HomeCollection? in
            let feed = HomeFeed.genre(genre)
            guard responses[feed] != nil else { return nil }
            return HomeCollection(id: .genre(genre), entries: mixedEntries(catalog(feed)), hasFailure: failed(feed))
        }
        let recentTrends = Self.mixedEntries(watchingCatalog)
        let dailyChart = Array(Self.mixedEntries(todayCatalog).prefix(10))
        let newMovies = Self.entries(in: releaseCatalog, kind: .movie)
        let newSeries = Self.entries(in: releaseCatalog, kind: .series)
        let popularMovies = Self.popularEntries(from: favoriteCatalog, fallback: popularCatalog, kind: .movie)
        let popularSeries = Self.popularEntries(from: favoriteCatalog, fallback: popularCatalog, kind: .series)
        let dailyChartComplete = dailyChart.count == 10 && dailyChart.filter { $0.kind == .movie }.count == 5
        let ranked = dailyChartComplete ? dailyChart : []
        let rated = (Self.mixedEntries(popularCatalog) + genreRows.flatMap(\.entries))
            .compactMap { entry -> (CinemetaSearchResult, Double)? in
                guard let rating = entry.title.imdbRating, rating >= 8 else { return nil }
                return (entry, rating)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        var rows: [HomeCollection] = []
        if responses[.watching] != nil {
            rows.append(HomeCollection(id: .watching, entries: recentTrends,
                                       hasFailure: failed(.watching) || (isComplete && recentTrends.isEmpty)))
        }
        if responses[.today]?.count == CinemetaKind.allCases.count {
            rows.append(HomeCollection(id: .today, entries: ranked, hasFailure: !dailyChartComplete))
        }
        if responses[.releases]?[.movie] != nil {
            rows.append(HomeCollection(id: .newReleases, entries: newMovies, hasFailure: failed(.releases, kind: .movie)))
        }
        if responses[.releases]?[.series] != nil {
            rows.append(HomeCollection(id: .newSeries, entries: newSeries, hasFailure: failed(.releases, kind: .series)))
        }
        if isComplete || !rated.isEmpty {
            rows.append(HomeCollection(id: .topRated, entries: Self.uniqueEntries(rated, limit: rated.count),
                                       hasFailure: failed(.popular) || genreRows.contains(where: \.hasFailure)))
        }
        if responses[.favorites]?[.series] != nil || responses[.popular]?[.series] != nil {
            rows.append(HomeCollection(id: .popularSeries, entries: popularSeries,
                                       hasFailure: failed(.favorites, kind: .series) && failed(.popular, kind: .series)))
        }
        if responses[.favorites]?[.movie] != nil || responses[.popular]?[.movie] != nil {
            rows.append(HomeCollection(id: .popularMovies, entries: popularMovies,
                                       hasFailure: failed(.favorites, kind: .movie) && failed(.popular, kind: .movie)))
        }

        let order: [HomeCollection.ID] = [.watching, .today, .newReleases, .newSeries, .topRated,
                                          .popularSeries, .popularMovies] + genres.map(HomeCollection.ID.genre)
        return HomeCatalog(
            rows: rows + genreRows,
            featuredEntries: Self.featuredEntries(from: [watchingCatalog, todayCatalog, releaseCatalog, popularCatalog],
                                                  excluding: Set(ranked.map(\.catalogID)), on: date),
            rowOrder: order, isComplete: isComplete
        )
    }

    func loadGenre(_ genre: HomeGenre, kind: CinemetaKind, skip: Int) async -> [CinemetaTitle]? {
        await catalog(kind: kind, filter: ("genre", genre.rawValue), skip: skip)
    }

    private static func mixedEntries(_ catalog: CinemetaCatalog) -> [CinemetaSearchResult] {
        let movies = entries(in: catalog, kind: .movie)
        let series = entries(in: catalog, kind: .series)
        return uniqueEntries(interleave(movies, series), limit: movies.count + series.count)
    }

    private static func popularEntries(
        from catalog: CinemetaCatalog, fallback: CinemetaCatalog, kind: CinemetaKind
    ) -> [CinemetaSearchResult] {
        let candidates = entries(in: catalog, kind: kind) + entries(in: fallback, kind: kind)
        return uniqueEntries(candidates, limit: candidates.count)
    }

    private static func featuredEntries(
        from catalogs: [CinemetaCatalog], excluding used: Set<String>, on date: Date
    ) -> [CinemetaSearchResult] {
        let calendar = Calendar.current
        let localMidnight = calendar.startOfDay(for: date)
        let day = Int(floor((localMidnight.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: localMidnight))) / 86_400))

        func rotatedCandidates(for kind: CinemetaKind) -> [CinemetaSearchResult] {
            let candidates = catalogs.flatMap { catalog in
                entries(in: catalog, kind: kind).lazy
                    .filter { $0.title.background != nil && !used.contains($0.catalogID) }
                    .prefix(8)
            }
            // An unchanged pool keeps its lineup even when a feed shuffles its ranking.
            let pool = uniqueEntries(candidates, limit: candidates.count).sorted {
                ($0.title.imdbID ?? $0.id) < ($1.title.imdbID ?? $1.id)
            }
            guard !pool.isEmpty else { return [] }
            let start = ((day % pool.count) * 2 % pool.count + pool.count) % pool.count
            return Array(pool[start...] + pool[..<start])
        }

        let movies = rotatedCandidates(for: .movie)
        let series = rotatedCandidates(for: .series)
        let candidates = day.isMultiple(of: 2) ? interleave(movies, series) : interleave(series, movies)
        return uniqueEntries(candidates, limit: 5)
    }

    private static func interleave(_ first: [CinemetaSearchResult], _ second: [CinemetaSearchResult]) -> [CinemetaSearchResult] {
        (0..<max(first.count, second.count)).flatMap { index in
            [first, second].compactMap { entries in entries.indices.contains(index) ? entries[index] : nil }
        }
    }

    private static func entries(in catalog: CinemetaCatalog, kind: CinemetaKind) -> [CinemetaSearchResult] {
        catalog[kind].compactMap { title in
            guard title.imdbID != nil, !title.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CinemetaSearchResult(title: title, kind: kind)
        }
    }

    private static func uniqueEntries(_ entries: [CinemetaSearchResult], limit: Int) -> [CinemetaSearchResult] {
        var seen = Set<String>()
        var result: [CinemetaSearchResult] = []
        for entry in entries where seen.insert(entry.catalogID).inserted {
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    func details(for title: CinemetaTitle, kind: CinemetaKind) async -> CinemetaTitle? {
        await details(contentID: title.imdbID ?? title.tmdbID ?? title.id, kind: kind)
    }

    func details(imdbID id: String, kind: CinemetaKind) async -> CinemetaTitle? {
        guard id.hasPrefix("tt"), id.utf8.count > 2,
              id.utf8.dropFirst(2).allSatisfy({ (48...57).contains($0) }) else { return nil }
        return await verifiedDetails(contentID: id, kind: kind, source: .cinemeta)
    }

    func details(contentID: String, kind: CinemetaKind) async -> CinemetaTitle? {
        guard contentID.hasPrefix("tmdb:") else { return await details(imdbID: contentID, kind: kind) }
        let digits = contentID.utf8.dropFirst(5)
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return await verifiedDetails(contentID: contentID, kind: kind, source: .betterPosters)
    }

    private func verifiedDetails(contentID: String, kind: CinemetaKind, source: CatalogSource) async -> CinemetaTitle? {
        let response = await fetch(TitleResponse.self, path: "/meta/\(kind.rawValue)/\(contentID).json",
                                   source: source, policy: .title) {
            $0.meta.matchesDetails(for: contentID, kind: kind)
        }
        guard let title = response?.meta, title.matchesDetails(for: contentID, kind: kind) else { return nil }
        return title
    }

    func related(to title: CinemetaTitle, kind: CinemetaKind) async -> [CinemetaTitle] {
        guard let genre = title.genres?.lazy.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }),
              let titles = await catalog(kind: kind, filter: ("genre", genre)) else { return [] }
        return Array(titles.lazy.filter { candidate in
            candidate.id != title.id && (title.imdbID == nil || candidate.imdbID != title.imdbID)
        }.prefix(12))
    }

    private enum CatalogSource: String {
        case cinemeta = "v3-cinemeta.strem.io"
        case betterPosters = "btttr.cc"
    }

    private func catalog(
        kind: CinemetaKind, filter: (name: String, value: String)?, id: String = "top",
        source: CatalogSource = .cinemeta, skip: Int = 0
    ) async -> [CinemetaTitle]? {
        var path = "/catalog/\(kind.rawValue)/\(id)"
        var extra: [String] = []
        if let filter {
            // Stremio transports catalog filters as encoded path segments.
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let value = filter.value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            extra.append("\(filter.name)=\(value)")
        }
        if skip > 0 { extra.append("skip=\(skip)") }
        if !extra.isEmpty { path += "/" + extra.joined(separator: "&") }
        let policy: CinemaMetadataCache.Policy = filter?.name == "search" ? .search : .catalog
        let minimumEntries = switch id {
        case "tmdb-today", "tmdb-today-shows": 5
        case "trakt-popular", "trakt-trending", "tmdb-latest", "tmdb-latest-shows": 1
        default: 0
        }
        let loaded = await fetch(CatalogResponse.self, path: path + ".json", source: source, policy: policy) { response in
            let titles = response.metas.compactMap { entry in
                entry.kind == nil || entry.kind == kind ? entry.title : nil
            }
            guard minimumEntries > 0 else { return response.metas.isEmpty || !titles.isEmpty }
            let usable = titles.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return Set(usable.compactMap(\.imdbID)).count >= minimumEntries
        }
        guard let response = loaded else { return nil }
        var seen = Set<String>()
        return response.metas.compactMap { entry in
            guard let title = entry.title, entry.kind == nil || entry.kind == kind,
                  seen.insert(title.imdbID ?? title.id).inserted else { return nil }
            return title
        }
    }

    private func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type, path: String, source: CatalogSource = .cinemeta, policy: CinemaMetadataCache.Policy,
        canStore: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async -> Value? {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = source.rawValue
        endpoint.percentEncodedPath = path
        guard let url = endpoint.url else { return nil }

        let request = URLRequest(url: url, timeoutInterval: source == .cinemeta ? 12 : 7)
        let session = policy == .search && self.session === URLSession.shared ? Self.searchSession : self.session
        if let cache {
            return await cache.load(type, request: request, session: session, policy: policy, canStore: canStore)
        }
        return await CinemaMetadataCache.loadUncached(type, request: request, session: session)
    }

    private struct TitleResponse: Decodable, Sendable {
        let meta: CinemetaTitle
    }

    private struct CatalogResponse: Decodable, Sendable {
        let metas: [CatalogEntry]
    }

    private struct CatalogEntry: Decodable, Sendable {
        let title: CinemetaTitle?
        let kind: CinemetaKind?

        private enum CodingKeys: String, CodingKey { case type }

        init(from decoder: any Decoder) throws {
            title = try? CinemetaTitle(from: decoder)
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            kind = (try? fields?.decode(String.self, forKey: .type)).flatMap(CinemetaKind.init(rawValue:))
        }
    }
}
