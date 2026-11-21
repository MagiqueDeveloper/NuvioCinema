import SwiftUI

enum HomeShelfStyle: Equatable {
    case poster, backdrop, editorial, genres

    init(shelf: HomeCollection.ID) {
        switch shelf {
        case .watching: self = .editorial
        case .continueWatching, .today, .newSeries, .popularSeries: self = .backdrop
        case .newReleases, .topRated, .popularMovies: self = .poster
        case .genres: self = .genres
        case .genrePopularMovies, .genreRecent, .genreAll: self = .poster
        case .genrePopularSeries: self = .backdrop
        case .genreAcclaimed: self = .editorial
        case .genre(let genre):
            switch genre {
            case .adventure, .documentary, .fantasy, .scienceFiction: self = .editorial
            case .action, .comedy, .crime, .family, .mystery, .thriller: self = .backdrop
            default: self = .poster
            }
        }
    }
}

struct HomeShelfViewport {
    let width: CGFloat
    let leadingInset: CGFloat

    func layout(_ style: HomeShelfStyle) -> HomeShelfLayout {
        HomeShelfLayout(viewportWidth: width, leadingInset: leadingInset, style: style)
    }
}

struct HomeShelfLayout {
    static let headingTextHeight: CGFloat = 42
    static let headingGap: CGFloat = 20
    static let headingHeight = headingTextHeight + headingGap
    private static let landscapeHeightRatio: CGFloat = 5.0 / 8.0

    let cardsPerRow: Int
    let viewportWidth: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let leadingInset: CGFloat
    let inset: CGFloat
    let spacing: CGFloat

    var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }
    var previewWidth: CGFloat { cardWidth / 6 }
    var pitch: CGFloat { cardWidth + spacing }
    var centeredInset: CGFloat { (viewportWidth - (CGFloat(cardsPerRow) * pitch - spacing)) / 2 }

    init(viewportWidth: CGFloat, leadingInset: CGFloat, style: HomeShelfStyle) {
        self.viewportWidth = viewportWidth
        self.leadingInset = leadingInset
        let heightRatio: CGFloat
        switch style {
        case .poster:
            (cardsPerRow, inset, spacing, heightRatio) = (6, 14, 30, 1.5)
        case .backdrop:
            (cardsPerRow, inset, spacing, heightRatio) = (4, 34, 44, Self.landscapeHeightRatio)
        case .editorial:
            (cardsPerRow, inset, spacing, heightRatio) = (3, 34, 44, Self.landscapeHeightRatio)
        case .genres:
            (cardsPerRow, inset, spacing, heightRatio) = (5, 24, 36, 0.49)
        }
        let gaps = CGFloat(cardsPerRow) * spacing
        cardWidth = max(1, (viewportWidth - leadingInset - inset - gaps) / (CGFloat(cardsPerRow) + 1.0 / 6.0))
        cardHeight = cardWidth * heightRatio
    }
}

struct HomeLoadingSkeleton: View {
    let heroHeight: CGFloat
    let gap: CGFloat
    let viewport: HomeShelfViewport

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            VStack(alignment: .leading, spacing: 16) {
                block(width: 360, height: 72)
                block(width: 256, height: 20)
                block(width: 516, height: 19)
                block(width: 414, height: 19)
                Capsule()
                    .fill(.white.opacity(0.09))
                    .frame(width: 240, height: 62)
                    .padding(.top, 8)
            }
            .padding(.leading, viewport.leadingInset + 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: heroHeight, alignment: .bottomLeading)
            .background {
                LinearGradient(colors: [Color(white: 0.15), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
            .clipped()

            HomeShelfSkeleton(viewport: viewport)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Home")
    }

    private func block(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(.white.opacity(0.09))
            .frame(width: width, height: height)
    }
}

struct HomeShelfSkeleton: View {
    let viewport: HomeShelfViewport

    private let placeholder = Color.white.opacity(0.09)

    var body: some View {
        let shelf = viewport.layout(.editorial)

        VStack(alignment: .leading, spacing: HomeShelfLayout.headingGap) {
            RoundedRectangle(cornerRadius: 7)
                .fill(placeholder)
                .frame(width: 285, height: 27)
                .frame(height: HomeShelfLayout.headingTextHeight)

            HStack(spacing: shelf.spacing) {
                ForEach(0..<(shelf.cardsPerRow + 1), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(placeholder)
                        .frame(width: shelf.cardWidth, height: shelf.cardHeight)
                }
            }
        }
        .padding(.leading, shelf.leadingInset + shelf.inset)
        .frame(width: viewport.width, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading collections")
    }
}

enum HomeShelfItem: Identifiable {
    case title(CinemetaSearchResult)
    case watching(CinemaContinueWatchingItem)
    case genre(HomeGenre, preview: [CinemetaSearchResult])

    var id: String {
        switch self {
        case .title(let entry): entry.id
        case .watching(let item): item.id
        case .genre(let genre, _): genre.rawValue
        }
    }
}

enum ContinueWatchingAction {
    case restart, markWatched, remove
}

private struct ContinueWatchingMenu: View {
    let isUpcoming: Bool
    let onAction: (ContinueWatchingAction) -> Void

    var body: some View {
        if !isUpcoming {
            Button {
                perform(.restart)
            } label: {
                Label("Play from Beginning", systemImage: "backward.end")
            }
            Button {
                perform(.markWatched)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
        Button(role: .destructive) {
            perform(.remove)
        } label: {
            Label("Remove from Continue Watching", systemImage: "minus.circle")
        }
    }

    private func perform(_ action: ContinueWatchingAction) {
        // tvOS invokes the action while dismissing the native menu. Let it release the card first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onAction(action)
        }
    }
}

struct CatalogShelves: View {
    let collections: [HomeCollection]
    let shelfOrder: [HomeCollection.ID]
    let genrePreviews: [HomeGenre: [CinemetaSearchResult]]
    let continueWatching: [CinemaContinueWatchingItem]
    let viewport: HomeShelfViewport
    let focus: FocusState<HomeFocusTarget?>.Binding
    let focusScope: Namespace.ID
    let returnFocus: HomeFocusTarget?
    let isRestoringFocus: Bool
    let onSelect: (HomeShelfItem, HomeCollection.ID) -> Void
    let onWatchAction: (ContinueWatchingAction, CinemaContinueWatchingItem) -> Void

    var body: some View {
        let collectionsByID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        LazyVStack(alignment: .leading, spacing: 32) {
            if !continueWatching.isEmpty {
                shelf(.continueWatching, items: continueWatching.map(HomeShelfItem.watching))
            }
            ForEach(shelfOrder, id: \.self) { id in
                if id == .genres {
                    let genres = HomeGenre.allCases.map { HomeShelfItem.genre($0, preview: genrePreviews[$0] ?? []) }
                    shelf(id, items: genres)
                } else if let collection = collectionsByID[id] {
                    shelf(id, items: collection.entries.map(HomeShelfItem.title))
                }
            }
        }
    }

    private func shelf(_ id: HomeCollection.ID, items: [HomeShelfItem]) -> some View {
        let style = HomeShelfStyle(shelf: id)
        return CatalogShelf(shelf: id, items: items, style: style, layout: viewport.layout(style), focus: focus,
                            focusScope: focusScope, returnFocus: returnFocus, isRestoringFocus: isRestoringFocus,
                            onSelect: onSelect, onWatchAction: onWatchAction)
    }
}

private struct CatalogShelf: View {
    let shelf: HomeCollection.ID
    let items: [HomeShelfItem]
    let style: HomeShelfStyle
    let layout: HomeShelfLayout
    let focus: FocusState<HomeFocusTarget?>.Binding
    let focusScope: Namespace.ID
    let returnFocus: HomeFocusTarget?
    let isRestoringFocus: Bool
    let onSelect: (HomeShelfItem, HomeCollection.ID) -> Void
    let onWatchAction: (ContinueWatchingAction, CinemaContinueWatchingItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstVisibleIndex = 0

    private var returnItemID: String? {
        guard case let .poster(returnShelf, id)? = returnFocus, returnShelf == shelf else { return nil }
        return id
    }

    var body: some View {
        let heading = Text(shelf.title)

        VStack(alignment: .leading, spacing: HomeShelfLayout.headingGap) {
            heading
                .font(.system(size: 34, weight: .semibold))
                .frame(height: HomeShelfLayout.headingTextHeight)
                .padding(.leading, layout.leadingInset + layout.inset)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(
                    shelf == .today && items.count == 10
                        ? Text("Popular Today. Top five movies and top five series.")
                        : heading
                )

            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let rank = shelf == .today ? index + 1 : nil
                            cardButton(for: item, rank: rank)
                                .padding(.leading, layout.inset + (index == 0 ? layout.leadingInset : 0))
                                .padding(.trailing, layout.spacing - layout.inset)
                                .id(item.id)
                        }
                    }
                    .padding(.trailing, items.count > layout.cardsPerRow
                             ? max(layout.inset + layout.previewWidth, layout.centeredInset - (layout.spacing - layout.inset))
                             : 0)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .frame(height: layout.cardHeight)
                // Clip at the horizontal viewport edge, with room for the native focus lift.
                .padding(.vertical, 34)
                .clipped()
                .padding(.vertical, -34)
                .buttonStyle(.borderless)
                .onChange(of: isRestoringFocus ? returnItemID : nil, initial: true) { _, id in
                    guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
                    firstVisibleIndex = leadingIndex(for: index)
                    scrollTo(firstVisibleIndex, using: scroll)
                }
                .onChange(of: focus.wrappedValue) { _, next in
                    guard case let .poster(focusedShelf, id)? = next, focusedShelf == shelf,
                          let index = items.firstIndex(where: { $0.id == id }) else { return }
                    let firstIndex = leadingIndex(for: index)
                    guard firstIndex != firstVisibleIndex else { return }
                    firstVisibleIndex = firstIndex
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) {
                        scrollTo(firstIndex, using: scroll)
                    }
                }
                .onChange(of: items.map(\.id)) { _, ids in
                    let lastLeadingIndex = max(0, ids.count - layout.cardsPerRow)
                    guard firstVisibleIndex > lastLeadingIndex else { return }
                    firstVisibleIndex = lastLeadingIndex
                    if ids.indices.contains(firstVisibleIndex) {
                        scrollTo(firstVisibleIndex, using: scroll)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    @ViewBuilder
    private func cardButton(for item: HomeShelfItem, rank: Int?) -> some View {
        switch item {
        case .watching(let watching):
            ContinueWatchingButton(item: watching, size: layout.cardSize,
                                   onSelect: { onSelect(item, shelf) }, onAction: { onWatchAction($0, watching) })
                .focused(focus, equals: .poster(shelf, item.id))
                .prefersDefaultFocus(item.id == returnItemID, in: focusScope)
        case .genre(let genre, let preview):
            discoveryButton(for: item, label: Text(genre.name)) {
                GenreCard(genre: genre, artwork: preview.lazy.compactMap(\.title.background).first, size: layout.cardSize)
            }
        case .title(let entry):
            let label = rank.map { Text("Rank \($0), \(entry.title.name)") } ?? Text(entry.title.name)
            discoveryButton(for: item, label: label) {
                if style == .poster {
                    TitleCard(title: entry.title, size: layout.cardSize)
                } else {
                    BackdropCard(entry: entry, size: layout.cardSize, isEditorial: style == .editorial, rank: rank)
                }
            }
        }
    }

    private func discoveryButton<Content: View>(for item: HomeShelfItem, label: Text,
                                                @ViewBuilder content: () -> Content) -> some View {
        Button(action: { onSelect(item, shelf) }, label: content)
            .focused(focus, equals: .poster(shelf, item.id))
            .prefersDefaultFocus(item.id == returnItemID, in: focusScope)
            .accessibilityLabel(label)
    }

    private func leadingIndex(for index: Int) -> Int {
        min(index, max(firstVisibleIndex, index - layout.cardsPerRow + 1))
    }

    private func scrollTo(_ firstIndex: Int, using scroll: ScrollViewProxy) {
        if firstIndex == 0 {
            scroll.scrollTo(items[firstIndex].id, anchor: .leading)
        } else {
            let anchorX = max(0, layout.centeredInset - layout.inset) / max(1, layout.viewportWidth - layout.pitch)
            scroll.scrollTo(items[firstIndex].id, anchor: UnitPoint(x: anchorX, y: 0.5))
        }
    }

}

private struct TitleCard: View {
    let title: CinemetaTitle
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)

        CatalogArtwork(url: BetterPosters.url(for: title.imdbID, showTrendTags: false),
                       fallbackURL: title.poster, isPoster: true)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            .accessibilityHidden(true)
    }
}

private struct BackdropCard: View {
    let entry: CinemetaSearchResult
    let size: CGSize
    let isEditorial: Bool
    let rank: Int?

    private var title: CinemetaTitle { entry.title }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)

        ZStack(alignment: .bottomLeading) {
            HomeLandscapeArtwork(title: title, kind: entry.kind, size: size)
            LinearGradient(
                stops: [.init(color: .clear, location: 0.38), .init(color: .black.opacity(0.88), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            caption
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if let rank {
                Text(rank.formatted())
                    .font(.system(size: 61, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 12, x: 1, y: 3)
                    .padding(.horizontal, 21)
                    .padding(.top, 10)
            }
        }
        .foregroundStyle(.white)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.lift)
        .accessibilityHidden(true)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 7) {
            LandscapeTitle(title: title, fontSize: isEditorial ? 39 : 32)
                .frame(width: size.width * 0.65, height: size.height * 0.33, alignment: .bottomLeading)

            if isEditorial {
                Text(metadata)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(isEditorial ? 26 : 20)
    }

    private var metadata: String {
        let kind = entry.kind == .movie ? String(localized: "Movie") : String(localized: "TV Show")
        return [kind, title.genres?.first, title.releaseYear].compactMap { $0 }.joined(separator: "  ·  ")
    }
}

private struct LandscapeTitle: View {
    let title: CinemetaTitle
    let fontSize: CGFloat

    var body: some View {
        CachedArtwork(url: title.logo) { phase in
            if let logo = phase.image {
                logo.resizable().scaledToFit()
            } else {
                Text(title.name)
                    .font(.system(size: fontSize, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .shadow(color: .black.opacity(0.85), radius: 7, y: 3)
    }
}

private struct HomeLandscapeArtwork: View {
    let title: CinemetaTitle
    let kind: CinemetaKind
    let size: CGSize

    private var alternateBackdrop: URL? {
        title.imdbID.flatMap { URL(string: "https://images.metahub.space/background/medium/\($0)/img") }
    }

    var body: some View {
        let alternate = alternateBackdrop
        let primary = title.background ?? alternate
        let fallback = alternate == primary ? nil : alternate

        CachedArtwork(url: primary) { phase in
            // Keep a rendered view behind the image so the download task can start.
            ZStack {
                placeholder
                if let image = phase.image {
                    backdrop(image)
                } else {
                    let failed = primary == nil || phase.error != nil
                    CachedArtwork(url: failed ? fallback : nil) { alternatePhase in
                        if let image = alternatePhase.image {
                            backdrop(image)
                        } else {
                            let canLoadPoster = failed && (fallback == nil || alternatePhase.error != nil)
                            poster(showFallbackIcon: failed, loadIfNeeded: canLoadPoster)
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.10, blue: 0.15), Color(red: 0.21, green: 0.25, blue: 0.32)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    private func poster(showFallbackIcon: Bool, loadIfNeeded: Bool) -> some View {
        let preferred = BetterPosters.url(for: title.imdbID, showTrendTags: false)
        let primaryPoster = title.poster ?? preferred
        let fallbackPoster = primaryPoster == preferred ? nil : preferred
        let cachedPoster = [primaryPoster, fallbackPoster].lazy.compactMap { $0 }
            .compactMap { CinemaImageCache.cached($0) }.first
            .map { Image(decorative: $0, scale: 1) }

        return ZStack(alignment: .trailing) {
            if showFallbackIcon {
                Image(systemName: kind == .movie ? "film" : "tv")
                    .font(.system(size: size.height * 0.41, weight: .light))
                    .foregroundStyle(.white.opacity(0.20))
                    .frame(width: size.width * 0.43, height: size.height)
            }
            CachedArtwork(url: loadIfNeeded ? primaryPoster : nil) { phase in
                if let image = phase.image {
                    posterImage(image)
                } else {
                    CachedArtwork(url: loadIfNeeded && phase.error != nil ? fallbackPoster : nil) { fallbackPhase in
                        if let image = fallbackPhase.image ?? cachedPoster {
                            posterImage(image)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .frame(width: size.height * 0.86, height: size.height)
            .mask {
                LinearGradient(colors: [.clear, .white], startPoint: .leading,
                               endPoint: UnitPoint(x: 0.34, y: 0.5))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .trailing)
    }

    private func posterImage(_ image: Image) -> some View {
        image.resizable()
            .scaledToFill()
            .frame(width: size.height * 0.86, height: size.height, alignment: .top)
            .clipped()
    }

    private func backdrop(_ image: Image) -> some View {
        image.resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

private struct GenreCard: View {
    let genre: HomeGenre
    let artwork: URL?
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        let design = design(for: genre)

        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [design.color, design.color.opacity(0.45)], startPoint: .topTrailing, endPoint: .bottomLeading)
                .background(Color(white: 0.08))

            CachedArtwork(url: artwork) { phase in
                if let image = phase.image {
                    image.resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(0.50)
                        .mask {
                            LinearGradient(colors: [.clear, .white], startPoint: .bottomLeading, endPoint: .topTrailing)
                        }
                } else {
                    Image(systemName: design.symbol)
                        .font(.system(size: size.height * 0.71, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.19))
                        .rotationEffect(.degrees(-12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(20)
                }
            }

            Text(genre.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .padding(21)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.21), lineWidth: 1) }
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.lift)
        .accessibilityHidden(true)
    }

    private func design(for genre: HomeGenre) -> (color: Color, symbol: String) {
        switch genre {
        case .action: (Color(red: 0.68, green: 0.25, blue: 0.13), "bolt.fill")
        case .adventure: (Color(red: 0.23, green: 0.43, blue: 0.28), "map.fill")
        case .animation: (Color(red: 0.57, green: 0.28, blue: 0.63), "paintpalette.fill")
        case .comedy: (Color(red: 0.67, green: 0.43, blue: 0.11), "face.smiling.fill")
        case .crime: (Color(red: 0.23, green: 0.33, blue: 0.43), "fingerprint")
        case .documentary: (Color(red: 0.16, green: 0.44, blue: 0.47), "globe.americas.fill")
        case .drama: (Color(red: 0.48, green: 0.23, blue: 0.36), "theatermasks.fill")
        case .family: (Color(red: 0.21, green: 0.48, blue: 0.38), "popcorn.fill")
        case .fantasy: (Color(red: 0.31, green: 0.23, blue: 0.59), "wand.and.stars")
        case .horror: (Color(red: 0.50, green: 0.17, blue: 0.20), "moon.stars.fill")
        case .mystery: (Color(red: 0.25, green: 0.35, blue: 0.51), "questionmark.circle.fill")
        case .romance: (Color(red: 0.61, green: 0.25, blue: 0.39), "heart.fill")
        case .scienceFiction: (Color(red: 0.19, green: 0.32, blue: 0.65), "sparkles")
        case .thriller: (Color(red: 0.32, green: 0.28, blue: 0.45), "eye.fill")
        }
    }
}

private struct ContinueWatchingButton: View {
    let item: CinemaContinueWatchingItem
    let size: CGSize
    let onSelect: () -> Void
    let onAction: (ContinueWatchingAction) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var reachedRelease: Date?

    var body: some View {
        let upcoming = item.upcomingEpisode()
        let release = upcoming?.releasedAt
        let isAwaitingRelease = release != nil && release != reachedRelease
        let pendingEpisode = isAwaitingRelease ? upcoming : nil

        Button(action: onSelect) {
            ContinueWatchingCard(item: item, upcoming: pendingEpisode, size: size)
        }
        .accessibilityLabel(ContinueWatchingCard.accessibilityLabel(for: item, upcoming: pendingEpisode))
        .contextMenu {
            ContinueWatchingMenu(isUpcoming: item.upcomingEpisode() != nil, onAction: onAction)
        }
        .task(id: scenePhase == .active ? release : nil) {
            guard scenePhase == .active, let release else { return }
            do {
                var remaining = release.timeIntervalSinceNow
                while remaining > 0 {
                    try await Task.sleep(for: .seconds(min(86_400, remaining)))
                    remaining = release.timeIntervalSinceNow
                }
                try Task.checkCancellation()
                reachedRelease = release
            } catch {
                // Replacing the selected episode also replaces its release date.
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let item: CinemaContinueWatchingItem
    let upcoming: CinemetaEpisode?
    let size: CGSize

    private var title: CinemetaTitle { item.entry.title }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)

        HomeLandscapeArtwork(title: title, kind: item.entry.kind, size: size)
        .overlay {
            RadialGradient(colors: [.black.opacity(0.40), .clear], center: .center,
                           startRadius: 0, endRadius: size.width * 0.46)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .clear, location: 0.52), .init(color: .black.opacity(0.90), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            LandscapeTitle(title: title, fontSize: 32)
                .multilineTextAlignment(.center)
                .frame(width: size.width * 0.62, height: size.height * 0.38)
        }
        .overlay(alignment: .bottomLeading) {
            cardStatus
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.19), lineWidth: 1) }
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.lift)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cardStatus: some View {
        if let upcoming, let coming = Self.comingStatus(for: upcoming) {
            let date = Text(coming).foregroundStyle(Color.cyan)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text("S\(upcoming.season), E\(upcoming.episode) ·")
                        .foregroundStyle(.white.opacity(0.8))
                    date
                }
                .fixedSize(horizontal: true, vertical: false)

                date.minimumScaleFactor(0.78)
            }
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
        } else {
            HStack(spacing: 12) {
                if NuvioAccount.hasStarted(item.progress), item.progress.duration > 0 {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 52 * item.progress.fraction)
                        }
                        .frame(width: 52, height: 5)
                }
                Text(Self.status(for: item))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }

    private static func comingStatus(for episode: CinemetaEpisode) -> String? {
        episode.releasedAt.map { release in
            let date = CinemetaEpisode.displayAirDate(release)
            return String(localized: "Coming \(date)")
        }
    }

    private static func remaining(for progress: NuvioProgress) -> String? {
        guard progress.duration > 0 else { return nil }
        let minutes = max(1, Int(ceil(Double(progress.duration - min(progress.position, progress.duration)) / 60_000)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    private static func status(for item: CinemaContinueWatchingItem) -> String {
        if !NuvioAccount.hasStarted(item.progress) {
            if item.entry.kind == .series, let season = item.progress.season, let episode = item.progress.episode {
                return String(localized: "Play S\(season), E\(episode)")
            }
            return String(localized: "Play")
        }
        let time = remaining(for: item.progress).map { String(localized: "\($0) left") }
        if item.entry.kind == .series, let season = item.progress.season, let episode = item.progress.episode {
            let label = String(localized: "S\(season), E\(episode)")
            return [label, time].compactMap { $0 }.joined(separator: " · ")
        }
        return time ?? String(localized: "In Progress")
    }

    static func accessibilityLabel(for item: CinemaContinueWatchingItem, upcoming: CinemetaEpisode?) -> String {
        var parts = [item.entry.title.name]
        if item.entry.kind == .series, let season = item.progress.season, let episode = item.progress.episode {
            parts.append(String(localized: "Season \(season), Episode \(episode)"))
            if let name = item.episode?.name { parts.append(name) }
        }
        if let upcoming, let coming = comingStatus(for: upcoming) {
            parts.append(coming)
        } else if !NuvioAccount.hasStarted(item.progress) {
            parts.append(String(localized: "Ready to play"))
        } else if let time = remaining(for: item.progress) {
            parts.append(String(localized: "\(time) left"))
            let percent = item.progress.fraction.formatted(.percent.precision(.fractionLength(0)))
            parts.append(String(localized: "\(percent) watched"))
        } else {
            parts.append(String(localized: "In Progress"))
        }
        return parts.joined(separator: ", ")
    }
}
