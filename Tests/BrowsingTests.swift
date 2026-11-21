import Foundation
import XCTest
@testable import NuvioTV

final class BrowsingTests: XCTestCase {
    func testSearchRetryKeepsSuccessfulCategoryAndLoadsFailedCategory() async throws {
        let previous = CinemetaCatalog(movies: [try title("tt101")], series: nil)
        let client = CinemetaClient(session: session())
        let retried = await client.retrySearch(query: "Test", retaining: previous)

        XCTAssertEqual(retried.movies?.map(\.id), ["tt101"])
        XCTAssertEqual(retried.series?.map(\.id), ["tt202"])
        XCTAssertFalse(retried.hasFailure)
    }

    func testGenrePaginationIsolatesFailuresAndAdvancesOverlappingPages() {
        var pagination = GenrePagination()
        pagination.receive(["a", "b"], kind: .movie, skip: 0)
        pagination.receive(nil, kind: .series, skip: 0)
        XCTAssertEqual(pagination.automaticOffsets, [.movie: 50])
        XCTAssertEqual(pagination.retryOffsets, [.series: 0])

        pagination.receive(["b", "c"], kind: .movie, skip: 50)
        pagination.receive(["a", "c"], kind: .movie, skip: 100)
        XCTAssertEqual(pagination.automaticOffsets, [.movie: 150])
        pagination.receive(["c", "b"], kind: .movie, skip: 150)
        XCTAssertTrue(pagination.automaticOffsets.isEmpty)

        pagination.receive(["x"], kind: .series, skip: 0)
        XCTAssertEqual(pagination.automaticOffsets, [.series: 50])
        XCTAssertTrue(pagination.retryOffsets.isEmpty)
        pagination.receive([], kind: .series, skip: 50)
        XCTAssertTrue(pagination.automaticOffsets.isEmpty)
    }

    func testHomeHoldsFocusedShelfPositionAndRefreshesFollowingShelves() throws {
        let order: [HomeCollection.ID] = [.watching, .today, .newReleases, .newSeries, .popularMovies]
        let before = HomeCatalog(rows: [try row(.watching, ["tt101"]), try row(.newSeries, ["tt201", "tt202"]),
                                        try row(.popularMovies, ["tt301"])],
                                 featuredEntries: [], rowOrder: order, isComplete: false)
        let next = HomeCatalog(rows: [try row(.watching, ["tt101"]), try row(.newReleases, ["tt103"]),
                                      try row(.newSeries, ["tt205", "tt201", "tt202"]),
                                      try row(.popularMovies, ["tt302"])],
                               featuredEntries: [], rowOrder: order, isComplete: true)

        let held = try XCTUnwrap(next.preservingFocus(on: .newSeries, entryID: "movie:tt202", from: before))
        XCTAssertEqual(held.shelfOrder, [.watching, .genres, .newSeries, .popularMovies])
        XCTAssertEqual(held.collections.first { $0.id == .newSeries }?.entries.map(\.title.id), ["tt201", "tt202", "tt205"])
        XCTAssertEqual(held.collections.first { $0.id == .popularMovies }?.entries.map(\.title.id), ["tt302"])
        XCTAssertEqual(next.shelfOrder, [.watching, .newReleases, .genres, .newSeries, .popularMovies])
    }

    func testFeaturedArtworkSlidesGentlyInBothDirectionsAndSettles() throws {
        let start = ContinuousClock.now
        let midpoint = start + .milliseconds(375)
        let late = start + .milliseconds(500)
        let finished = start + .milliseconds(675)
        let home = HeroCarousel()

        for step in [-1, 1] {
            let carousel = home.transition(to: 1, step: step, at: start, animated: true)
            let slide = try XCTUnwrap(carousel.slide)
            let slices = slide.backdrop(at: midpoint, entering: 1)
            let incoming = try XCTUnwrap(slices.first { $0.index == 1 })
            let outgoing = try XCTUnwrap(slices.first { $0.index == 0 })
            XCTAssertGreaterThan(incoming.horizontalOffset * Double(step), 0)
            XCTAssertLessThan(outgoing.horizontalOffset * Double(step), 0)
            XCTAssertLessThan(abs(incoming.horizontalOffset), 0.05)
            XCTAssertEqual(slide.backdrop(at: late, entering: 1).count, 2)
            XCTAssertEqual(slide.backdrop(at: finished, entering: 1), [
                HeroCarousel.BackdropSlice(index: 1, coverage: 0..<1, horizontalOffset: 0)
            ])
        }
        XCTAssertNil(home.transition(to: 1, step: 1, at: start, animated: false).slide)
    }

    func testFeaturedArtworkResumesFromItsVisiblePositionWhenInterrupted() throws {
        let start = ContinuousClock.now
        let interruptedAt = start + .milliseconds(375)
        let first = HeroCarousel().transition(to: 1, step: 1, at: start, animated: true)
        let before = try XCTUnwrap(first.slide).backdrop(at: interruptedAt, entering: 1)
        let interrupted = first.transition(to: 2, step: -1, at: interruptedAt, animated: true)
        let slide = try XCTUnwrap(interrupted.slide)
        XCTAssertEqual(slide.backdrop(at: interruptedAt, entering: 2), before)

        let continuing = slide.backdrop(at: interruptedAt + .milliseconds(170), entering: 2)
        XCTAssertEqual(continuing.first?.coverage.lowerBound, 0)
        XCTAssertEqual(continuing.last?.coverage.upperBound, 1)
        for slice in continuing {
            XCTAssertLessThanOrEqual(slice.horizontalOffset, slice.coverage.lowerBound)
            XCTAssertGreaterThanOrEqual(slice.horizontalOffset, slice.coverage.upperBound - 1)
        }
    }

    func testDetailsValidateDeliveryIncludingUncachedResponses() async {
        let client = CinemetaClient(session: session())
        let incompatible = await client.details(imdbID: "tt405", kind: .movie)
        XCTAssertNil(incompatible)

        let validAlias = await client.details(contentID: "tmdb:42", kind: .series)
        XCTAssertEqual(validAlias?.imdbID, "tt302")
        XCTAssertEqual(validAlias?.tmdbID, "tmdb:42")

        let incompatibleAlias = await client.details(contentID: "tmdb:43", kind: .series)
        XCTAssertNil(incompatibleAlias)
    }

    func testDetailsRefetchWhenAnOldCacheEntryDoesNotMatch() async {
        struct StoredTitle: Decodable {
            let meta: CinemetaTitle
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CinemaMetadataCache(directory: directory)
        let session = session()
        var oldRequest = URLRequest(url: URL(string: "https://btttr.cc/meta/series/tmdb:42.json")!)
        oldRequest.setValue("invalid", forHTTPHeaderField: "X-Browsing-Fixture")
        let stored = await cache.load(StoredTitle.self, request: oldRequest, session: session, policy: .title)
        XCTAssertEqual(stored?.meta.tmdbID, "tmdb:99")

        let client = CinemetaClient(session: session, cache: cache)
        let refreshed = await client.details(contentID: "tmdb:42", kind: .series)
        XCTAssertEqual(refreshed?.tmdbID, "tmdb:42")
    }

    func testMetadataCacheRemoveAllEmptiesItsDirectory() async throws {
        struct StoredTitle: Decodable {
            let meta: CinemetaTitle
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CinemaMetadataCache(directory: directory)
        var request = URLRequest(url: URL(string: "https://btttr.cc/meta/series/tmdb:42.json")!)
        request.setValue("invalid", forHTTPHeaderField: "X-Browsing-Fixture")
        _ = await cache.load(StoredTitle.self, request: request, session: session(), policy: .title)
        XCTAssertGreaterThan(CinemaCacheStorage.size(of: directory), 0)

        await cache.removeAll()
        XCTAssertEqual(CinemaCacheStorage.size(of: directory), 0)
    }

    func testCacheStorageSizeSumsNestedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: directory.appendingPathComponent("a"))
        try Data(count: 5_000).write(to: nested.appendingPathComponent("b"))

        XCTAssertGreaterThanOrEqual(CinemaCacheStorage.size(of: directory), 15_000)
        CinemaCacheStorage.removeContents(of: directory)
        XCTAssertEqual(CinemaCacheStorage.size(of: directory), 0)
    }

    func testGenreHeroAlternatesKindsAndNeedsArtwork() throws {
        let movies = try (1...4).map { try entry("tt1\($0)", kind: .movie, artwork: $0 != 2) }
        let series = try (1...4).map { try entry("tt2\($0)", kind: .series, artwork: true) }
        let sections = GenrePageSections.make(movies: movies, series: series, currentYear: 2026)

        XCTAssertEqual(sections.hero.map(\.title.id), ["tt11", "tt21", "tt22", "tt13", "tt23"])
    }

    func testGenreAcclaimedAndRecentRowsRankAndHideShortLists() throws {
        let movies = try [
            entry("tt1", kind: .movie, rating: 7.6, year: 2019),
            entry("tt2", kind: .movie, rating: 8.4, year: 2026),
            entry("tt3", kind: .movie, rating: 6.1, year: 2025),
            entry("tt4", kind: .movie, rating: 7.9, year: 2025),
        ]
        let series = try [
            entry("tt5", kind: .series, rating: 9.0, year: 2024),
            entry("tt6", kind: .series, rating: nil, year: 2026),
        ]
        let sections = GenrePageSections.make(movies: movies, series: series, currentYear: 2026)

        XCTAssertEqual(sections.acclaimed.map(\.title.id), ["tt5", "tt2", "tt4", "tt1"])
        XCTAssertEqual(sections.recent.map(\.title.id), ["tt2", "tt6", "tt3", "tt4"])

        let sparse = GenrePageSections.make(movies: Array(movies.prefix(2)), series: [], currentYear: 2026)
        XCTAssertTrue(sparse.acclaimed.isEmpty)
        XCTAssertTrue(sparse.recent.isEmpty)
    }

    private func entry(_ id: String, kind: CinemetaKind, artwork: Bool = false,
                       rating: Double? = nil, year: Int? = nil) throws -> CinemetaSearchResult {
        var fields: [String: Any] = ["id": id, "name": "Title \(id)"]
        if artwork {
            fields["background"] = "https://example.com/\(id)-background.jpg"
            fields["logo"] = "https://example.com/\(id)-logo.png"
        }
        if let rating { fields["imdbRating"] = String(rating) }
        if let year { fields["releaseInfo"] = String(year) }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return CinemetaSearchResult(title: try JSONDecoder().decode(CinemetaTitle.self, from: data), kind: kind)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowsingCatalogProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func title(_ id: String) throws -> CinemetaTitle {
        try JSONDecoder().decode(CinemetaTitle.self, from: Data(#"{"id":"\#(id)","name":"Test"}"#.utf8))
    }

    private func row(_ id: HomeCollection.ID, _ ids: [String]) throws -> HomeCollection {
        try HomeCollection(id: id, entries: ids.map { CinemetaSearchResult(title: try title($0), kind: .movie) },
                           hasFailure: false)
    }
}

private final class BrowsingCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                   headerFields: ["Content-Type": "application/json"]) else { return }
        let data: String
        if url.path.hasPrefix("/catalog/") {
            let kind = url.path.contains("/series/") ? "series" : "movie"
            data = #"{"metas":[{"id":"tt202","name":"Recovered","type":"\#(kind)"}]}"#
        } else if request.value(forHTTPHeaderField: "X-Browsing-Fixture") == "invalid" {
            data = #"{"meta":{"id":"tt999","name":"Wrong title","type":"series","tmdb_id":99}}"#
        } else if url.path.contains("tt405") {
            data = #"{"meta":{"id":"tt405","name":"Wrong media type","type":"series"}}"#
        } else {
            data = #"{"meta":{"id":"tt302","name":"Known alias","type":"series","tmdb_id":42}}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
