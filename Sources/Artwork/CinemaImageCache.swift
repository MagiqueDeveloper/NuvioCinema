import CryptoKit
import ImageIO
import SwiftUI

enum CinemaImageError: Error {
    case missing, unavailable, invalidImage, throttled
    case response(Int)
}

actor CinemaImageCache {
    static let shared = CinemaImageCache()
    private static let memory = DecodedImages()
    private static let maximumDownloadSize = 12 * 1024 * 1024
    private static let defaultMaxAge: TimeInterval = 86_400
    private static let defaultStaleIfError: TimeInterval = 7 * 86_400

    private let session: URLSession
    private let directory: URL?
    private let diskLimit: Int
    private var requests: [URL: ArtworkRequest] = [:]
    private var missingUntil: [URL: Date] = [:]

    private struct ArtworkRequest {
        let task: Task<CGImage, Error>
        var consumers: Set<UUID>
    }

    private struct StoredArtwork: Codable {
        let data: Data
        let freshness: CinemaHTTPFreshness
    }

    private struct DecodedArtwork {
        let image: CGImage
        let freshness: CinemaHTTPFreshness
    }

    init(session: URLSession = .shared, directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("CinemaArtwork", isDirectory: true), diskLimit: Int = 160 * 1024 * 1024) {
        self.session = session
        self.directory = directory
        self.diskLimit = diskLimit
    }

    nonisolated static func cached(_ url: URL) -> CGImage? {
        guard let artwork = memory.artwork(for: url), artwork.freshness.expiresAt > .now else { return nil }
        return artwork.image
    }

    func image(for url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        if let image = Self.cached(url) {
            CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .memory)
            return image
        }
        if let until = missingUntil[url], until > .now {
            CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .memory)
            throw CinemaImageError.missing
        }
        let consumer = UUID()
        let task: Task<CGImage, Error>
        if let request = requests[url] {
            CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .coalesced)
            requests[url]?.consumers.insert(consumer)
            task = request.task
        } else {
            task = Task { try await loadImage(for: url) }
            requests[url] = ArtworkRequest(task: task, consumers: [consumer])
        }
        return try await withTaskCancellationHandler {
            defer { release(consumer, for: url) }
            let image = try await task.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await self.release(consumer, for: url) }
        }
    }

    private func release(_ consumer: UUID, for url: URL) {
        guard requests[url]?.consumers.remove(consumer) != nil, requests[url]?.consumers.isEmpty == true else { return }
        requests.removeValue(forKey: url)?.task.cancel()
    }

    private func loadImage(for url: URL) async throws -> CGImage {
        let file = diskURL(for: url)
        let stored = file.flatMap(readArtwork)
        var cached = Self.memory.artwork(for: url)
        if cached == nil, let stored, let image = await Self.decode(stored.data) {
            cached = DecodedArtwork(image: image, freshness: stored.freshness)
        }
        try Task.checkCancellation()
        if let cached, cached.freshness.expiresAt > .now {
            CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .disk)
            if let file {
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path())
            }
            Self.memory.insert(cached, for: url)
            return cached.image
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        cached?.freshness.applyValidators(to: &request)
        do {
            let (data, response) = try await CinemaPublicNetwork.shared.data(for: request, session: session, resource: .artwork)
            try Task.checkCancellation()
            let previous = response.statusCode == 304 ? cached?.freshness : nil
            let freshness = CinemaHTTPFreshness(response: response, defaultMaxAge: Self.defaultMaxAge,
                                                defaultStaleIfError: Self.defaultStaleIfError, revalidating: previous)
            switch response.statusCode {
            case 304:
                guard let cached else { throw CinemaImageError.unavailable }
                save(cached.image, bytes: stored?.data, freshness: freshness, url: url, file: file)
                return cached.image
            case 200..<300:
                guard data.count <= Self.maximumDownloadSize, let image = await Self.decode(data) else {
                    throw CinemaImageError.invalidImage
                }
                try Task.checkCancellation()
                save(image, bytes: data, freshness: freshness, url: url, file: file)
                return image
            case 404, 410:
                removeArtwork(for: url, file: file)
                if freshness.allowsStorage, freshness.expiresAt > .now {
                    if missingUntil.count >= 512 {
                        missingUntil = missingUntil.filter { $0.value > .now }
                        if missingUntil.count >= 512 { missingUntil.removeAll(keepingCapacity: true) }
                    }
                    missingUntil[url] = min(freshness.expiresAt, .now.addingTimeInterval(300))
                }
                throw CinemaImageError.missing
            case 429:
                throw CinemaImageError.throttled
            default:
                throw CinemaImageError.response(response.statusCode)
            }
        } catch {
            try Task.checkCancellation()
            let failure: Error
            if case .coolingDown? = error as? CinemaPublicNetworkError {
                failure = CinemaImageError.throttled
            } else {
                failure = error
            }
            if let cached, cached.freshness.staleUntil > .now, Self.canUseStale(after: failure) {
                CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .stale)
                return cached.image
            }
            throw failure
        }
    }

    private static func canUseStale(after error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        switch error as? CinemaImageError {
        case .throttled?: return true
        case let .response(status)?: return (500..<600).contains(status)
        default: return false
        }
    }

    private func save(_ image: CGImage, bytes: Data?, freshness: CinemaHTTPFreshness, url: URL, file: URL?) {
        guard freshness.allowsStorage else {
            removeArtwork(for: url, file: file)
            return
        }
        Self.memory.insert(DecodedArtwork(image: image, freshness: freshness), for: url)
        if let file, let bytes { store(StoredArtwork(data: bytes, freshness: freshness), at: file) }
    }

    private func removeArtwork(for url: URL, file: URL?) {
        Self.memory.remove(url)
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private static func decode(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2160,
            ] as CFDictionary)
        }.value
    }

    private func diskURL(for url: URL) -> URL? {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let key = hash.map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(key)
    }

    private func readArtwork(_ file: URL) -> StoredArtwork? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let stored = try? PropertyListDecoder().decode(StoredArtwork.self, from: data) { return stored }
        let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let freshness = CinemaHTTPFreshness(legacyFileDate: date, maxAge: Self.defaultMaxAge,
                                            staleIfError: Self.defaultStaleIfError)
        return StoredArtwork(data: data, freshness: freshness)
    }

    private func store(_ artwork: StoredArtwork, at file: URL) {
        guard let directory else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(artwork), data.count <= diskLimit else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            let entries = files.compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
                return (url, size, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var bytes = entries.reduce(0) { $0 + $1.1 }
            for (url, size, _) in entries where bytes > diskLimit {
                if (try? manager.removeItem(at: url)) != nil { bytes -= size }
            }
        } catch {
            // The decoded image is still available when the system purges the disk cache.
        }
    }

    private final class DecodedImages: @unchecked Sendable {
        private final class Entry {
            let artwork: DecodedArtwork

            init(_ artwork: DecodedArtwork) { self.artwork = artwork }
        }

        private let cache = NSCache<NSURL, Entry>()

        init() {
            cache.totalCostLimit = 128 * 1024 * 1024
            cache.countLimit = 200
        }

        func artwork(for url: URL) -> DecodedArtwork? { cache.object(forKey: url as NSURL)?.artwork }

        func insert(_ artwork: DecodedArtwork, for url: URL) {
            let image = artwork.image
            cache.setObject(Entry(artwork), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }

        func remove(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
    }
}

struct CachedArtwork<Content: View>: View {
    let url: URL?
    let transaction: Transaction
    let content: (AsyncImagePhase) -> Content

    @State private var loadedURL: URL?
    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.transaction = transaction
        self.content = content
    }

    private var visiblePhase: AsyncImagePhase {
        if url == loadedURL { return phase }
        if let url, let image = CinemaImageCache.cached(url) {
            return .success(Image(decorative: image, scale: 1))
        }
        return .empty
    }

    var body: some View {
        content(visiblePhase)
            .task(id: url) {
                guard let url else { return }
                do {
                    let image = try await CinemaImageCache.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                    withTransaction(transaction) {
                        phase = .success(Image(decorative: image, scale: 1))
                        loadedURL = url
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                    loadedURL = url
                }
            }
    }
}
