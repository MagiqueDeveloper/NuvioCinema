import SwiftUI
import UIKit

struct TitleLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: 17) {
            RoundedRectangle(cornerRadius: 15)
                .frame(width: 260, height: 126)
            RoundedRectangle(cornerRadius: 7)
                .frame(width: 190, height: 17)
            RoundedRectangle(cornerRadius: 7)
                .frame(width: 130, height: 14)
        }
        .foregroundStyle(.white.opacity(0.10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading title")
    }
}

struct TitleDetailsView: View {
    let title: CinemetaTitle
    let kind: CinemetaKind
    let restartItem: CinemaContinueWatchingItem?
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.resetFocus) private var resetFocus
    @Environment(NuvioAccount.self) private var account
    @Environment(CinemaTitleNavigation.self) private var titles
    @Namespace private var titleFocusScope
    @FocusState private var focus: FocusTarget?
    @State private var details: CinemetaTitle?
    @State private var loadFailed = false
    @State private var loadAttempt = 0
    @State private var selectedSeason: Int?
    @State private var seasonSlideOffset: CGFloat = 0
    @State private var playbackRequest: TitlePlaybackRequest?
    @State private var playbackOrigin: FocusTarget?
    @State private var didHandleInitialFocus = false
    @State private var episodeUnavailable = false
    @State private var unavailableEpisodeRelease: Date?
    @State private var trailerUnavailable = false
    @State private var portraits: [String: CastPortrait] = [:]
    @State private var showsCredits = false
    @State private var credits: CinemaTitleCredits?
    @State private var related: [CinemetaTitle] = []
    @State private var relatedOriginID: String?

    init(title: CinemetaTitle, kind: CinemetaKind, restartItem: CinemaContinueWatchingItem? = nil,
         onDismiss: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.restartItem = restartItem
        self.onDismiss = onDismiss
    }
    @State private var loadedHeroBackdrop: Image?

    private enum FocusTarget: Hashable {
        case overview, play, episodes, trailers, trailer(String), cast(String), related(String), about, information
        case season(Int), episode(String), retry
    }

    private enum Section: Hashable { case hero, episodes, trailers }
    private enum FocusRegion: Equatable { case hero, seasonPicker, episodeCards }

    private var focusRegion: FocusRegion? {
        switch focus {
        case .overview?, .play?, .episodes?, .trailers?:
            return .hero
        case .season?:
            return .seasonPicker
        case .episode?:
            return .episodeCards
        case .retry?:
            return kind == .series ? .seasonPicker : .hero
        default:
            return nil
        }
    }

    private enum WatchStatus {
        case watched
        case inProgress(Double)

        var accessibilityDescription: String {
            switch self {
            case .watched:
                String(localized: "Watched")
            case .inProgress(let fraction):
                String(localized: "\(fraction.formatted(.percent.precision(.fractionLength(0)))) watched")
            }
        }
    }

    private var metadata: CinemetaTitle { details ?? title }
    private var watchContentID: String { metadata.imdbID ?? title.imdbID ?? title.id }
    private var trailers: [CinemaTrailer] { metadata.trailers.isEmpty ? title.trailers : metadata.trailers }
    private var people: [PersonCredit] {
        let extra = credits?.people ?? []
        let castRole = String(localized: "Cast")
        let cast = metadata.cast.isEmpty ? title.cast : metadata.cast
        let directors = metadata.directors.isEmpty ? title.directors : metadata.directors
        let writers = metadata.writers.isEmpty ? title.writers : metadata.writers
        let knownCrew = directors.map { CinemaCredit(name: $0, role: String(localized: "Director"), isCast: false) }
            + writers.map { CinemaCredit(name: $0, role: String(localized: "Writer"), isCast: false) }

        let extraCast = extra.filter(\.isCast)
        let castByName = Dictionary(grouping: extraCast) { creditNameKey($0.name) }
        let billedCast = cast.flatMap { name in
            castByName[creditNameKey(name)] ?? [CinemaCredit(name: name, role: castRole, isCast: true)]
        }
        return mergePeople(billedCast + extraCast + knownCrew + extra.filter { !$0.isCast })
    }

    private func mergePeople(_ credits: [CinemaCredit]) -> [PersonCredit] {
        var castKeys: [String] = []
        var crewKeys: [String] = []
        var people: [String: PersonCredit] = [:]
        for credit in credits {
            let key = creditNameKey(credit.name)
            if people[key] == nil {
                if credit.isCast {
                    guard castKeys.count < 24 else { continue }
                    castKeys.append(key)
                } else {
                    guard crewKeys.count < 24 else { continue }
                    crewKeys.append(key)
                }
                people[key] = PersonCredit(id: key, name: credit.name, roles: [])
            }
            if people[key]?.roles.contains(credit.role) == false { people[key]?.roles.append(credit.role) }
        }
        return (castKeys + crewKeys).compactMap { people[$0] }
    }

    private var creditsIMDbID: String? { metadata.imdbID ?? title.imdbID }

    private func creditNameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            .filter { $0.isLetter || $0.isNumber }
    }
    private var synopsis: String? {
        [metadata.description, title.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
    private var relatedSeed: CinemetaTitle { metadata.genres?.isEmpty == false ? metadata : title }
    private var episodes: [CinemetaEpisode] {
        if let details, !details.episodes.isEmpty { return details.episodes }
        return title.episodes
    }

    private var episodeGroups: [Int: [CinemetaEpisode]] {
        Dictionary(grouping: episodes, by: \.season)
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 28) {
                    hero(scroll: scroll)
                        .id(Section.hero)
                    if kind == .series {
                        episodesSection
                            .id(Section.episodes)
                    }
                    if !trailers.isEmpty {
                        trailersSection
                            .id(Section.trailers)
                    }
                    if !related.isEmpty {
                        relatedShelf
                    }
                    if !people.isEmpty {
                        castShelf
                    }
                    aboutSection
                    informationSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: focusRegion) { _, region in
                guard isEnabled, playbackRequest == nil, let region else { return }
                scrollToSection(region == .hero ? .hero : .episodes, using: scroll)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { notification in
                guard isEnabled, playbackRequest == nil, !episodeUnavailable, !trailerUnavailable,
                      case .season? = focus,
                      let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                      context.focusHeading == .up else { return }
                // An offscreen hero may have no eligible target above the focused season.
                returnToHero(using: scroll)
            }
        }
        .background { CinemaStyle.background.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .focusScope(titleFocusScope)
        .defaultFocus($focus, .play)
        .onExitCommand(perform: playbackRequest == nil ? onDismiss : nil)
        .task {
            guard !didHandleInitialFocus else { return }
            didHandleInitialFocus = true
            openInitialPlayback()
            guard playbackRequest == nil else { return }
            focus = .play
            // The focus engine may register the new screen on a later layout pass.
            do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            guard !Task.isCancelled, playbackRequest == nil, focus == nil else { return }
            resetFocus(in: titleFocusScope)
            focus = .play
        }
        #if NUVIO_UPSTREAM_PLAYER
        .disabled(playbackRequest != nil)
        .accessibilityHidden(playbackRequest != nil)
        .overlay {
            if let playbackRequest {
                playbackView(for: playbackRequest)
                    .transition(.opacity)
            }
        }
        .onChange(of: playbackRequest?.id) { _, id in
            if id == nil { restorePlaybackFocus() }
        }
        #else
        .fullScreenCover(item: $playbackRequest, onDismiss: restorePlaybackFocus) { request in
            playbackView(for: request)
                .presentationBackground(.clear)
        }
        #endif
        .alert("Episode Unavailable", isPresented: $episodeUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            if let unavailableEpisodeRelease {
                Text("This episode airs \(CinemetaEpisode.displayAirDate(unavailableEpisodeRelease)).")
            } else if details == nil && !loadFailed {
                Text("Episode information hasn’t loaded yet. Choose an episode when it’s available.")
            } else {
                Text("No episodes are available to play.")
            }
        }
        .alert("Couldn’t open YouTube", isPresented: $trailerUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This trailer opens in the YouTube app when it’s available on your Apple TV.")
        }
        .task(id: relatedSeed.genres?.first) {
            let matches = await CinemetaClient().related(to: relatedSeed, kind: kind)
            guard !Task.isCancelled else { return }
            related = matches
        }
        .task(id: creditsIMDbID) {
            guard let imdbID = creditsIMDbID else { return }
            let loaded = await CinemaCredits.shared.load(imdbID: imdbID, kind: kind)
            guard !Task.isCancelled else { return }
            credits = loaded
        }
        .task(id: loadAttempt) {
            let loaded = await CinemetaClient().details(for: title, kind: kind)
            guard !Task.isCancelled else { return }
            if let loaded {
                details = loaded
            } else {
                loadFailed = true
            }
        }
    }

    private func hero(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            overview
            heroActions(scroll: scroll)
        }
        .frame(maxWidth: 690, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 42)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * 0.91
        }
        .background { heroBackdrop }
        .focusSection()
    }

    private func openInitialPlayback() {
        guard let restartItem,
              let current = account.continueWatching.first(where: { $0.id == restartItem.id }),
              current.progress.season == restartItem.progress.season,
              current.progress.episode == restartItem.progress.episode else { return }
        if kind == .series {
            guard let episode = current.episode, !episode.isUpcoming() else { return }
        }
        showPlayback(episode: current.episode, progress: current.progress, origin: .play,
                     startsFromBeginning: true)
    }

    private func heroActions(scroll: ScrollViewProxy) -> some View {
        let episode = kind == .series ? heroEpisode() : nil
        let saved = savedHeroProgress(for: episode)
        let progress = saved.flatMap { NuvioAccount.hasStarted($0) && $0.fraction < 0.95 ? $0 : nil }
        let remaining = progress.flatMap(remainingPlaybackTime)
        return HStack(spacing: 18) {
            Button(action: playTitle) {
                if let progress, let remaining {
                    HStack(spacing: 14) {
                        Image(systemName: "play.fill")
                        Capsule()
                            .fill(.foreground.opacity(0.24))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.foreground).frame(width: 92 * progress.fraction)
                            }
                            .frame(width: 92, height: 8)
                        Text(remaining)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                } else {
                    Label(progress == nil ? "Play" : "Resume", systemImage: "play.fill")
                        .padding(.horizontal, 14)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel(progress == nil ? Text("Play") : Text("Resume"))
            .accessibilityValue(remaining.map { Text("\($0) remaining") } ?? Text(""))
            .focused($focus, equals: .play)
            .prefersDefaultFocus(in: titleFocusScope)

            if kind == .series {
                Button {
                    scrollToSection(.episodes, using: scroll)
                    let groups = episodeGroups
                    if let season = displayedSeason(in: groups, currentEpisode: currentEpisode(in: groups)) {
                        focus = .season(season)
                    } else if loadFailed {
                        focus = .retry
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Episodes")
                .focused($focus, equals: .episodes)
            }

            if let first = trailers.first {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.46)) {
                        scroll.scrollTo(Section.trailers, anchor: .top)
                        focus = .trailer(first.id)
                    }
                } label: {
                    Image(systemName: "film")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(trailers.count == 1 ? Text("Trailer") : Text("Trailers"))
                .focused($focus, equals: .trailers)
            }

            if kind == .movie && loadFailed {
                Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .retry)
            }
        }
        .buttonBorderShape(.capsule)
    }

    private func scrollToSection(_ section: Section, using scroll: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.42)) {
            scroll.scrollTo(section, anchor: section == .episodes ? .center : .top)
        }
    }

    private func returnToHero(using scroll: ScrollViewProxy) {
        let origin = focus
        Task { @MainActor in
            await Task.yield()
            guard isEnabled, playbackRequest == nil, !episodeUnavailable, !trailerUnavailable, focus == origin else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.42)) {
                scroll.scrollTo(Section.hero, anchor: .top)
                focus = .play
            } completion: {
                guard isEnabled, playbackRequest == nil, !episodeUnavailable, !trailerUnavailable,
                      focus == nil || focus == origin else { return }
                resetFocus(in: titleFocusScope)
                focus = .play
            }
        }
    }

    private func savedHeroProgress(for episode: CinemetaEpisode?) -> NuvioProgress? {
        kind == .series
            ? episode.flatMap(episodeProgress)
            : account.continueProgress(for: watchContentID, kind: kind)
    }

    private func remainingPlaybackTime(_ progress: NuvioProgress) -> String? {
        guard progress.duration > 0 else { return nil }
        let milliseconds = progress.duration - min(progress.position, progress.duration)
        let minutes = max(1, Int(ceil(Double(milliseconds) / 60_000)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    private func heroEpisode() -> CinemetaEpisode? {
        let groups = episodeGroups
        let now = Date.now
        let playable = orderedSeasons(groups).flatMap { season in
            groups[season, default: []].filter { !$0.isUpcoming(at: now) }.sorted { $0.episode < $1.episode }
        }
        return account.currentSeriesEpisode(in: playable, contentID: watchContentID)
            ?? playable.first { !account.hasWatched(watchContentID, kind: kind, season: $0.season, episode: $0.episode) }
            ?? playable.first
    }

    private func playTitle() {
        let episode = kind == .series ? heroEpisode() : nil
        guard kind == .movie || episode != nil else {
            let now = Date.now
            unavailableEpisodeRelease = episodes.compactMap(\.releasedAt).filter { $0 > now }.min()
            episodeUnavailable = true
            return
        }
        showPlayback(episode: episode, progress: savedHeroProgress(for: episode), origin: .play)
    }

    private func playEpisode(_ episode: CinemetaEpisode) {
        if episode.isUpcoming() {
            unavailableEpisodeRelease = episode.releasedAt
            episodeUnavailable = true
            return
        }
        showPlayback(episode: episode, progress: episodeProgress(episode), origin: .episode(episode.id))
    }

    private func episodeProgress(_ episode: CinemetaEpisode) -> NuvioProgress? {
        account.progress(for: watchContentID, kind: kind, season: episode.season, episode: episode.episode)
    }

    private func showPlayback(episode: CinemetaEpisode?, progress: NuvioProgress?, origin: FocusTarget,
                              startsFromBeginning: Bool = false) {
        let candidates: [String]
        if let episode {
            let standardID = "\(watchContentID):\(episode.season):\(episode.episode)"
            let catalogID = "\(title.id):\(episode.season):\(episode.episode)"
            let cloudID = progress.map { "\($0.contentID):\(episode.season):\(episode.episode)" }
            candidates = [standardID, episode.id, catalogID, cloudID].compactMap { $0 }
        } else {
            candidates = [watchContentID, title.id, progress?.contentID].compactMap { $0 }
        }
        var seen = Set<String>()
        let resumePosition = progress.flatMap { NuvioAccount.hasStarted($0) && $0.fraction < 0.95 ? $0.position : nil }
        let position = startsFromBeginning ? 0 : (resumePosition ?? 0)
        playbackOrigin = origin
        let contentID = progress?.contentID ?? watchContentID
        let request = TitlePlaybackRequest(title: metadata.name, episode: episode.map {
            String(localized: "S\($0.season), E\($0.episode) · \($0.name)")
        }, kind: kind, videoIDs: candidates.filter { seen.insert($0).inserted }, position: position, addons: account.addons,
                                           contentID: contentID, season: episode?.season, episodeNumber: episode?.episode,
                                           profileID: account.profileID, accountID: account.playbackAccountID,
                                           followingEpisodes: episode.map { nextEpisodesForPlayback(after: $0) } ?? [],
                                           metadata: metadata, selectedEpisode: episode,
                                           startsFromBeginning: startsFromBeginning)
        setPlaybackRequest(request)
    }

    private func nextEpisodesForPlayback(after current: CinemetaEpisode) -> [CinemetaEpisode] {
        let now = Date.now
        var seen = Set<String>()
        let following = episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }.filter { episode in
            guard (episode.season, episode.episode) > (current.season, current.episode),
                  current.season == 0 ? episode.season == 0 : episode.season > 0 else { return false }
            return seen.insert("\(episode.season):\(episode.episode)").inserted
        }
        return Array(following.prefix { !$0.isUpcoming(at: now) })
    }

    private func dismissPlaybackSources() {
        setPlaybackRequest(nil)
    }

    private func playbackView(for request: TitlePlaybackRequest) -> some View {
        TitlePlaybackView(request: request, account: account,
                          isPresented: { playbackRequest?.id == request.id }, onDismiss: dismissPlaybackSources)
            .id(request.id)
    }

    private func setPlaybackRequest(_ request: TitlePlaybackRequest?) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.14 : 0.25)) {
            playbackRequest = request
        }
    }

    private func restorePlaybackFocus() {
        guard let playbackOrigin else { return }
        self.playbackOrigin = nil
        focus = playbackOrigin
        Task { @MainActor in
            await Task.yield()
            guard playbackRequest == nil, focus == nil else { return }
            focus = playbackOrigin
        }
    }

    private var heroBackdrop: some View {
        let animate = !reduceMotion
        let transaction = Transaction(animation: animate ? .easeOut(duration: 0.44) : nil)
        let catalogURL = title.background
        let detailURL = details?.background
        let urls = [catalogURL, detailURL == catalogURL ? nil : detailURL].compactMap { $0 }
        let cached = urls.lazy.compactMap { CinemaImageCache.cached($0) }.first

        return GeometryReader { geometry in
            ZStack {
                CinemaStyle.background
                if let image = loadedHeroBackdrop ?? cached.map({ Image(decorative: $0, scale: 1) }) {
                    image.resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                        .transition(.opacity)
                }
            }
        }
        .task(id: urls) {
            await loadHeroBackdrop(from: urls, transaction: transaction)
        }
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.94), location: 0),
                    .init(color: .black.opacity(0.72), location: 0.30),
                    .init(color: .clear, location: 0.66),
                ],
                startPoint: UnitPoint(x: 0, y: 0.9),
                endPoint: UnitPoint(x: 1, y: 0.36)
            )
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.79),
                    .init(color: .white.opacity(0.88), location: 0.86),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .visualEffect { effect, geometry in
            let distance = max(0, -geometry.frame(in: .scrollView(axis: .vertical)).minY)
            let amount = Double(min(1, distance / max(1, geometry.size.height * 0.65)))
            return effect.opacity(animate ? 1 - 0.46 * amount : 1)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .accessibilityHidden(true)
    }

    private func loadHeroBackdrop(from urls: [URL], transaction: Transaction) async {
        guard loadedHeroBackdrop == nil, !urls.isEmpty else { return }

        var candidates = urls
        for attempt in 0..<2 {
            var transientFailures: [URL] = []
            for url in candidates {
                do {
                    let image = try await CinemaImageCache.shared.image(for: url)
                    try Task.checkCancellation()
                    withTransaction(transaction) {
                        loadedHeroBackdrop = Image(decorative: image, scale: 1)
                    }
                    return
                } catch CinemaImageError.missing {
                    continue
                } catch {
                    guard !Task.isCancelled else { return }
                    transientFailures.append(url)
                }
            }
            guard attempt == 0, !transientFailures.isEmpty else { return }
            candidates = transientFailures
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleLogo
            metadataRow

            if let synopsis {
                Text(synopsis)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineSpacing(4)
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
            } else if details == nil && !loadFailed {
                VStack(alignment: .leading, spacing: 11) {
                    skeletonLine(width: 600, height: 17)
                    skeletonLine(width: 530, height: 17)
                    skeletonLine(width: 352, height: 17)
                }
                .frame(height: 90, alignment: .center)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading title information")
            } else if loadFailed && kind == .movie {
                Text("Couldn’t load title information.")
                    .foregroundStyle(.secondary)
            }

            if kind == .movie, account.hasWatched(watchContentID, kind: kind) {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .focusable(kind == .movie)
        .focusEffectDisabled()
        .focused($focus, equals: .overview)
    }

    private var titleLogo: some View {
        let transaction = Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.25))
        return CachedArtwork(url: title.logo ?? details?.logo, transaction: transaction) { phase in
            if let logo = phase.image {
                logo.resizable()
                    .scaledToFit()
                    .shadow(color: .white.opacity(0.48), radius: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
                    .transition(.opacity)
            } else {
                Text(metadata.name)
                    .font(.system(size: 70, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 510, minHeight: 144, maxHeight: 144, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.name)
        .accessibilityAddTraits(.isHeader)
    }

    private var metadataRow: some View {
        let category = kind == .movie ? String(localized: "Movie") : String(localized: "Series")
        let genres = (metadata.genres ?? title.genres ?? []).prefix(2).joined(separator: " / ")
        let facts = [category, metadata.displayReleaseInfo ?? title.displayReleaseInfo,
                     genres, metadata.runtime ?? title.runtime]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        return HStack(spacing: 15) {
            Text(facts.joined(separator: "  •  "))
            if let rating = metadata.imdbRating ?? title.imdbRating {
                HStack(spacing: 7) {
                    Text("IMDb")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 4))
                    Text(rating, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("IMDb rating")
                .accessibilityValue("\(rating, format: .number.precision(.fractionLength(1))) out of 10")
            }
        }
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }

    private enum DetailShelf {
        static let sectionGap: CGFloat = 20
        static let cardGap: CGFloat = 28
        static let cardRadius: CGFloat = 14
        static let wideArtwork = CGSize(width: 320, height: 180)
        static let posterArtwork = CGSize(width: 186, height: 279)
    }

    private var trailersSection: some View {
        VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            sectionHeading("Trailers")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DetailShelf.cardGap) {
                    ForEach(Array(trailers.enumerated()), id: \.element.id) { index, trailer in
                        let name = trailerName(trailer, index: index)
                        Button {
                            Task {
                                let opened = await UIApplication.shared.open(trailer.youtubeURL, options: [.universalLinksOnly: true])
                                trailerUnavailable = !opened
                            }
                        } label: {
                            trailerCard(trailer, name: name)
                        }
                        .focused($focus, equals: .trailer(trailer.id))
                        .accessibilityLabel(name)
                        .accessibilityHint("Opens in YouTube")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func trailerName(_ trailer: CinemaTrailer, index: Int) -> String {
        if let name = trailer.title,
           name.localizedCaseInsensitiveCompare(metadata.name) != .orderedSame,
           trailers.filter({ $0.title == name }).count == 1 {
            return name
        }
        return trailers.count == 1 ? String(localized: "Trailer") : String(localized: "Trailer \(index + 1)")
    }

    private func trailerCard(_ trailer: CinemaTrailer, name: String) -> some View {
        let size = DetailShelf.wideArtwork
        let shape = RoundedRectangle(cornerRadius: DetailShelf.cardRadius)
        let url = URL(string: "https://i.ytimg.com/vi/\(trailer.id)/mqdefault.jpg")

        return VStack(alignment: .leading, spacing: 12) {
            shelfArtwork(url: url, size: size) {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)

            shelfCaption(name, width: size.width)
        }
    }

    private struct PersonCredit: Identifiable {
        let id: String
        let name: String
        var roles: [String]

        var role: String { roles.joined(separator: " · ") }
    }

    private var castShelf: some View {
        let people = people
        let names = people.map(\.name)
        return VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            sectionHeading("Cast & Crew")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DetailShelf.cardGap) {
                    ForEach(people) { person in
                        castCard(person, portrait: portraits[person.name])
                            .focusable()
                            .focused($focus, equals: .cast(person.id))
                            .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .task(id: names) {
            let loaded = await CastPortraits.shared.load(for: names)
            guard !Task.isCancelled else { return }
            portraits = loaded
        }
    }

    private func castCard(_ person: PersonCredit, portrait: CastPortrait?) -> some View {
        let isFocused = focus == .cast(person.id)
        let size: CGFloat = 148

        return VStack(spacing: 12) {
            CachedArtwork(url: portrait?.url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .overlay {
                            Text(initials(for: person.name))
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.92), lineWidth: 3)
                    .padding(-4)
                    .opacity(isFocused ? 1 : 0)
            }
            .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(person.name)
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.8))
                Text(person.role)
                    .font(.system(size: 19))
                    .lineLimit(3)
                    .foregroundStyle(.white.opacity(isFocused ? 0.7 : 0.5))
            }
            .multilineTextAlignment(.center)
            .frame(width: 172, alignment: .top)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.count > 1 ? [words.first?.first, words.last?.first] : [words.first?.first]
        return String(letters.compactMap { $0 }).uppercased()
    }

    private var relatedShelf: some View {
        VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            sectionHeading("Related")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DetailShelf.cardGap) {
                    ForEach(related) { item in
                        Button {
                            relatedOriginID = item.id
                            titles.show(onDismiss: restoreRelatedFocus) { close in
                                TitleDetailsView(title: item, kind: kind, onDismiss: close)
                            }
                        } label: {
                            relatedCard(item)
                        }
                        .focused($focus, equals: .related(item.id))
                        .accessibilityLabel(item.name)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func relatedCard(_ item: CinemetaTitle) -> some View {
        let size = DetailShelf.posterArtwork
        let shape = RoundedRectangle(cornerRadius: DetailShelf.cardRadius)

        return VStack(alignment: .leading, spacing: 12) {
            shelfArtwork(url: BetterPosters.url(for: item.imdbID), size: size, isPoster: true, fallbackURL: item.poster) {
                EmptyView()
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)

            shelfCaption(item.name, width: size.width)
        }
    }

    private func shelfArtwork<Overlay: View>(
        url: URL?,
        size: CGSize,
        isPoster: Bool = false,
        fallbackURL: URL? = nil,
        isFocused: Bool = false,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: DetailShelf.cardRadius)

        return Group {
            if isPoster {
                CatalogArtwork(url: url, fallbackURL: fallbackURL, isPoster: true)
            } else {
                CachedArtwork(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color(white: 0.09)
                    }
                }
            }
        }
            .frame(width: size.width, height: size.height)
            .overlay(content: overlay)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(isFocused ? 0.92 : 0.16), lineWidth: isFocused ? 3 : 1)
            }
            .accessibilityHidden(true)
    }

    private func shelfCaption(_ name: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(name)
            .font(.system(size: 23, weight: .semibold))
            .lineLimit(2, reservesSpace: true)
            .frame(width: width, alignment: alignment)
    }

    private func restoreRelatedFocus() {
        if let id = relatedOriginID { focus = .related(id) }
        relatedOriginID = nil
    }

    private var aboutSection: some View {
        detailPanel("About", target: .about) {
            VStack(alignment: .leading, spacing: 12) {
                Text(metadata.name)
                    .font(.system(size: 28, weight: .semibold))
                Text(synopsis ?? String(localized: "No synopsis available."))
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private struct InformationField {
        let label: String
        let value: String
    }

    private var information: [InformationField] {
        var fields: [InformationField] = []

        func add(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.caseInsensitiveCompare("N/A") != .orderedSame else { return }
            fields.append(InformationField(label: label, value: value))
        }

        add(String(localized: "Type"), kind == .movie ? String(localized: "Movie") : String(localized: "Series"))
        let genres = metadata.genres.flatMap { $0.isEmpty ? nil : $0 } ?? title.genres ?? []
        add(String(localized: "Genres"), genres.joined(separator: ", "))

        if let date = metadata.released ?? title.released {
            add(String(localized: "Released"), date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
        } else {
            add(String(localized: "Release Year"), metadata.releaseYear ?? title.releaseYear)
        }

        add(String(localized: "Runtime"), metadata.runtime ?? title.runtime)
        add(String(localized: "Content Rating"), metadata.contentRating ?? title.contentRating)
        if let rating = metadata.imdbRating ?? title.imdbRating {
            add(String(localized: "IMDb Rating"), String(localized: "\(rating.formatted(.number.precision(.fractionLength(1)))) out of 10"))
        }

        let countries = metadata.countries.isEmpty ? title.countries : metadata.countries
        let languages = metadata.languages.isEmpty ? title.languages : metadata.languages
        add(String(localized: "Region of Origin"), countries.joined(separator: ", "))
        add(String(localized: "Languages"), languages.joined(separator: ", "))

        if kind == .series {
            add(String(localized: "Status"), metadata.status ?? title.status)
            let seasonCount = episodeGroups.keys.filter { $0 > 0 }.count
            if seasonCount > 0 { add(String(localized: "Seasons"), seasonCount.formatted()) }
        }
        add(String(localized: "Awards"), metadata.awards ?? title.awards)
        return fields
    }

    private var informationSection: some View {
        detailPanel("Information", target: .information) {
            let columns = [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 28, alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(information, id: \.label) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.label)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(field.value)
                            .font(.system(size: 25))
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if credits != nil || !portraits.isEmpty {
                Button {
                    showsCredits.toggle()
                } label: {
                    Label(showsCredits ? "Hide Credits" : "Show Credits", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                if showsCredits {
                    attributionCredits
                }
            }
        }
    }

    private var attributionCredits: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let credits {
                Link(credits.sourceName, destination: credits.sourceURL)
            }
            ForEach(portraits.keys.sorted(), id: \.self) { name in
                if let portrait = portraits[name] {
                    HStack(spacing: 18) {
                        Link("\(name) · \(portrait.attribution)", destination: portrait.sourceURL)
                        if let licenseURL = portrait.licenseURL {
                            Link("License", destination: licenseURL)
                                .accessibilityLabel("Photo license for \(name)")
                        }
                    }
                }
            }
            if !portraits.isEmpty {
                Text("Portraits are displayed with a circular crop.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 21))
    }

    private func detailPanel<Content: View>(
        _ title: LocalizedStringKey,
        target: FocusTarget,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let focused = focus == target
        let shape = RoundedRectangle(cornerRadius: 18)

        return VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            sectionHeading(title)
            content()
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(focused ? 0.09 : 0.045), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(focused ? 0.42 : 0.11), lineWidth: 1) }
        .padding(.horizontal, 16)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: target)
        .focusSection()
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 36, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(height / 2, 12))
            .fill(.white.opacity(0.10))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    private var episodeSkeleton: some View {
        VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            skeletonLine(width: 148, height: 48)
            HStack(alignment: .top, spacing: DetailShelf.cardGap) {
                ForEach(0..<4) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.white.opacity(0.08))
                            .aspectRatio(16 / 9, contentMode: .fit)
                        skeletonLine(width: index.isMultiple(of: 2) ? 180 : 224, height: 18)
                        skeletonLine(width: 106, height: 13)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading episodes")
    }

    @ViewBuilder
    private var episodesSection: some View {
        let groups = episodeGroups
        let currentEpisode = currentEpisode(in: groups)
        let seasons = orderedSeasons(groups)
        let displayedSeason = displayedSeason(in: groups, currentEpisode: currentEpisode)
        VStack(alignment: .leading, spacing: DetailShelf.sectionGap) {
            sectionHeading("Episodes")
            if let season = displayedSeason, let seasonEpisodes = groups[season] {
                seasonPicker(seasons: seasons, current: season)
                ZStack {
                    episodeShelf(seasonEpisodes.sorted { $0.episode < $1.episode },
                                 initialEpisodeID: currentEpisode?.season == season ? currentEpisode?.id : nil)
                        .id(season)
                        .transition(seasonShelfTransition)
                }
            } else if loadFailed {
                Text("Couldn’t load episodes.")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
                    .focused($focus, equals: .retry)
            } else if details == nil {
                episodeSkeleton
            } else {
                Text("No episodes available.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onChange(of: focus) { _, focused in
            if case let .season(season)? = focused {
                selectSeason(season, from: displayedSeason, in: seasons)
            } else if selectedSeason == nil, case let .episode(id)? = focused {
                // Late progress or metadata must not replace a shelf the viewer is already using.
                selectedSeason = groups.first { $0.value.contains { $0.id == id } }?.key
            }
        }
    }

    private var seasonShelfTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .offset(x: seasonSlideOffset).combined(with: .opacity),
            removal: .identity
        )
    }

    private func selectSeason(_ season: Int, from current: Int?, in seasons: [Int]) {
        guard selectedSeason != season else { return }
        guard let current, let fromIndex = seasons.firstIndex(of: current),
              let toIndex = seasons.firstIndex(of: season), fromIndex != toIndex else {
            selectedSeason = season
            return
        }
        seasonSlideOffset = toIndex > fromIndex ? 104 : -104
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) {
            selectedSeason = season
        }
    }

    private func orderedSeasons(_ groups: [Int: [CinemetaEpisode]]) -> [Int] {
        let regular = groups.keys.filter { $0 > 0 }.sorted()
        return groups[0] == nil ? regular : regular + [0]
    }

    private func retry() {
        loadFailed = false
        loadAttempt += 1
    }

    private func currentEpisode(in groups: [Int: [CinemetaEpisode]]) -> CinemetaEpisode? {
        guard selectedSeason == nil else { return nil }
        let now = Date.now
        let playable = groups.values.flatMap { $0 }.filter { !$0.isUpcoming(at: now) }
        return account.currentSeriesEpisode(in: playable, contentID: watchContentID)
    }

    private func displayedSeason(in groups: [Int: [CinemetaEpisode]], currentEpisode: CinemetaEpisode?) -> Int? {
        if let selectedSeason, groups[selectedSeason] != nil { return selectedSeason }
        return currentEpisode?.season ?? orderedSeasons(groups).first
    }

    private func seasonPicker(seasons: [Int], current: Int) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(seasons, id: \.self) { season in
                        let label: LocalizedStringKey = season == 0 ? "Specials" : "Season \(season)"
                        Button {
                            selectSeason(season, from: current, in: seasons)
                        } label: {
                            Text(label)
                        }
                        .buttonStyle(.bordered)
                        .tint(season == current ? .white : .gray)
                        .accessibilityAddTraits(season == current ? .isSelected : [])
                        .focused($focus, equals: .season(season))
                    }
                }
                .padding(.vertical, 8)
            }
            .task(id: current) {
                guard !Task.isCancelled, selectedSeason == nil, current != seasons.first else { return }
                scroll.scrollTo(current, anchor: .leading)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func episodeShelf(_ episodes: [CinemetaEpisode], initialEpisodeID: CinemetaEpisode.ID?) -> some View {
        let now = Date.now
        return ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DetailShelf.cardGap) {
                    ForEach(episodes) { episode in
                        let upcoming = episode.isUpcoming(at: now)
                        let status = upcoming ? nil : episodeWatchStatus(episode)
                        let airDate = episode.releasedAt.map { release in
                            let date = CinemetaEpisode.displayAirDate(release)
                            return upcoming ? String(localized: "Coming \(date)") : date
                        }
                        Button {
                            playEpisode(episode)
                        } label: {
                            episodeCard(episode, status: status, airDate: airDate, upcoming: upcoming)
                        }
                        .focused($focus, equals: .episode(episode.id))
                        .accessibilityLabel("Episode \(episode.episode), \(episode.name)")
                        .accessibilityValue([airDate, status?.accessibilityDescription, episode.overview]
                            .compactMap { $0 }.joined(separator: ". "))
                        .contextMenu { episodeMenu(for: episode, status: status) }
                    }
                }
            }
            .task(id: initialEpisodeID) {
                guard !Task.isCancelled, selectedSeason == nil,
                      let initialEpisodeID, initialEpisodeID != episodes.first?.id else { return }
                scroll.scrollTo(initialEpisodeID, anchor: .leading)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.borderless)
        .focusSection()
    }

    @ViewBuilder
    private func episodeMenu(for episode: CinemetaEpisode, status: WatchStatus?) -> some View {
        if account.profileID != nil, !episode.isUpcoming() {
            if case .watched? = status {
                Button("Mark as Unwatched", systemImage: "eye.slash") {
                    setEpisodesWatched([episode], watched: false)
                }
            } else {
                Button("Mark as Watched", systemImage: "checkmark") {
                    setEpisodesWatched([episode], watched: true)
                }
            }
            Button("Mark Watched Up to Here", systemImage: "checklist.checked") {
                let target = (episode.season, episode.episode)
                let now = Date.now
                let previous = episodes.filter {
                    ($0.season, $0.episode) <= target && ($0.season == 0) == (episode.season == 0)
                        && !$0.isUpcoming(at: now)
                }
                setEpisodesWatched(previous, watched: true)
            }
        }
    }

    private func setEpisodesWatched(_ episodes: [CinemetaEpisode], watched: Bool) {
        let profileID = account.profileID
        let accountID = account.playbackAccountID
        let title = metadata
        let contentID = watchContentID
        // Let the native menu finish dismissing before updating the cards it belongs to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard account.profileID == profileID, account.playbackAccountID == accountID else { return }
            account.setEpisodesWatched(episodes, title: title, contentID: contentID, watched: watched)
        }
    }

    private func episodeWatchStatus(_ episode: CinemetaEpisode) -> WatchStatus? {
        if account.hasWatched(watchContentID, kind: kind, season: episode.season, episode: episode.episode) {
            return .watched
        }
        guard let progress = account.progress(for: watchContentID, kind: kind, season: episode.season, episode: episode.episode),
              NuvioAccount.hasStarted(progress), progress.duration > 0 else { return nil }
        return .inProgress(progress.fraction)
    }

    private func episodeCard(_ episode: CinemetaEpisode, status: WatchStatus?, airDate: String?, upcoming: Bool) -> some View {
        let size = CGSize(width: 380, height: 214)
        let shape = RoundedRectangle(cornerRadius: 18)

        return VStack(alignment: .leading, spacing: 0) {
            episodeArtwork(episode.thumbnail, size: size)
                .overlay(alignment: .bottom) {
                    if case let .inProgress(fraction)? = status {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.68))
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Episode \(episode.episode)")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if case .watched? = status {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    if let airDate {
                        Text(airDate)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(upcoming ? Color.cyan : .white.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, upcoming ? 10 : 0)
                            .background(upcoming ? .cyan.opacity(0.13) : .clear, in: Capsule())
                            .layoutPriority(1)
                    }
                }
                .frame(height: 27)

                Text(episode.name)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                Text(episode.overview ?? "")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(17)
        }
        .frame(width: size.width)
        .foregroundStyle(.white)
        .background(Color(white: 0.095))
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.lift)
    }

    private func episodeArtwork(_ thumbnail: URL?, size: CGSize) -> some View {
        CachedArtwork(url: thumbnail) { phase in
            if let image = phase.image {
                image.resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else if thumbnail != nil, case .empty = phase {
                Color(white: 0.09)
            } else {
                CachedArtwork(url: metadata.background ?? title.background) { fallback in
                    if let image = fallback.image {
                        image.resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    } else {
                        Color(white: 0.09)
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
