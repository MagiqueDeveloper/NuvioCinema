import Foundation
import Testing
@testable import NuvioTV

@Suite("Cinema playback")
@MainActor
struct PlaybackTests {
    @Test func seekingIntoCreditsPreservesTheLastResumePoint() {
        let recorder = PlaybackProgressRecorder()
        var writes: [(Int64, Bool)] = []
        let write: (Int64, Int64, Bool) -> Void = { position, _, watched in writes.append((position, watched)) }

        recorder.sample(600, duration: 2_400, initialPosition: 0, checkpoint: .periodic, uptime: 1, using: write)
        recorder.sample(2_398, duration: 2_400, initialPosition: 0, checkpoint: .seek, uptime: 2, using: write)
        recorder.sample(2_399, duration: 2_400, initialPosition: 0, checkpoint: .periodic, uptime: 3, using: write)
        recorder.sample(2_400, duration: 2_400, initialPosition: 0, checkpoint: .ended, uptime: 4, using: write)
        recorder.flush(using: write)

        #expect(recorder.resumePosition == 600_000)
        #expect(writes.map(\.0) == [600_000])
        #expect(writes.allSatisfy { !$0.1 })
    }

    @Test func playbackThroughCreditsCompletesOnce() {
        let recorder = PlaybackProgressRecorder()
        var writes: [(Int64, Bool)] = []
        let write: (Int64, Int64, Bool) -> Void = { position, _, watched in writes.append((position, watched)) }

        for position in 84...92 {
            recorder.sample(Double(position), duration: 100, initialPosition: 0, checkpoint: .periodic,
                            uptime: Double(position), using: write)
        }
        recorder.sample(100, duration: 100, initialPosition: 0, checkpoint: .ended, uptime: 100, using: write)
        recorder.flush(using: write)

        #expect(recorder.resumePosition == 0)
        #expect(writes.map(\.0) == [100_000])
        #expect(writes.map(\.1) == [true])
    }

    @Test func naturalEndOfShortContentCompletes() {
        let recorder = PlaybackProgressRecorder()
        var completions: [Int64] = []
        let write: (Int64, Int64, Bool) -> Void = { position, _, watched in
            if watched { completions.append(position) }
        }

        for position in 15...19 {
            recorder.sample(Double(position), duration: 20, initialPosition: 0, checkpoint: .periodic,
                            uptime: Double(position), using: write)
        }
        recorder.sample(20, duration: 20, initialPosition: 0, checkpoint: .ended, uptime: 20, using: write)

        #expect(completions == [20_000])
    }

    @Test func sustainedPlaybackAfterLateResumeCompletesAtNaturalEnd() {
        let recorder = PlaybackProgressRecorder()
        var completions: [Int64] = []
        let write: (Int64, Int64, Bool) -> Void = { position, _, watched in
            if watched { completions.append(position) }
        }

        for position in 87...99 {
            recorder.sample(Double(position), duration: 100, initialPosition: 87_000, checkpoint: .periodic,
                            uptime: Double(position), using: write)
        }
        #expect(completions.isEmpty)
        recorder.sample(100, duration: 100, initialPosition: 87_000, checkpoint: .ended, uptime: 100, using: write)

        #expect(completions == [100_000])
    }

    @Test func committedPausedSeekCanPersistTheBeginning() {
        let recorder = PlaybackProgressRecorder()
        var writes: [Int64] = []
        let write: (Int64, Int64, Bool) -> Void = { position, _, _ in writes.append(position) }

        recorder.sample(0, duration: 300, initialPosition: 90_000, checkpoint: .seek, uptime: 1, using: write)
        recorder.flush(using: write)

        #expect(recorder.resumePosition == 0)
        #expect(writes == [0])
    }

    @Test func directSourceIdentityIncludesNormalizedHeaders() throws {
        let url = try #require(URL(string: "https://example.com/video"))
        func source(_ headers: [String: String]) -> AddonStream {
            AddonStream(id: UUID(), addon: "Provider", name: "Source", description: nil, filename: nil,
                        videoHash: nil, videoSize: nil, notWebReady: false, subtitles: [],
                        destination: .video(url), requestHeaders: headers)
        }

        let first = source(["Referer": " https://a.example ", "Accept": "video/*"])
        let equivalent = source(["accept": "video/*", "referer": "https://a.example"])
        let other = source(["Accept": "video/*", "Referer": "https://b.example"])

        #expect(first.playbackSourceID == equivalent.playbackSourceID)
        #expect(first.playbackSourceID != other.playbackSourceID)
        #expect(first.playbackSourceID != source([:]).playbackSourceID)
    }

    @Test func playableGuideAndNextEpisodeQueueAreIndependent() throws {
        let guide = try JSONDecoder().decode([CinemetaEpisode].self, from: Data("""
        [
          {"id":"show:1:1","season":1,"episode":1},
          {"id":"show:1:2","season":1,"episode":2},
          {"id":"show:1:3","season":1,"episode":3,"released":"2999-01-01T00:00:00Z"},
          {"id":"show:2:1","season":2,"episode":1}
        ]
        """.utf8))
        let request = TitlePlaybackRequest(
            title: "Show", episode: nil, kind: .series, videoIDs: [guide[0].id], position: 0, addons: [],
            contentID: "show", season: 1, episodeNumber: 1, profileID: nil, accountID: nil,
            episodeGuide: guide, selectedEpisode: guide[0]
        )

        #expect(request.playableEpisodes.map(\.id) == [guide[0].id, guide[1].id, guide[3].id])
        #expect(request.followingEpisodes.map(\.id) == [guide[1].id])
        let laterEpisode = request.changingEpisode(to: guide[3], position: 0)
        #expect(laterEpisode.playableEpisodes.first?.id == guide[0].id)
        #expect(laterEpisode.followingEpisodes.isEmpty)
    }

    @Test func sourcesAppearBeforeTheSlowestProviderAndKeepTheirIdentity() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackProviderFixture.self]
        let addons = ["a", "b", "c", "d", "e"].enumerated().map { order, id in
            NuvioAddon(id: id, name: id, enabled: true,
                       url: "https://provider.invalid/\(id)/manifest.json", sortOrder: order)
        }
        var sharedSource: UUID?
        var final: AddonStreamResults?
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { PlaybackProviderFixture.releaseFirstProvider() }
        }
        defer {
            timeout.cancel()
            PlaybackProviderFixture.releaseFirstProvider()
        }

        let loader = AddonStreams(session: URLSession(configuration: configuration))
        for await update in loader.updates(addons: addons, kind: .movie, videoIDs: ["tt123"]) {
            if !update.isComplete, let source = update.streams.first(where: { $0.addon == "e" }) {
                sharedSource = source.id
                PlaybackProviderFixture.releaseFirstProvider()
            }
            if update.isComplete { final = update }
        }

        #expect(sharedSource != nil)
        #expect(final?.streams.map(\.addon) == ["a", "b", "c", "d"])
        #expect(final?.streams.first?.id == sharedSource)
    }
}

private final class PlaybackProviderFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: PlaybackProviderFixture?
    nonisolated(unsafe) private static var hasReleased = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "provider.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/a/manifest.json" {
            let waitForLastProvider = Self.lock.withLock {
                guard !Self.hasReleased else { return false }
                Self.held = self
                return true
            }
            if waitForLastProvider { return }
        }
        respond()
    }

    override func stopLoading() {}

    static func releaseFirstProvider() {
        let ready = lock.withLock {
            let request = held
            hasReleased = true
            held = nil
            return request
        }
        ready?.respond()
    }

    private func respond() {
        guard let url = request.url, let provider = url.pathComponents.dropFirst().first,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let body: String
        if url.lastPathComponent == "manifest.json" {
            body = #"{"name":"\#(provider)","types":["movie"],"resources":["stream"]}"#
        } else {
            let source = provider == "a" || provider == "e" ? "shared" : provider
            body = #"{"streams":[{"url":"https://source.invalid/\#(source).mkv"}]}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
