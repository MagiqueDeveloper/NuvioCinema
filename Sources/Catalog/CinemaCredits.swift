import Foundation

struct CinemaCredit: Sendable {
    let name: String
    let role: String
    let isCast: Bool
}

struct CinemaTitleCredits: Sendable {
    let people: [CinemaCredit]
    let sourceName: String
    let sourceURL: URL
}

actor CinemaCredits {
    static let shared = CinemaCredits()

    private var cache: [String: CinemaTitleCredits] = [:]

    func load(imdbID: String, kind: CinemetaKind) async -> CinemaTitleCredits? {
        let digits = imdbID.utf8.dropFirst(2)
        guard imdbID.hasPrefix("tt"), (1...22).contains(digits.count),
              digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let key = "\(kind.rawValue):\(imdbID)"
        if let cached = cache[key] { return cached }

        let seriesCredits = kind == .series ? await Self.tvMaze(imdbID: imdbID) : nil
        guard !Task.isCancelled else { return nil }
        let credits: CinemaTitleCredits?
        if let seriesCredits {
            credits = seriesCredits
        } else {
            credits = await Self.wikidata(imdbID: imdbID)
        }
        if let credits { cache[key] = credits }
        return credits
    }

    private static func tvMaze(imdbID: String) async -> CinemaTitleCredits? {
        let lookupURL = URL(string: "https://api.tvmaze.com/lookup/shows")!
            .appending(queryItems: [URLQueryItem(name: "imdb", value: imdbID)])
        guard let lookup: TVMazeShow = await fetch(lookupURL), !Task.isCancelled else { return nil }
        let showURL = URL(string: "https://api.tvmaze.com/shows/\(lookup.id)")!
            .appending(queryItems: [URLQueryItem(name: "embed[]", value: "cast"), URLQueryItem(name: "embed[]", value: "crew")])
        guard let show: TVMazeShow = await fetch(showURL), let credits = show._embedded,
              show.url.scheme == "https", show.url.host() == "www.tvmaze.com" else { return nil }

        let cast = credits.cast.compactMap { entry -> CinemaCredit? in
            guard let name = clean(entry.person.name), let character = clean(entry.character.name) else { return nil }
            return CinemaCredit(name: name, role: actorRole(character, voice: entry.voice == true), isCast: true)
        }
        let crew = credits.crew.compactMap { entry -> CinemaCredit? in
            guard let name = clean(entry.person.name), let role = clean(entry.type) else { return nil }
            return CinemaCredit(name: name, role: role, isCast: false)
        }
        guard !cast.isEmpty || !crew.isEmpty else { return nil }
        return CinemaTitleCredits(people: cast + crew, sourceName: "TVmaze · CC BY-SA", sourceURL: show.url)
    }

    private static func wikidata(imdbID: String) async -> CinemaTitleCredits? {
        let query = """
            SELECT DISTINCT ?title ?name ?credit ?characterName ?ordinal WHERE {
              ?title wdt:P345 "\(imdbID)".
              VALUES (?credit ?claim ?statement) {
                ("cast" p:P161 ps:P161)
                ("voice" p:P725 ps:P725)
                ("director" p:P57 ps:P57)
                ("writer" p:P58 ps:P58)
                ("producer" p:P162 ps:P162)
                ("executiveProducer" p:P1431 ps:P1431)
                ("composer" p:P86 ps:P86)
                ("cinematographer" p:P344 ps:P344)
                ("editor" p:P1040 ps:P1040)
                ("creator" p:P170 ps:P170)
              }
              ?title ?claim ?role.
              ?role ?statement ?person; wikibase:rank ?rank.
              FILTER(?rank != wikibase:DeprecatedRank)
              ?person wdt:P31 wd:Q5; rdfs:label ?name.
              FILTER(LANG(?name) = "en")
              OPTIONAL { ?role pq:P1545 ?ordinal. }
              OPTIONAL {
                ?role pq:P4633 ?characterText.
                FILTER(LANG(?characterText) = "en" || LANG(?characterText) = "")
              }
              OPTIONAL {
                ?role pq:P453 ?character.
                ?character rdfs:label ?characterLabel.
                FILTER(LANG(?characterLabel) = "en")
              }
              BIND(COALESCE(?characterText, ?characterLabel) AS ?characterName)
            }
            LIMIT 300
            """
        let url = URL(string: "https://query.wikidata.org/sparql")!.appending(queryItems: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json"),
        ])
        guard let result: WikidataResult = await fetch(url),
              let item = result.results.bindings.first?.title.value,
              result.results.bindings.allSatisfy({ $0.title.value == item }),
              let itemID = URL(string: item)?.lastPathComponent, itemID.hasPrefix("Q"),
              itemID.dropFirst().allSatisfy(\.isASCII), itemID.dropFirst().allSatisfy(\.isNumber),
              let sourceURL = URL(string: "https://www.wikidata.org/wiki/\(itemID)") else { return nil }

        let people = result.results.bindings.sorted { lhs, rhs in
            (lhs.billingOrder, lhs.credit.value, lhs.name.value) < (rhs.billingOrder, rhs.credit.value, rhs.name.value)
        }.compactMap { entry -> CinemaCredit? in
            guard let name = clean(entry.name.value) else { return nil }
            let isCast = entry.credit.value == "cast" || entry.credit.value == "voice"
            let role = if isCast {
                actorRole(clean(entry.characterName?.value), voice: entry.credit.value == "voice")
            } else {
                crewRole(entry.credit.value)
            }
            guard let role else { return nil }
            return CinemaCredit(name: name, role: role, isCast: isCast)
        }
        guard !people.isEmpty else { return nil }
        return CinemaTitleCredits(people: people, sourceName: "Wikidata · CC0", sourceURL: sourceURL)
    }

    private static func actorRole(_ character: String?, voice: Bool) -> String {
        if let character {
            return voice ? String(localized: "\(character) (Voice)") : character
        }
        return voice ? String(localized: "Voice Cast") : String(localized: "Cast")
    }

    private static func crewRole(_ value: String) -> String? {
        switch value {
        case "director": String(localized: "Director")
        case "writer": String(localized: "Writer")
        case "producer": String(localized: "Producer")
        case "executiveProducer": String(localized: "Executive Producer")
        case "composer": String(localized: "Composer")
        case "cinematographer": String(localized: "Cinematographer")
        case "editor": String(localized: "Editor")
        case "creator": String(localized: "Creator")
        default: nil
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fetch<Value: Decodable>(_ url: URL) async -> Value? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("NuvioCinema/0.1 (https://github.com/MagiqueDeveloper/NuvioCinema)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private struct TVMazeShow: Decodable {
        let id: Int
        let url: URL
        let _embedded: Credits?

        struct Credits: Decodable {
            let cast: [Cast]
            let crew: [Crew]
        }

        struct Cast: Decodable {
            let person: Name
            let character: Name
            let voice: Bool?
        }

        struct Crew: Decodable {
            let person: Name
            let type: String
        }

        struct Name: Decodable {
            let name: String
        }
    }

    private struct WikidataResult: Decodable {
        let results: Results

        struct Results: Decodable {
            let bindings: [Binding]
        }

        struct Binding: Decodable {
            let title: Value
            let name: Value
            let credit: Value
            let characterName: Value?
            let ordinal: Value?

            var billingOrder: Int { ordinal.flatMap { Int($0.value) } ?? Int.max }
        }

        struct Value: Decodable {
            let value: String
        }
    }
}
