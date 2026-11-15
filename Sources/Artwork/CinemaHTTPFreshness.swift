import Foundation

struct CinemaHTTPFreshness: Codable, Sendable {
    let allowsStorage: Bool
    let expiresAt: Date
    let staleUntil: Date
    let etag: String?
    let lastModified: String?

    private let cacheControl: String?
    private let lifetime: TimeInterval

    init(response: HTTPURLResponse, defaultMaxAge: TimeInterval, defaultStaleIfError: TimeInterval,
         now: Date = .now, revalidating previous: Self? = nil) {
        cacheControl = response.value(forHTTPHeaderField: "Cache-Control") ?? previous?.cacheControl
        let directives = Self.directives(in: cacheControl)
        let vary = response.value(forHTTPHeaderField: "Vary")?.lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let uncacheableVariant = vary.contains { ["*", "authorization", "cookie"].contains($0) }
        allowsStorage = directives["no-store"] == nil && directives["private"] == nil && !uncacheableVariant
        etag = response.value(forHTTPHeaderField: "ETag") ?? previous?.etag
        lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? previous?.lastModified

        let serverDate = response.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate)
        let age = max(0, Self.seconds(response.value(forHTTPHeaderField: "Age")) ?? 0,
                      serverDate.map { now.timeIntervalSince($0) } ?? 0)
        let expiration = response.value(forHTTPHeaderField: "Expires").flatMap(Self.httpDate)
        let explicitLifetime = Self.seconds(directives["max-age"])
            ?? expiration.map { max(0, $0.timeIntervalSince(serverDate ?? now)) }
        lifetime = explicitLifetime ?? previous?.lifetime ?? defaultMaxAge
        let requiresValidation = directives["no-cache"] != nil || directives["must-revalidate"] != nil
        let remaining = directives["no-cache"] == nil ? lifetime - age : min(0, lifetime - age)
        expiresAt = now.addingTimeInterval(remaining)
        let staleAllowance = requiresValidation ? 0 : Self.seconds(directives["stale-if-error"]) ?? defaultStaleIfError
        staleUntil = expiresAt.addingTimeInterval(staleAllowance)
    }

    init(legacyFileDate date: Date, maxAge: TimeInterval, staleIfError: TimeInterval) {
        allowsStorage = true
        expiresAt = date.addingTimeInterval(maxAge)
        staleUntil = expiresAt.addingTimeInterval(staleIfError)
        etag = nil
        lastModified = nil
        cacheControl = nil
        lifetime = maxAge
    }

    func applyValidators(to request: inout URLRequest) {
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
    }

    static func httpDate(_ value: String) -> Date? {
        httpDateFormatter.date(from: value)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func seconds(_ value: String?) -> TimeInterval? {
        guard let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func directives(in header: String?) -> [String: String] {
        var directives: [String: String] = [:]
        for item in (header ?? "").split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            directives[key] = parts.dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) ?? ""
        }
        return directives
    }
}
