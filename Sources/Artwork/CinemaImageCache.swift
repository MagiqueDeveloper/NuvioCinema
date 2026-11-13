import CryptoKit
import ImageIO
import SwiftUI

enum CinemaImageError: Error {
    case missing, unavailable, invalidImage
}

actor CinemaImageCache {
    static let shared = CinemaImageCache()
    private static let memory = DecodedImages()
    private static let maximumDownloadSize = 12 * 1024 * 1024

    private let session: URLSession
    private let directory: URL?
    private let diskLimit: Int
    private var requests: [URL: Task<CGImage, Error>] = [:]
    private var missingUntil: [URL: Date] = [:]

    init(session: URLSession = .shared, directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("CinemaArtwork", isDirectory: true), diskLimit: Int = 160 * 1024 * 1024) {
        self.session = session
        self.directory = directory
        self.diskLimit = diskLimit
    }

    nonisolated static func cached(_ url: URL) -> CGImage? {
        memory.image(for: url)
    }

    func image(for url: URL) async throws -> CGImage {
        if let image = Self.cached(url) { return image }
        if let until = missingUntil[url], until > .now { throw CinemaImageError.missing }
        if let request = requests[url] { return try await request.value }

        // Keep a shared request alive when a cell scrolls offscreen.
        let request = Task {
            defer { requests[url] = nil }
            let file = diskURL(for: url)
            if let file, let data = try? Data(contentsOf: file),
               let image = await Self.decode(data) {
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path())
                Self.memory.insert(image, for: url)
                return image
            }

            do {
                let (data, image) = try await Self.download(url, session: session)
                Self.memory.insert(image, for: url)
                if let file { store(data, at: file) }
                return image
            } catch CinemaImageError.missing {
                if missingUntil.count >= 512 {
                    missingUntil = missingUntil.filter { $0.value > .now }
                    if missingUntil.count >= 512 { missingUntil.removeAll(keepingCapacity: true) }
                }
                missingUntil[url] = Date.now.addingTimeInterval(300)
                throw CinemaImageError.missing
            }
        }
        requests[url] = request
        return try await request.value
    }

    private static func download(_ url: URL, session: URLSession) async throws -> (Data, CGImage) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CinemaImageError.unavailable }
        if response.statusCode == 404 || response.statusCode == 410 { throw CinemaImageError.missing }
        guard (200..<300).contains(response.statusCode), data.count <= maximumDownloadSize else {
            throw CinemaImageError.unavailable
        }
        guard let image = await decode(data) else { throw CinemaImageError.invalidImage }
        return (data, image)
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

    private func store(_ data: Data, at file: URL) {
        guard let directory, data.count <= diskLimit else { return }
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
        private let cache = NSCache<NSURL, CGImage>()

        init() {
            cache.totalCostLimit = 128 * 1024 * 1024
            cache.countLimit = 200
        }

        func image(for url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

        func insert(_ image: CGImage, for url: URL) {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
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
