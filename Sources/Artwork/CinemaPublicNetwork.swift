import Foundation
#if DEBUG || NUVIO_NETWORK_METRICS
import OSLog
#endif

enum CinemaNetworkResource: String, Sendable {
    case artwork, metadata
}

enum CinemaNetworkCacheTier: String, Sendable {
    case memory, disk, stale, coalesced
}

enum CinemaPublicNetworkError: Error {
    case invalidHost
    case invalidResponse
    case coolingDown(until: Date)
}

actor CinemaPublicNetwork {
    static let shared = CinemaPublicNetwork()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct HostQueue {
        var active = 0
        var nextStart: ContinuousClock.Instant?
        var cooldownUntil: Date?
        var waiters: [Waiter] = []
        var wakeup: Task<Void, Never>?
    }

    private let clock = ContinuousClock()
    private var hosts: [String: HostQueue] = [:]
    private let maximumConcurrent = 3

    func data(for request: URLRequest, session: URLSession = .shared,
              resource: CinemaNetworkResource) async throws -> (Data, HTTPURLResponse) {
        guard let host = request.url?.host()?.lowercased(), !host.isEmpty else {
            throw CinemaPublicNetworkError.invalidHost
        }
        do {
            try await acquire(for: host)
        } catch let error as CinemaPublicNetworkError {
            #if DEBUG || NUVIO_NETWORK_METRICS
            if case .coolingDown = error {
                CinemaNetworkMetrics.recordCooldownSkip(host: host, resource: resource)
            }
            #endif
            throw error
        }
        defer { release(for: host) }
        try Task.checkCancellation()

        #if DEBUG || NUVIO_NETWORK_METRICS
        let observer = CinemaNetworkTaskObserver(host: host, resource: resource)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: observer)
        } catch {
            CinemaNetworkMetrics.recordTransportError(host: host, resource: resource, error: error)
            throw error
        }
        #else
        let (data, response) = try await session.data(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else { throw CinemaPublicNetworkError.invalidResponse }

        if let until = Self.cooldownDate(for: http) {
            let current = hosts[host]?.cooldownUntil ?? .distantPast
            hosts[host]?.cooldownUntil = max(current, until)
            startNext(for: host)
        }
        #if DEBUG || NUVIO_NETWORK_METRICS
        CinemaNetworkMetrics.recordResponse(host: host, resource: resource, status: http.statusCode)
        #endif
        return (data, http)
    }

    private func acquire(for host: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if hosts[host] == nil, hosts.count >= 32 { pruneIdleHosts() }
                hosts[host, default: HostQueue()].waiters.append(Waiter(id: id, continuation: continuation))
                startNext(for: host)
            }
        } onCancel: {
            Task { await self.cancel(id, for: host) }
        }
    }

    private func pruneIdleHosts() {
        let instant = clock.now
        let date = Date.now
        hosts = hosts.filter { _, queue in
            queue.active > 0 || !queue.waiters.isEmpty
                || queue.nextStart.map { $0 > instant } == true
                || queue.cooldownUntil.map { $0 > date } == true
        }
    }

    private func cancel(_ id: UUID, for host: String) {
        guard let index = hosts[host]?.waiters.firstIndex(where: { $0.id == id }),
              let waiter = hosts[host]?.waiters.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        startNext(for: host)
    }

    private func release(for host: String) {
        hosts[host]?.active -= 1
        startNext(for: host)
    }

    private func startNext(for host: String) {
        guard var queue = hosts[host] else { return }
        if let until = queue.cooldownUntil, until > Date.now {
            let waiting = queue.waiters
            queue.waiters.removeAll()
            queue.wakeup?.cancel()
            queue.wakeup = nil
            hosts[host] = queue
            for waiter in waiting {
                waiter.continuation.resume(throwing: CinemaPublicNetworkError.coolingDown(until: until))
            }
            return
        }

        guard !queue.waiters.isEmpty, queue.active < maximumConcurrent else {
            queue.wakeup?.cancel()
            queue.wakeup = nil
            hosts[host] = queue
            return
        }

        let now = clock.now
        if let nextStart = queue.nextStart, nextStart > now {
            if queue.wakeup == nil {
                queue.wakeup = Task {
                    do { try await clock.sleep(until: nextStart) } catch { return }
                    guard !Task.isCancelled else { return }
                    hosts[host]?.wakeup = nil
                    startNext(for: host)
                }
                hosts[host] = queue
            }
            return
        }

        let waiter = queue.waiters.removeFirst()
        queue.wakeup?.cancel()
        queue.wakeup = nil
        queue.active += 1
        queue.nextStart = now.advanced(by: .milliseconds(host == "api.tvmaze.com" ? 550 : 120))
        hosts[host] = queue
        waiter.continuation.resume()
        if !queue.waiters.isEmpty { startNext(for: host) }
    }

    private static func cooldownDate(for response: HTTPURLResponse, now: Date = .now) -> Date? {
        let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.statusCode == 429 || response.statusCode == 503 && header != nil else { return nil }
        if let header, !header.isEmpty {
            if header.utf8.allSatisfy({ (48...57).contains($0) }),
               let delay = TimeInterval(header), delay.isFinite {
                return now.addingTimeInterval(delay)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: header) { return date }
            }
        }
        return now.addingTimeInterval(15)
    }
}

enum CinemaNetworkMetrics {
    static func recordCacheHit(for url: URL, resource: CinemaNetworkResource, tier: CinemaNetworkCacheTier) {
        #if DEBUG || NUVIO_NETWORK_METRICS
        guard let host = url.host()?.lowercased() else { return }
        let totals = metrics.update(host: host, resource: resource) { $0.cacheHits[tier, default: 0] += 1 }
        let count = totals.cacheHits[tier, default: 0]
        logger.debug("host=\(host, privacy: .public) resource=\(resource.rawValue, privacy: .public) cache=\(tier.rawValue, privacy: .public) count=\(count)")
        #endif
    }

    #if DEBUG || NUVIO_NETWORK_METRICS
    private struct MetricKey: Hashable {
        let host: String
        let resource: CinemaNetworkResource
    }

    private struct Totals {
        var cacheHits: [CinemaNetworkCacheTier: Int] = [:]
        var network = 0
        var protocolCache = 0
        var receivedBytes: Int64 = 0
        var responses = 0
        var rateLimits = 0
        var cooldownSkips = 0
        var transportErrors = 0
    }

    private final class MetricCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var counters: [MetricKey: Totals] = [:]

        func update(host: String, resource: CinemaNetworkResource, _ change: (inout Totals) -> Void) -> Totals {
            let key = MetricKey(host: host, resource: resource)
            lock.lock()
            defer { lock.unlock() }
            change(&counters[key, default: Totals()])
            return counters[key, default: Totals()]
        }
    }

    private static let logger = Logger(subsystem: "com.nuviocinema.app", category: "PublicNetwork")
    private static let metrics = MetricCounts()

    fileprivate static func recordResponse(host: String, resource: CinemaNetworkResource, status: Int) {
        let totals = metrics.update(host: host, resource: resource) {
            $0.responses += 1
            if status == 429 { $0.rateLimits += 1 }
        }
        logger.debug("host=\(host, privacy: .public) resource=\(resource.rawValue, privacy: .public) status=\(status) totalResponses=\(totals.responses) total429=\(totals.rateLimits)")
    }

    fileprivate static func recordCooldownSkip(host: String, resource: CinemaNetworkResource) {
        let totals = metrics.update(host: host, resource: resource) { $0.cooldownSkips += 1 }
        logger.debug("host=\(host, privacy: .public) resource=\(resource.rawValue, privacy: .public) cooldownSkips=\(totals.cooldownSkips)")
    }

    fileprivate static func recordTransportError(host: String, resource: CinemaNetworkResource, error: Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        let code = (error as NSError).code
        let totals = metrics.update(host: host, resource: resource) { $0.transportErrors += 1 }
        logger.debug("host=\(host, privacy: .public) resource=\(resource.rawValue, privacy: .public) errorCode=\(code) totalErrors=\(totals.transportErrors)")
    }

    fileprivate static func recordTransfer(host: String, resource: CinemaNetworkResource,
                                           network: Int, localCache: Int, received: Int64) {
        let totals = metrics.update(host: host, resource: resource) {
            $0.network += network
            $0.protocolCache += localCache
            $0.receivedBytes += received
        }
        logger.debug("host=\(host, privacy: .public) resource=\(resource.rawValue, privacy: .public) network=\(network) protocolCache=\(localCache) receivedBytes=\(received) totalNetwork=\(totals.network) totalProtocolCache=\(totals.protocolCache) totalReceivedBytes=\(totals.receivedBytes)")
    }
    #endif
}

#if DEBUG || NUVIO_NETWORK_METRICS
private final class CinemaNetworkTaskObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let resource: CinemaNetworkResource

    init(host: String, resource: CinemaNetworkResource) {
        self.host = host
        self.resource = resource
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var network = 0
        var localCache = 0
        var received: Int64 = 0
        for transaction in metrics.transactionMetrics {
            switch transaction.resourceFetchType {
            case .networkLoad:
                network += 1
                received += max(0, transaction.countOfResponseHeaderBytesReceived)
                received += max(0, transaction.countOfResponseBodyBytesReceived)
            case .localCache:
                localCache += 1
            default:
                break
            }
        }
        CinemaNetworkMetrics.recordTransfer(host: host, resource: resource, network: network,
                                            localCache: localCache, received: received)
    }
}
#endif
