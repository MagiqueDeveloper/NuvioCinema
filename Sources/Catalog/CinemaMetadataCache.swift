import CryptoKit
import Foundation

actor CinemaMetadataCache {
    static let shared = CinemaMetadataCache()

    enum Policy: Equatable, Sendable {
        case catalog, search, title, reference

        var maxAge: TimeInterval {
            switch self {
            case .catalog: 30 * 60
            case .search: 10 * 60
            case .title: 6 * 60 * 60
            case .reference: 7 * 24 * 60 * 60
            }
        }

        var staleIfError: TimeInterval {
            switch self {
            case .catalog: 24 * 60 * 60
            case .search: 60 * 60
            case .title: 3 * 24 * 60 * 60
            case .reference: 7 * 24 * 60 * 60
            }
        }
    }

    private struct Key: Hashable {
        let url: URL
        let variants: [String]

        var fileName: String {
            let identifier = ([url.absoluteString] + variants).joined(separator: "\u{0}")
            return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct StoredResponse: Codable {
        let data: Data
        let freshness: CinemaHTTPFreshness
    }

    private final class Entry {
        let response: StoredResponse
        let value: any Sendable

        init(response: StoredResponse, value: any Sendable) {
            self.response = response
            self.value = value
        }
    }

    private struct Flight {
        let id: UUID
        let task: Task<Delivery, Error>
        var waiters: Set<UUID>
    }

    private struct Delivery: Sendable {
        let value: any Sendable
        let freshUntil: Date?
    }

    private enum LoadError: Error { case responseStatus(Int) }

    private static let variantHeaders = ["Accept", "Accept-Encoding", "Accept-Language", "User-Agent"]
    private static let maximumStoredResponseSize = 2 * 1024 * 1024
    private static let maximumDiskEntries = 512

    private let directory: URL?
    private let diskLimit: Int
    private let memory = NSCache<NSString, Entry>()
    private var flights: [Key: Flight] = [:]
    private var writesSinceTrim = 0

    init(directory: URL? = CinemaCacheStorage.metadataDirectory, diskLimit: Int = 32 * 1024 * 1024) {
        self.directory = directory
        self.diskLimit = diskLimit
        memory.countLimit = 192
        memory.totalCostLimit = 12 * 1024 * 1024
    }

    /// Empties memory and the disk folder. Requests in flight finish and may store their result again.
    func removeAll() {
        memory.removeAllObjects()
        writesSinceTrim = 0
        if let directory { CinemaCacheStorage.removeContents(of: directory) }
    }

    func load<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: URLRequest,
        session: URLSession = .shared,
        policy: Policy,
        canStore: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async -> Value? {
        await loadWithFreshness(type, request: request, session: session, policy: policy, canStore: canStore)?.value
    }

    func loadWithFreshness<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: URLRequest,
        session: URLSession = .shared,
        policy: Policy,
        canStore: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async -> (value: Value, freshUntil: Date?)? {
        guard !Task.isCancelled else { return nil }
        guard let key = Self.key(for: request) else {
            return await Self.loadUncached(type, request: request, session: session).map { ($0, nil) }
        }

        let fileName = key.fileName
        let (stored, onDisk) = cachedEntry(type, fileName: fileName, policy: policy)
        let entry: Entry?
        if policy == .title, let stored, let value = stored.value as? Value, !canStore(value) {
            remove(fileName, policy: policy)
            entry = nil
        } else {
            entry = stored
        }
        if let entry, let value = entry.value as? Value, entry.response.freshness.expiresAt > .now {
            CinemaNetworkMetrics.recordCacheHit(for: key.url, resource: .metadata, tier: onDisk ? .disk : .memory)
            return (value, entry.response.freshness.expiresAt)
        }

        let waiter = UUID()
        let task: Task<Delivery, Error>
        if let flight = flights[key] {
            flights[key]?.waiters.insert(waiter)
            task = flight.task
            CinemaNetworkMetrics.recordCacheHit(for: key.url, resource: .metadata, tier: .coalesced)
        } else {
            let id = UUID()
            task = Task {
                defer {
                    if flights[key]?.id == id { flights[key] = nil }
                }
                return try await fetch(
                    type, request: request, session: session, policy: policy,
                    cached: entry, key: key, fileName: fileName, canStore: canStore
                )
            }
            flights[key] = Flight(id: id, task: task, waiters: [waiter])
        }
        return await withTaskCancellationHandler {
            guard let result = try? await task.value, !Task.isCancelled,
                  let value = result.value as? Value else { return nil }
            return (value, result.freshUntil)
        } onCancel: {
            Task { await self.cancelWaiter(waiter, for: key) }
        }
    }

    static func loadUncached<Value: Decodable & Sendable>(
        _ type: Value.Type, request: URLRequest, session: URLSession
    ) async -> Value? {
        do {
            let (data, response) = try await CinemaPublicNetwork.shared.data(for: request, session: session, resource: .metadata)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    private func cancelWaiter(_ waiter: UUID, for key: Key) {
        guard flights[key]?.waiters.remove(waiter) != nil,
              let flight = flights[key], flight.waiters.isEmpty else { return }
        flights[key] = nil
        flight.task.cancel()
    }

    private func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: URLRequest,
        session: URLSession,
        policy: Policy,
        cached: Entry?,
        key: Key,
        fileName: String,
        canStore: @Sendable (Value) -> Bool
    ) async throws -> Delivery {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        cached?.response.freshness.applyValidators(to: &request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await CinemaPublicNetwork.shared.data(for: request, session: session, resource: .metadata)
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code != .cancelled,
               let stale = staleDelivery(cached: cached, url: key.url) { return stale }
            throw error
        }
        try Task.checkCancellation()

        let status = response.statusCode
        if status == 304, let cached {
            let refreshed = freshness(for: response, policy: policy, previous: cached.response.freshness)
            let value = cached.value
            if refreshed.allowsStorage, Self.supportsVary(response) {
                store(Entry(response: StoredResponse(data: cached.response.data, freshness: refreshed), value: value),
                      fileName: fileName, policy: policy)
                return Delivery(value: value, freshUntil: refreshed.expiresAt)
            }
            remove(fileName, policy: policy)
            return Delivery(value: value, freshUntil: nil)
        }
        guard (200..<300).contains(status) else {
            if status == 404 || status == 410 { remove(fileName, policy: policy) }
            if status == 408 || status == 429 || (500..<600).contains(status),
               let stale = staleDelivery(cached: cached, url: key.url) { return stale }
            throw LoadError.responseStatus(status)
        }

        let freshness = freshness(for: response, policy: policy)
        let mayStore = freshness.allowsStorage && Self.supportsVary(response)
        if !mayStore { remove(fileName, policy: policy) }

        let value: Value
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            if mayStore, let stale = staleDelivery(cached: cached, url: key.url) { return stale }
            throw error
        }
        guard status == 200, canStore(value) else {
            if mayStore, let stale = staleDelivery(cached: cached, url: key.url) { return stale }
            return Delivery(value: value, freshUntil: nil)
        }
        if mayStore {
            if data.count <= Self.maximumStoredResponseSize {
                store(Entry(response: StoredResponse(data: data, freshness: freshness), value: value),
                      fileName: fileName, policy: policy)
            } else {
                remove(fileName, policy: policy)
            }
        }
        return Delivery(value: value, freshUntil: mayStore ? freshness.expiresAt : nil)
    }

    private func freshness(
        for response: HTTPURLResponse, policy: Policy, previous: CinemaHTTPFreshness? = nil
    ) -> CinemaHTTPFreshness {
        CinemaHTTPFreshness(response: response, defaultMaxAge: policy.maxAge,
                            defaultStaleIfError: policy.staleIfError, revalidating: previous)
    }

    private func staleDelivery(cached: Entry?, url: URL) -> Delivery? {
        guard let cached, cached.response.freshness.staleUntil > .now else { return nil }
        CinemaNetworkMetrics.recordCacheHit(for: url, resource: .metadata, tier: .stale)
        return Delivery(value: cached.value, freshUntil: nil)
    }

    private static func key(for request: URLRequest) -> Key? {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else { return nil }
        let variants = variantHeaders.map { name in
            request.value(forHTTPHeaderField: name)
                ?? (name == "Accept-Language" ? Locale.preferredLanguages.joined(separator: ",") : "")
        }
        return Key(url: url, variants: variants)
    }

    private static func supportsVary(_ response: HTTPURLResponse) -> Bool {
        guard let vary = response.value(forHTTPHeaderField: "Vary") else { return true }
        return vary.split(separator: ",").allSatisfy { token in
            let name = token.trimmingCharacters(in: .whitespaces)
            return variantHeaders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private func cachedEntry<Value: Decodable & Sendable>(
        _ type: Value.Type, fileName: String, policy: Policy
    ) -> (Entry?, onDisk: Bool) {
        if let entry = memory.object(forKey: fileName as NSString), entry.value is Value { return (entry, false) }
        guard policy != .search, let file = directory?.appendingPathComponent(fileName),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return (nil, false) }
        guard size <= Self.maximumStoredResponseSize + 16 * 1024,
              let data = try? Data(contentsOf: file),
              let stored = try? PropertyListDecoder().decode(StoredResponse.self, from: data),
              stored.freshness.allowsStorage,
              let value = try? JSONDecoder().decode(type, from: stored.data) else {
            remove(fileName, policy: policy)
            return (nil, false)
        }
        let entry = Entry(response: stored, value: value)
        memory.setObject(entry, forKey: fileName as NSString, cost: stored.data.count * 2)
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path())
        return (entry, true)
    }

    private func store(_ entry: Entry, fileName: String, policy: Policy) {
        memory.setObject(entry, forKey: fileName as NSString, cost: entry.response.data.count * 2)
        guard policy != .search, let directory, diskLimit > 0 else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let bytes = try? encoder.encode(entry.response), bytes.count <= diskLimit else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            // Listing and statting every file is costly, so trim on the first write and then every 16 writes.
            let trim = writesSinceTrim == 0
            writesSinceTrim = (writesSinceTrim + 1) % 16
            if trim { try trimDisk(at: directory) }
        } catch {
            // Metadata remains usable in memory if tvOS purges or disables the cache directory.
        }
    }

    private func trimDisk(at directory: URL) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                options: .skipsHiddenFiles)
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        guard bytes > diskLimit || count > Self.maximumDiskEntries else { return }
        for (file, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            guard bytes > diskLimit || count > Self.maximumDiskEntries else { break }
            if (try? FileManager.default.removeItem(at: file)) != nil {
                bytes -= size
                count -= 1
            }
        }
    }

    private func remove(_ fileName: String, policy: Policy) {
        memory.removeObject(forKey: fileName as NSString)
        if policy != .search, let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
    }
}
