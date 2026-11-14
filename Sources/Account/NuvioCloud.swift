import Foundation

struct NuvioPairing: Sendable {
    let verificationURL: URL
    let code: String
    let expiresAt: Date
    let pollInterval: TimeInterval
    fileprivate let deviceCode: String
    fileprivate let nonce: String
    fileprivate let polling: NuvioPairingPoll
}

enum NuvioPairingStatus: Sendable {
    case pending, approved, expired
}

struct NuvioSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userId: String?
    let email: String?
}

struct NuvioProfile: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let usesPrimaryAddons: Bool
    let isLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "profile_index"
        case name
        case usesPrimaryAddons = "uses_primary_addons"
        case isLocked = "pin_enabled"
    }
}

struct NuvioAddon: Decodable, Identifiable, Sendable {
    let id: String
    let name: String?
    let enabled: Bool
    let url: String
    let sortOrder: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, url
        case sortOrder = "sort_order"
    }
}

struct NuvioProgress: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let contentID: String
    let contentType: String
    let title: String?
    let season: Int?
    let episode: Int?
    let position: Int64
    let duration: Int64
    fileprivate let lastWatched: Int64
    let progressKey: String?

    var fraction: Double { duration > 0 ? min(1, max(0, Double(position) / Double(duration))) : 0 }
    var updatedAt: Date { Date(timeIntervalSince1970: Double(lastWatched) / 1_000) }

    private enum CodingKeys: String, CodingKey {
        case id, title, season, episode, position, duration
        case contentID = "content_id"
        case contentType = "content_type"
        case lastWatched = "last_watched"
        case progressKey = "progress_key"
    }
}

struct NuvioHistory: Decodable, Identifiable, Sendable {
    let id: String
    let contentID: String
    let contentType: String
    let title: String
    let season: Int?
    let episode: Int?
    fileprivate let watched: Int64

    var watchedAt: Date { Date(timeIntervalSince1970: Double(watched) / 1_000) }

    private enum CodingKeys: String, CodingKey {
        case id, title, season, episode
        case contentID = "content_id"
        case contentType = "content_type"
        case watched = "watched_at"
    }
}

struct NuvioLibraryItem: Decodable, Identifiable, Sendable {
    let id: String
    let contentID: String
    let contentType: String
    let name: String
    private let posterAddress: String?
    private let added: Int64

    var title: String { name }
    var addedAt: Date { Date(timeIntervalSince1970: Double(added) / 1_000) }
    var poster: URL? {
        guard let posterAddress, let url = URL(string: posterAddress),
              url.scheme == "https", url.host() != nil, url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case contentID = "content_id"
        case contentType = "content_type"
        case posterAddress = "poster"
        case added = "added_at"
    }
}

struct NuvioProgressUpdate: Codable, Sendable {
    let contentID: String
    let contentType: String
    let videoID: String
    let progressKey: String
    let season: Int?
    let episode: Int?
    let position: Int64
    let duration: Int64
    let timestamp: Int64

    init(contentID: String, contentType: String, season: Int?, episode: Int?, position: Int64, duration: Int64, timestamp: Int64) {
        self.contentID = contentID
        self.contentType = contentType
        self.season = season
        self.episode = episode
        self.position = position
        self.duration = duration
        self.timestamp = timestamp
        if let season, let episode {
            videoID = "\(contentID):\(season):\(episode)"
            progressKey = "\(contentID)_s\(season)e\(episode)"
        } else {
            videoID = contentID
            progressKey = contentID
        }
    }

    var key: String { "\(contentType):\(progressKey)" }

    func row(id: String? = nil, title: String? = nil) -> NuvioProgress {
        NuvioProgress(id: id ?? key, contentID: contentID, contentType: contentType, title: title, season: season,
                      episode: episode, position: position, duration: duration, lastWatched: timestamp, progressKey: progressKey)
    }

    func matches(_ row: NuvioProgress) -> Bool {
        row.contentID == contentID && row.contentType == contentType && row.season == season && row.episode == episode
    }

    private enum CodingKeys: String, CodingKey {
        case season, episode, position, duration
        case contentID = "content_id"
        case contentType = "content_type"
        case videoID = "video_id"
        case progressKey = "progress_key"
        case timestamp = "last_watched"
    }
}

struct NuvioWatchedUpdate: Codable, Sendable {
    let contentID: String
    let contentType: String
    let title: String
    let season: Int?
    let episode: Int?
    let timestamp: Int64

    func row(key: String, id: String? = nil) -> NuvioHistory {
        NuvioHistory(id: id ?? key, contentID: contentID, contentType: contentType, title: title,
                     season: season, episode: episode, watched: timestamp)
    }

    func matches(_ row: NuvioHistory) -> Bool {
        row.contentID == contentID && row.contentType == contentType && row.season == season && row.episode == episode
    }

    private enum CodingKeys: String, CodingKey {
        case title, season, episode
        case contentID = "content_id"
        case contentType = "content_type"
        case timestamp = "watched_at"
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(contentID, forKey: .contentID)
        try fields.encode(contentType, forKey: .contentType)
        try fields.encode(title, forKey: .title)
        try fields.encode(season, forKey: .season)
        try fields.encode(episode, forKey: .episode)
        try fields.encode(timestamp, forKey: .timestamp)
    }
}

struct NuvioWatchedKey: Encodable, Sendable {
    let contentID: String
    let season: Int?
    let episode: Int?

    private enum CodingKeys: String, CodingKey {
        case contentID = "content_id"
        case season, episode
    }
}

struct NuvioPINResult: Decodable, Sendable {
    let unlocked: Bool
    let retryAfterSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case unlocked
        case retryAfterSeconds = "retry_after_seconds"
    }
}

enum NuvioCloudError: LocalizedError {
    case invalidResponse
    case invalidPairing
    case invalidPIN
    case expiredPairing
    case invalidSession(Int)
    case http(Int, code: String?)

    var status: Int? {
        switch self {
        case .http(let status, _), .invalidSession(let status): status
        default: nil
        }
    }

    var isUnauthorized: Bool { status == 401 }
    var isInvalidSession: Bool {
        if case .invalidSession = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Nuvio returned an unexpected response."
        case .invalidPairing: "Nuvio returned an invalid pairing link."
        case .invalidPIN: "Enter a four-digit PIN."
        case .expiredPairing: "This code expired. Generate a new code to sign in."
        case .invalidSession: "Your Nuvio session expired. Sign in again."
        case .http(429, _): "Too many requests. Try again in a moment."
        case .http: "Nuvio couldn’t complete the request. Try again."
        }
    }
}

struct NuvioCloud: Sendable {
    private static let apiHost = "api.nuvio.tv"
    private static let linkHost = "nuvio.tv"
    // Public client configuration published by NuvioMedia/self-host in .env.example.
    private static let publishableKey = "sb_publishable_1Clq8rlTVACkdcZuqr6_AD__xUUC_EN"
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func startPairing() async throws -> NuvioPairing {
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &random) })
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let identity = ["p_device_nonce": nonce, "p_device_name": "Nuvio Cinema"]
        let modernPath = "/link"
        do {
            let body = identity.merging(["p_device_type": "tv", "p_redirect_base_url": "https://\(Self.linkHost)\(modernPath)"]) { _, new in new }
            let rows: [PairingStart] = try await rpc("start_device_login_session", body: body)
            guard let response = rows.first else { throw NuvioCloudError.invalidResponse }
            return try makePairing(code: response.userCode, deviceCode: response.deviceCode, nonce: nonce,
                                   link: response.link, path: modernPath, expiration: response.expiresAt,
                                   interval: response.pollIntervalSeconds)
        } catch NuvioCloudError.http(404, code: "PGRST202") {
            let legacyPath = "/tv-login"
            let body = identity.merging(["p_redirect_base_url": "https://\(Self.linkHost)\(legacyPath)"]) { _, new in new }
            let rows: [LegacyPairingStart] = try await rpc("start_tv_login_session", body: body)
            guard let response = rows.first else { throw NuvioCloudError.invalidResponse }
            return try makePairing(code: response.code, deviceCode: response.code, nonce: nonce,
                                   link: response.link, path: legacyPath, expiration: response.expiresAt,
                                   interval: response.pollIntervalSeconds)
        }
    }

    func pollPairing(_ pairing: NuvioPairing) async throws -> NuvioPairingStatus {
        guard pairing.expiresAt > .now else { return .expired }
        guard await pairing.polling.begin() else { return .pending }
        let response: PairingPoll
        do {
            let rows: [PairingPoll] = try await rpc("poll_tv_login_session", body: [
                "p_code": pairing.deviceCode, "p_device_nonce": pairing.nonce
            ])
            guard let first = rows.first else { throw NuvioCloudError.invalidResponse }
            response = first
        } catch {
            await pairing.polling.end(interval: nil)
            throw error
        }
        await pairing.polling.end(interval: response.pollIntervalSeconds)
        switch response.status.lowercased() {
        case "approved": return .approved
        case "pending": return .pending
        case "expired", "used", "cancelled": return .expired
        default: throw NuvioCloudError.invalidResponse
        }
    }

    func exchangePairing(_ pairing: NuvioPairing) async throws -> NuvioSession {
        guard pairing.expiresAt > .now else { throw NuvioCloudError.expiredPairing }
        let body = ["code": pairing.deviceCode, "device_nonce": pairing.nonce]
        let response: TokenResponse = try await decode(path: "/functions/v1/tv-logins-exchange", body: body)
        return try await fetchIdentityIfNeeded(response.session())
    }

    func refresh(_ current: NuvioSession) async throws -> NuvioSession {
        do {
            let response: TokenResponse = try await decode(path: "/auth/v1/token",
                                                          query: [.init(name: "grant_type", value: "refresh_token")],
                                                          body: ["refresh_token": current.refreshToken])
            return try await fetchIdentityIfNeeded(response.session(previous: current))
        } catch NuvioCloudError.http(let status, let code) where
            ["refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired", "invalid_grant"].contains(code) {
            throw NuvioCloudError.invalidSession(status)
        }
    }

    func logout(_ current: NuvioSession) async throws {
        _ = try await request(path: "/auth/v1/logout", query: [.init(name: "scope", value: "local")],
                              body: nil, accessToken: current.accessToken)
    }

    func profiles(session current: NuvioSession) async throws -> [NuvioProfile] {
        let profiles: [NuvioProfile] = try await rpc("sync_pull_profiles", body: [String: String](), session: current)
        return profiles.sorted { $0.id < $1.id }
    }

    func addons(profile: Int, usesPrimaryAddons: Bool = false, session current: NuvioSession) async throws -> [NuvioAddon] {
        let owner: String = try await rpc("get_sync_owner", body: [String: String](), session: current)
        guard UUID(uuidString: owner) != nil else { throw NuvioCloudError.invalidResponse }
        let rows: [NuvioAddon] = try await decode(path: "/rest/v1/addons", query: [
            .init(name: "select", value: "id,name,enabled,url,sort_order"),
            .init(name: "user_id", value: "eq.\(owner)"),
            .init(name: "profile_id", value: "eq.\(usesPrimaryAddons ? 1 : profile)"),
            .init(name: "order", value: "sort_order.asc,id.asc")
        ], method: "GET", body: Optional<String>.none, session: current)
        return rows
    }

    func progress(profile: Int, session current: NuvioSession) async throws -> [NuvioProgress] {
        try await rpc("sync_pull_watch_progress", body: ["p_profile_id": profile, "p_limit": 200], session: current)
    }

    func history(profile: Int, session current: NuvioSession) async throws -> [NuvioHistory] {
        let pageSize = 200
        var history: [NuvioHistory] = []
        var seen = Set<NuvioHistory.ID>()
        var page = 1
        while true {
            let rows: [NuvioHistory] = try await rpc("sync_pull_watched_items", body: [
                "p_profile_id": profile, "p_page": page, "p_page_size": pageSize
            ], session: current)
            let additionalRows = rows.filter { seen.insert($0.id).inserted }
            history += additionalRows
            guard rows.count == pageSize, !additionalRows.isEmpty else { return history }
            page += 1
        }
    }

    func pushProgress(_ rows: [NuvioProgressUpdate], profile: Int, origin: String, session current: NuvioSession) async throws {
        let payload = PlaybackPush(profile: profile, origin: origin, entries: rows, items: nil)
        try await pushPlayback("sync_push_watch_progress", payload: payload, session: current)
    }

    func pushWatched(_ rows: [NuvioWatchedUpdate], profile: Int, origin: String, session current: NuvioSession) async throws {
        let payload = PlaybackPush(profile: profile, origin: origin, entries: nil, items: rows)
        try await pushPlayback("sync_push_watched_items", payload: payload, session: current)
    }

    func deleteProgress(_ keys: [String], profile: Int, session current: NuvioSession) async throws {
        try await pushPlayback("sync_delete_watch_progress", payload: PlaybackDelete(profile: profile, keys: keys),
                               session: current)
    }

    func deleteWatched(_ keys: [NuvioWatchedKey], profile: Int, session current: NuvioSession) async throws {
        try await pushPlayback("sync_delete_watched_items", payload: PlaybackDelete(profile: profile, keys: keys),
                               session: current)
    }

    private func pushPlayback(_ rpc: String, payload: some Encodable, session current: NuvioSession) async throws {
        _ = try await request(path: "/rest/v1/rpc/\(rpc)", query: [], body: try JSONEncoder().encode(payload),
                              accessToken: current.accessToken)
    }

    func library(profile: Int, session current: NuvioSession) async throws -> [NuvioLibraryItem] {
        try await rpc("sync_pull_library", body: ["p_profile_id": profile, "p_limit": 200, "p_offset": 0], session: current)
    }

    func verifyPIN(_ pin: String, profile: Int, session current: NuvioSession) async throws -> NuvioPINResult {
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else { throw NuvioCloudError.invalidPIN }
        let rows: [NuvioPINResult] = try await rpc("verify_profile_pin", body: PINRequest(profile: profile, pin: pin), session: current)
        guard let result = rows.first else { throw NuvioCloudError.invalidResponse }
        return result
    }

    private func fetchIdentityIfNeeded(_ current: NuvioSession) async throws -> NuvioSession {
        guard current.userId == nil || current.email == nil else { return current }
        do {
            let user: TokenResponse.User = try await decode(path: "/auth/v1/user", method: "GET",
                                                           body: Optional<String>.none, session: current)
            return NuvioSession(accessToken: current.accessToken, refreshToken: current.refreshToken, expiresAt: current.expiresAt,
                                userId: user.id ?? current.userId, email: user.email ?? current.email)
        } catch {
            try Task.checkCancellation()
            // Identity lookup is optional. Keep the exchanged or rotated tokens and retry on refresh.
            return current
        }
    }

    private func makePairing(code: String, deviceCode: String, nonce: String, link: String, path: String,
                             expiration: String, interval: Int?) throws -> NuvioPairing {
        guard !code.isEmpty, !deviceCode.isEmpty, let expires = Self.timestamp(expiration), expires > .now,
              let url = URLComponents(string: link), url.scheme == "https", url.host == Self.linkHost,
              url.port == nil, url.path == path, url.user == nil, url.password == nil, url.fragment == nil,
              url.queryItems == [URLQueryItem(name: "code", value: code)], let verificationURL = url.url else {
            throw NuvioCloudError.invalidPairing
        }
        let pollInterval = TimeInterval(max(2, interval ?? 3))
        return NuvioPairing(verificationURL: verificationURL, code: code, expiresAt: expires,
                            pollInterval: pollInterval, deviceCode: deviceCode, nonce: nonce,
                            polling: NuvioPairingPoll(interval: pollInterval))
    }

    private static func timestamp(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    private func rpc<Response: Decodable, Body: Encodable>(_ name: String, body: Body, session current: NuvioSession? = nil) async throws -> Response {
        try await decode(path: "/rest/v1/rpc/\(name)", body: body, session: current)
    }

    private func decode<Response: Decodable, Body: Encodable>(path: String, query: [URLQueryItem] = [], method: String = "POST",
                                                               body: Body?, session current: NuvioSession? = nil) async throws -> Response {
        let data = try await request(path: path, query: query, method: method,
                                     body: try body.map { try JSONEncoder().encode($0) }, accessToken: current?.accessToken)
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else { throw NuvioCloudError.invalidResponse }
        return result
    }

    private func request(path: String, query: [URLQueryItem], method: String = "POST", body: Data?, accessToken: String?) async throws -> Data {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = Self.apiHost
        endpoint.path = path
        endpoint.queryItems = query.isEmpty ? nil : query
        guard let url = endpoint.url else { throw NuvioCloudError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: NuvioNoRedirects())
        guard let http = response as? HTTPURLResponse else { throw NuvioCloudError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw NuvioCloudError.http(http.statusCode, code: failure?.errorCode ?? failure?.code ?? failure?.error)
        }
        return data
    }

    private struct PairingStart: Decodable {
        let userCode: String
        let deviceCode: String
        let link: String
        let expiresAt: String
        let pollIntervalSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case userCode = "user_code"
            case deviceCode = "device_code"
            case link = "verification_uri_complete"
            case expiresAt = "expires_at"
            case pollIntervalSeconds = "poll_interval_seconds"
        }
    }

    private struct LegacyPairingStart: Decodable {
        let code: String
        let link: String
        let expiresAt: String
        let pollIntervalSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case code
            case link = "web_url"
            case expiresAt = "expires_at"
            case pollIntervalSeconds = "poll_interval_seconds"
        }
    }

    private struct PairingPoll: Decodable {
        let status: String
        let pollIntervalSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case status
            case pollIntervalSeconds = "poll_interval_seconds"
        }
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable {
            let id: String?
            let email: String?
        }

        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval?
        let expiresAt: TimeInterval?
        let user: User?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case user
        }

        func session(previous: NuvioSession? = nil) throws -> NuvioSession {
            let expiry = expiresAt.map { Date(timeIntervalSince1970: $0) }
                ?? expiresIn.map { Date.now.addingTimeInterval($0) }
            guard !accessToken.isEmpty, !refreshToken.isEmpty, let expiry, expiry > .now else { throw NuvioCloudError.invalidResponse }
            return NuvioSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiry,
                                userId: user?.id ?? previous?.userId, email: user?.email ?? previous?.email)
        }
    }

    private struct ErrorResponse: Decodable {
        let errorCode: String?
        let code: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case code, error
        }
    }

    private struct PINRequest: Encodable {
        let profile: Int
        let pin: String

        enum CodingKeys: String, CodingKey {
            case profile = "p_profile_id"
            case pin = "p_pin"
        }
    }

    private struct PlaybackPush: Encodable {
        let profile: Int
        let origin: String
        let entries: [NuvioProgressUpdate]?
        let items: [NuvioWatchedUpdate]?

        enum CodingKeys: String, CodingKey {
            case profile = "p_profile_id"
            case origin = "p_origin_client_id"
            case entries = "p_entries"
            case items = "p_items"
        }
    }

    private struct PlaybackDelete<Key: Encodable>: Encodable {
        let profile: Int
        let keys: [Key]

        private enum CodingKeys: String, CodingKey {
            case profile = "p_profile_id"
            case keys = "p_keys"
        }
    }
}

fileprivate actor NuvioPairingPoll {
    private var interval: TimeInterval
    private var nextRequest = ContinuousClock.now
    private var inFlight = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func begin() -> Bool {
        guard !inFlight, .now >= nextRequest else { return false }
        inFlight = true
        return true
    }

    func end(interval newInterval: Int?) {
        if let newInterval { interval = TimeInterval(max(2, newInterval)) }
        nextRequest = .now.advanced(by: .seconds(interval))
        inFlight = false
    }
}

private final class NuvioNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
