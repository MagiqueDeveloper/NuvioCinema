#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

struct CinemaPlaybackActionButton<Content: View>: View {
    let isNextEpisode: Bool
    let isFocused: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadius = AppCardStyle.defaultCornerRadiusRaw

    private var episodeCornerRadius: CGFloat {
        max(14, AppCardStyle.episodeCornerRadius(for: cardCornerRadius))
    }

    var body: some View {
        // Drawn like the other player buttons (white fill, black text when focused) rather than with the
        // system `.glass` style, whose own focus highlight ignored `isFocused` and left the label colours wrong.
        let shape = RoundedRectangle(cornerRadius: isNextEpisode ? episodeCornerRadius : 31, style: .continuous)
        Button(action: action) {
            label()
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, isNextEpisode ? 12 : 25)
                .padding(.vertical, isNextEpisode ? 12 : 0)
                .frame(minHeight: 62)
                .background { background(in: shape) }
                .contentShape(shape)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    @ViewBuilder
    private func background(in shape: RoundedRectangle) -> some View {
        if isFocused {
            shape.fill(Color.white)
        } else if #available(tvOS 26.0, *), AppleTVCapability.current.supportsLiquidGlass {
            shape.fill(Color.black.opacity(0.35))
                .glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color.black.opacity(0.80))
                .overlay { shape.strokeBorder(.white.opacity(0.20), lineWidth: 1) }
        }
    }
}

struct CinemaNextEpisodeActionCard: View {
    let episode: NuvioVideo
    let isEpisodeWatched: Bool
    let isRevealableNextEpisode: Bool
    let isAutoPlayCancelled: Bool

    @AppStorage(SettingsKey.blurUnwatchedEpisodes) private var blurUnwatchedEpisodes = false
    @AppStorage(SettingsKey.hideUnwatchedEpisodeTitles) private var hideUnwatchedEpisodeTitles = false
    @AppStorage(SettingsKey.revealNextEpisodeSpoilers) private var revealNextEpisodeSpoilers = false

    private var hidesSpoilers: Bool {
        !isEpisodeWatched && !(revealNextEpisodeSpoilers && isRevealableNextEpisode)
    }

    private var isPlayable: Bool {
        EpisodeReleasePolicy.hasAired(episode.released)
    }

    private var actionTitle: String {
        if isPlayable { return L10n.string("tvos_play_next_episode", fallback: "Play Next Episode") }
        return L10n.string("player_next_episode", fallback: "Next Episode")
    }

    private var status: String? {
        if !isPlayable {
            if let date = EpisodeReleasePolicy.airDateText(for: episode.released) {
                return L10n.format("details_airs_date", fallback: "Airs %@", date)
            }
            return L10n.string("details_upcoming", fallback: "Upcoming")
        }
        return isAutoPlayCancelled ? L10n.string("player_autoplay_cancelled", fallback: "Auto-Play cancelled") : nil
    }

    var body: some View {
        HStack(spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Image(systemName: isPlayable ? "play.fill" : "calendar")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(actionTitle)
                        .font(.system(size: 23, weight: .semibold))
                        .minimumScaleFactor(0.8)
                }

                if !(hideUnwatchedEpisodeTitles && hidesSpoilers), !episode.title.isEmpty {
                    Text(episode.title)
                        .font(.system(size: 21, weight: .medium))
                }

                Text(L10n.format("details_season_episode", fallback: "Season %1$d · Episode %2$d", episode.season, episode.episode))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)

                if let status {
                    Text(status)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 416, alignment: .leading)
    }

    private var artwork: some View {
        let shouldBlur = blurUnwatchedEpisodes && hidesSpoilers
        let size = CGSize(width: 136, height: 77)
        return CachedArtwork(url: episode.thumbnail.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(shouldBlur ? 1.15 : 1)
                    .blur(radius: shouldBlur ? 16 : 0)
            } else {
                Color(white: 0.16)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

#endif
