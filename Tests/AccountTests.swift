import Foundation
import XCTest
@testable import NuvioTV

final class AccountTests: XCTestCase {
    func testProgressUsesFullProfileRequestAndNormalizesLegacySeries() async throws {
        let cloud = makeCloud()
        let progress = try await cloud.progress(profile: 6, session: session)

        XCTAssertEqual(progress.count, 201)
        XCTAssertEqual(progress.last?.contentID, "tmdb:201")
        XCTAssertEqual(progress.last?.contentType, "series")
        XCTAssertEqual(progress.last?.id, "series:tmdb:201_s2e3")
    }

    func testLibraryContinuesAfterFirstPageAndNormalizesLegacySeries() async throws {
        let cloud = makeCloud()
        let items = try await cloud.library(profile: 6, session: session)

        XCTAssertEqual(items.count, 201)
        XCTAssertEqual(items.last?.contentID, "tmdb:201")
        XCTAssertEqual(items.last?.contentType, "series")
    }

    func testLegacyHistoryKindMatchesSeries() async throws {
        let cloud = makeCloud()
        let history = try await cloud.history(profile: 6, session: session)

        XCTAssertEqual(history.first?.contentType, "series")
        XCTAssertEqual(history.first?.season, 2)
        XCTAssertEqual(history.first?.episode, 3)
    }

    private var session: NuvioSession {
        NuvioSession(accessToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture,
                     userId: nil, email: nil)
    }

    private func makeCloud() -> NuvioCloud {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountRPCFixture.self]
        return NuvioCloud(session: URLSession(configuration: configuration))
    }
}

private final class AccountRPCFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "api.nuvio.tv" }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        do {
            let (status, rows) = try fixture(for: url.lastPathComponent)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: rows))
            client.urlProtocolDidFinishLoading(self)
        } catch {
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func fixture(for endpoint: String) throws -> (Int, [[String: Any]]) {
        let body = try JSONSerialization.jsonObject(with: requestBody()) as? [String: Int]
        guard body?["p_profile_id"] == 6 else { return (400, []) }

        switch endpoint {
        case "sync_pull_watch_progress":
            guard body?["p_limit"] == nil else { return (400, []) }
            return (200, (1...201).map { index in
                ["progress_key": "tmdb:\(index)_s2e3", "content_id": "tmdb:\(index)", "content_type": "tv",
                 "season": 2, "episode": 3, "position": 60_000, "duration": 300_000, "last_watched": 1_760_000_000_000]
            })
        case "sync_pull_library":
            guard body?["p_limit"] == 200, let offset = body?["p_offset"], [0, 200].contains(offset) else {
                return (400, [])
            }
            let end = min(offset + 200, 201)
            return (200, ((offset + 1)...end).map { index in
                ["id": "library-\(index)", "content_id": "tmdb:\(index)", "content_type": "tv",
                 "name": "Series \(index)", "added_at": 1_760_000_000_000]
            })
        case "sync_pull_watched_items":
            return (200, [["id": "watched-1", "content_id": "tmdb:201", "content_type": "tv",
                           "title": "Series 201", "season": 2, "episode": 3, "watched_at": 1_760_000_000_000]])
        default:
            return (404, [])
        }
    }

    private func requestBody() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var data = Data()
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.badServerResponse) }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
