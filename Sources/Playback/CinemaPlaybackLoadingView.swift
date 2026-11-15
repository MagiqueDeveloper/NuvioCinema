#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

private struct CinemaPlaybackArtworkKey: EnvironmentKey {
    static let defaultValue: CinemaPlaybackArtwork? = nil
}

extension EnvironmentValues {
    var cinemaPlaybackArtwork: CinemaPlaybackArtwork? {
        get { self[CinemaPlaybackArtworkKey.self] }
        set { self[CinemaPlaybackArtworkKey.self] = newValue }
    }
}

struct CinemaPlaybackLoadingView: View {
    let artwork: CinemaPlaybackArtwork
    let title: String
    let episodeLine: String?
    let message: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedBackdrop: (urls: [URL], image: Image)?

    private var artworkTransaction: Transaction {
        Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.24))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop

            VStack(alignment: .leading, spacing: 16) {
                titleMark

                if let episodeLine, !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }

                if let message, !message.isEmpty {
                    status(message)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 106)
            .padding(.bottom, 96)
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                CinemaStyle.background

                if let backdropImage {
                    backdropImage
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                        .overlay { artworkScrim }
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: artwork.backdropURLs) { await loadBackdrop(from: artwork.backdropURLs) }
    }

    private var backdropImage: Image? {
        if let loadedBackdrop, loadedBackdrop.urls == artwork.backdropURLs {
            return loadedBackdrop.image
        }
        return artwork.backdropURLs.lazy.compactMap { CinemaImageCache.cached($0) }.first
            .map { Image(decorative: $0, scale: 1) }
    }

    private var artworkScrim: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.94), location: 0),
                    .init(color: .black.opacity(0.72), location: 0.32),
                    .init(color: .clear, location: 0.72),
                ],
                startPoint: UnitPoint(x: 0, y: 0.95),
                endPoint: UnitPoint(x: 1, y: 0.36)
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.60),
                    .init(color: .black.opacity(0.56), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func loadBackdrop(from urls: [URL]) async {
        for url in urls {
            guard !Task.isCancelled else { return }
            if let image = try? await CinemaImageCache.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                withTransaction(artworkTransaction) {
                    loadedBackdrop = (urls, Image(decorative: image, scale: 1))
                }
                return
            }
        }
    }

    private var titleMark: some View {
        CachedArtwork(url: artwork.logoURL, transaction: artworkTransaction) { phase in
            if let logo = phase.image {
                logo.resizable()
                    .scaledToFit()
                    .shadow(color: .white.opacity(0.48), radius: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
                    .transition(.opacity)
            } else {
                Text(title)
                    .font(.system(size: 70, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 510, minHeight: 144, maxHeight: 144, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    private func status(_ message: String) -> some View {
        let label = Text(message)
            .font(.system(size: 22, weight: .medium))
            .lineLimit(2, reservesSpace: true)

        return label
            .foregroundStyle(.white.opacity(0.76))
            .overlay {
                if !reduceMotion {
                    movingTextHighlight
                        .mask { label.foregroundStyle(.white) }
                        .accessibilityHidden(true)
                }
            }
    }

    private var movingTextHighlight: some View {
        TimelineView(.animation) { timeline in
            let duration: TimeInterval = 1.8
            let width = 0.62
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
            let left = (1 + width) * phase - width

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.36), location: 0.30),
                    .init(color: .white, location: 0.62),
                    .init(color: .clear, location: 1),
                ],
                startPoint: UnitPoint(x: left, y: 0.5),
                endPoint: UnitPoint(x: left + width, y: 0.5)
            )
        }
    }
}
#endif
