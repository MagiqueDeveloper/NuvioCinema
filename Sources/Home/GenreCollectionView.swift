import SwiftUI

struct GenrePagination {
    private let pageSize = 50
    private(set) var offsets: [CinemetaKind: Int] = [.movie: 0, .series: 0]
    private(set) var failures: Set<CinemetaKind> = []
    private var seenPages: [CinemetaKind: Set<Set<String>>] = [:]

    var automaticOffsets: [CinemetaKind: Int] { offsets.filter { !failures.contains($0.key) } }
    var retryOffsets: [CinemetaKind: Int] { offsets.filter { failures.contains($0.key) } }

    mutating func receive(_ ids: Set<String>?, kind: CinemetaKind, skip: Int) {
        guard offsets[kind] == skip else { return }
        guard let ids else {
            failures.insert(kind)
            return
        }
        failures.remove(kind)
        let isNewPage = !ids.isEmpty && seenPages[kind, default: []].insert(ids).inserted
        offsets[kind] = isNewPage ? skip + pageSize : nil
    }
}

/// The hero and themed rows of a genre page, derived from the genre's first page of popular titles.
struct GenrePageSections {
    static let heroLimit = 5
    static let shelfLimit = 16
    static let minimumShelfCount = 4
    static let acclaimedRating = 7.5

    var hero: [CinemetaSearchResult] = []
    var movies: [CinemetaSearchResult] = []
    var series: [CinemetaSearchResult] = []
    var acclaimed: [CinemetaSearchResult] = []
    var recent: [CinemetaSearchResult] = []

    var isEmpty: Bool { hero.isEmpty && movies.isEmpty && series.isEmpty }

    static func make(movies: [CinemetaSearchResult], series: [CinemetaSearchResult], currentYear: Int) -> Self {
        var seen = Set<CinemetaSearchResult.ID>()
        let mixed = (0..<max(movies.count, series.count)).flatMap { index in
            [movies, series].compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }.filter { seen.insert($0.id).inserted }

        var sections = Self()
        sections.hero = Array(mixed.lazy.filter { $0.title.background != nil && $0.title.logo != nil }.prefix(heroLimit))
        sections.movies = Array(movies.prefix(shelfLimit))
        sections.series = Array(series.prefix(shelfLimit))

        sections.acclaimed = shelf(ranked(mixed) { entry -> Double? in
            guard let rating = entry.title.imdbRating, rating >= acclaimedRating else { return nil }
            return rating
        })
        sections.recent = shelf(ranked(mixed) { entry -> Double? in
            guard let year = entry.title.releaseYear.flatMap(Int.init),
                  year >= currentYear - 1, year <= currentYear else { return nil }
            return Double(year)
        })
        return sections
    }

    /// Entries with a score, highest first; ties keep their popularity order.
    private static func ranked(_ entries: [CinemetaSearchResult],
                               by score: (CinemetaSearchResult) -> Double?) -> [CinemetaSearchResult] {
        var scored: [(order: Int, score: Double, entry: CinemetaSearchResult)] = []
        for (order, entry) in entries.enumerated() {
            if let value = score(entry) { scored.append((order, value, entry)) }
        }
        scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return scored.map(\.entry)
    }

    private static func shelf(_ entries: [CinemetaSearchResult]) -> [CinemetaSearchResult] {
        entries.count >= minimumShelfCount ? Array(entries.prefix(shelfLimit)) : []
    }
}

struct GenreCollectionView: View {
    let genre: HomeGenre
    let preview: [CinemetaSearchResult]
    let onDismiss: () -> Void

    @Environment(CinemaTitleNavigation.self) private var titles
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var focusScope
    @FocusState private var focus: HomeFocusTarget?
    @State private var entries: [CinemetaSearchResult]
    @State private var firstPage: [CinemetaKind: [CinemetaSearchResult]] = [:]
    @State private var pagination = GenrePagination()
    @State private var request: LoadRequest? = LoadRequest(offsets: GenrePagination().automaticOffsets)
    @State private var isNearEnd = false
    @State private var postLoadFocus: HomeFocusTarget?
    @State private var restoreTarget: HomeFocusTarget?
    @State private var requestedInitialFocus = false
    @State private var carousel = HeroCarousel()
    @State private var heroScroll = HomeHeroScroll()
    @State private var verticalPosition = ScrollPosition()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let preloadDistance: CGFloat = 450
    private static let columnCount = 6
    private static let posterSpacing: CGFloat = 30
    private static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: posterSpacing), count: columnCount)
    private static let sectionGap: CGFloat = 22
    private static let heroControlsHeight: CGFloat = 112

    private struct ScrollEdge: Equatable {
        let contentHeight: CGFloat
        let isNearEnd: Bool
    }

    private struct LoadRequest: Identifiable {
        let id = UUID()
        let offsets: [CinemetaKind: Int]
    }

    private var isActive: Bool { titles.screens.count == 1 }
    private var failures: Set<CinemetaKind> { pagination.failures }
    private var allShelf: HomeCollection.ID { .genreAll(genre) }

    init(genre: HomeGenre, preview: [CinemetaSearchResult] = [], onDismiss: @escaping () -> Void) {
        self.genre = genre
        self.preview = preview
        self.onDismiss = onDismiss
        var seen = Set<CinemetaSearchResult.ID>()
        _entries = State(initialValue: preview.filter { seen.insert($0.id).inserted })
    }

    private var sections: GenrePageSections {
        // Home's preview fills the page until the genre's own first page arrives.
        let movies = firstPage[.movie] ?? preview.filter { $0.kind == .movie }
        let series = firstPage[.series] ?? preview.filter { $0.kind == .series }
        return GenrePageSections.make(movies: movies, series: series,
                                      currentYear: Calendar.current.component(.year, from: .now))
    }

    var body: some View {
        GeometryReader { safeViewport in
            let leadingInset = max(safeViewport.safeAreaInsets.leading, safeViewport.frame(in: .global).minX)
            let topInset = max(safeViewport.safeAreaInsets.top, safeViewport.frame(in: .global).minY)
            GeometryReader { viewport in
                content(in: viewport, leadingInset: leadingInset, topInset: topInset)
            }
            .ignoresSafeArea()
        }
        .background {
            ZStack {
                CinemaStyle.background.ignoresSafeArea()
                HomeHeroBackdrop(carousel: carousel, heroScroll: heroScroll)
            }
        }
        .onChange(of: sections.hero.map(\.id), initial: true) { _, _ in applyHero() }
        .onChange(of: carousel.slide == nil) { _, settled in
            if settled { applyHero() }
        }
        .onChange(of: focus) { _, _ in applyHero() }
        .onExitCommand(perform: isActive ? onDismiss : nil)
        .task(id: request?.id) {
            if let request { await load(request) }
        }
    }

    private func content(in viewport: GeometryProxy, leadingInset: CGFloat, topInset: CGFloat) -> some View {
        let entries = entries
        let sections = sections
        let isLoading = request != nil
        let shelves = HomeShelfViewport(width: viewport.size.width, leadingInset: leadingInset)
        let collections = collections(for: sections)
        // Size the hero like Home's: the first row's heading and a sliver of its cards peek below it.
        let hasHero = !carousel.entries.isEmpty
        let firstStyle = collections.first.map { HomeShelfStyle(shelf: $0.id) } ?? .poster
        let heroHeight = hasHero
            ? max(0, viewport.size.height - Self.sectionGap - HomeShelfLayout.headingHeight
                  - shelves.layout(firstStyle).cardHeight / 4)
            : 0
        let shelfOffset = max(0, heroHeight - Self.heroControlsHeight)
        let artworkBottom = hasHero ? viewport.frame(in: .global).minY + heroHeight + Self.sectionGap / 2 : nil
        let restoresShelf = isActive && restoreTarget?.isPoster == true && shelfOffset > 0

        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionGap) {
                    if hasHero {
                        FeaturedHero(
                            height: heroHeight,
                            isActive: isActive,
                            carousel: $carousel,
                            focus: $focus,
                            focusScope: focusScope,
                            prefersFocus: preferredFocus == .hero,
                            onSelect: { showDetails($0, from: .hero) }
                        )
                        .overlay(alignment: .topLeading) { heroTitle(topInset: topInset) }
                        .padding(.leading, leadingInset)
                    } else {
                        heading(leadingInset: leadingInset)
                    }

                    if !collections.isEmpty {
                        CatalogShelves(
                            collections: collections,
                            shelfOrder: collections.map(\.id),
                            genrePreviews: [:],
                            continueWatching: [],
                            viewport: shelves,
                            focus: $focus,
                            focusScope: focusScope,
                            returnFocus: restoreTarget,
                            isRestoringFocus: isActive && restoreTarget != nil,
                            onSelect: { item, shelf in
                                if case .title(let entry) = item { showDetails(entry, from: .poster(shelf, item.id)) }
                            },
                            onWatchAction: { _, _ in }
                        )
                    } else if isLoading {
                        HomeShelfSkeleton(viewport: shelves)
                    }

                    VStack(alignment: .leading, spacing: HomeShelfLayout.headingGap) {
                        Text(allShelf.title)
                            .font(.system(size: 34, weight: .semibold))
                            .frame(height: HomeShelfLayout.headingTextHeight)
                            .accessibilityAddTraits(.isHeader)
                        grid(entries, isLoading: isLoading)
                        status(hasResults: !entries.isEmpty, isLoading: isLoading)
                    }
                    .padding(.leading, leadingInset + 14)
                    .padding(.trailing, 64)
                    .padding(.top, 12)
                }
                .padding(.bottom, 80)
            }
            .scrollPosition($verticalPosition)
            .scrollTargetBehavior(HomeHeroScrollBehavior(restoredShelfOffset: restoresShelf ? shelfOffset : nil))
            .scrollIndicators(.hidden)
            .onChange(of: focus) { previous, current in
                // Snap between the hero and the rows like Home, instead of scrolling the hero part-way.
                guard isActive, restoreTarget == nil, shelfOffset > 0, let current else { return }
                let distance = heroScroll.position.distance
                let isHero = current == .hero || current == .nextFeatured
                if isHero, previous?.isPoster != false, distance > 1 {
                    scrollPage(to: 0)
                } else if current.isPoster, previous?.isPoster != true, distance < shelfOffset - 1 {
                    scrollPage(to: shelfOffset)
                }
            }
            .onScrollGeometryChange(for: HomeHeroScrollPosition.self) { geometry in
                HomeHeroScrollPosition(
                    distance: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                    shelfOffset: shelfOffset,
                    artworkBottom: artworkBottom
                )
            } action: { _, position in
                heroScroll.update { heroScroll.position = position }
            }
            .focusScope(focusScope)
            .defaultFocus($focus, preferredFocus)
            .task {
                guard isActive, !requestedInitialFocus else { return }
                requestedInitialFocus = true
                focus = preferredFocus
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
                guard !Task.isCancelled, isActive, focus == nil, restoreTarget == nil, postLoadFocus == nil else { return }
                resetFocus(in: focusScope)
                focus = preferredFocus
            }
            .onScrollGeometryChange(for: ScrollEdge.self) { geometry in
                let bottom = geometry.contentSize.height + geometry.contentInsets.bottom
                return ScrollEdge(contentHeight: geometry.contentSize.height,
                                  isNearEnd: bottom - geometry.visibleRect.maxY <= preloadDistance)
            } action: { _, edge in
                isNearEnd = edge.isNearEnd
                loadMoreIfNeeded()
            }
            .onChange(of: isActive) { _, active in
                if active { loadMoreIfNeeded() }
            }
            .task(id: isActive ? postLoadFocus : nil) {
                guard isActive, restoreTarget == nil, let target = postLoadFocus else { return }
                // Retry may be below the last populated row.
                if focus == .retry, case let .poster(_, id) = target { scroll.scrollTo(gridID(id)) }
                await Task.yield()
                guard !Task.isCancelled, isActive, restoreTarget == nil, postLoadFocus == target else { return }
                if focus == nil || focus == .loading || focus == .retry || (focus == .hero && target != .hero) {
                    focus = target
                }
                postLoadFocus = nil
                loadMoreIfNeeded()
            }
            .task(id: isActive ? restoreTarget : nil) {
                guard isActive, let target = restoreTarget else { return }
                if case let .poster(shelf, id) = target, shelf == allShelf { scroll.scrollTo(gridID(id)) }
                do {
                    try await Task.sleep(for: .milliseconds(45))
                    guard isActive, restoreTarget == target else { return }
                    if focus != target {
                        resetFocus(in: focusScope)
                        focus = target
                    }
                    try await Task.sleep(for: .milliseconds(150))
                    guard restoreTarget == target else { return }
                    restoreTarget = nil
                    loadMoreIfNeeded()
                } catch {
                    // A new navigation action supersedes this focus restoration.
                }
            }
        }
    }

    private func scrollPage(to offset: CGFloat) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.42)) {
            verticalPosition.scrollTo(y: offset)
        }
    }

    private func applyHero() {
        // Don't swap titles mid-transition or out from under a focused hero.
        let entries = sections.hero
        guard carousel.slide == nil, entries.map(\.id) != carousel.entries.map(\.id) else { return }
        let isHeroFocused = focus == .hero || focus == .nextFeatured
        if isHeroFocused, let current = carousel.entry, !entries.contains(where: { $0.id == current.id }) { return }
        if focus == .nextFeatured, entries.count < 2 { return }
        let urls = Set(entries.flatMap { [$0.title.background, $0.title.logo].compactMap { $0 } })
        carousel = HeroCarousel(entries: entries,
                                index: entries.firstIndex { $0.id == carousel.entry?.id } ?? 0,
                                artwork: carousel.artwork.filter { urls.contains($0.key) })
    }

    private func collections(for sections: GenrePageSections) -> [HomeCollection] {
        [
            (HomeCollection.ID.genrePopularMovies(genre), sections.movies),
            (.genrePopularSeries(genre), sections.series),
            (.genreAcclaimed(genre), sections.acclaimed),
            (.genreRecent(genre), sections.recent),
        ].compactMap { id, entries in
            entries.isEmpty ? nil : HomeCollection(id: id, entries: entries, hasFailure: false)
        }
    }

    private var preferredFocus: HomeFocusTarget {
        if let restoreTarget { return restoreTarget }
        if let postLoadFocus { return postLoadFocus }
        if !carousel.entries.isEmpty || !sections.hero.isEmpty { return .hero }
        if let first = entries.first { return .poster(allShelf, first.id) }
        return request == nil && !failures.isEmpty ? .retry : .loading
    }

    private func gridID(_ id: CinemetaSearchResult.ID) -> String { "all-\(id)" }

    /// The genre name, pinned to the hero's top-left corner like a streaming app's category page.
    private func heroTitle(topInset: CGFloat) -> some View {
        Text(genre.name)
            .font(.system(size: 52, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 14, y: 3)
            .lineLimit(1)
            .padding(.leading, 14)
            .padding(.top, max(topInset, 40) + 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func heading(leadingInset: CGFloat) -> some View {
        Text(genre.name)
            .font(.system(size: 76, weight: .bold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leadingInset + 14)
            .padding(.top, 90)
            .padding(.bottom, 14)
    }

    private func grid(_ entries: [CinemetaSearchResult], isLoading: Bool) -> some View {
        let names = CinemetaSearchResult.disambiguatedNames(for: entries)
        return LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: Self.posterSpacing + 8) {
            ForEach(entries) { entry in
                let target = HomeFocusTarget.poster(allShelf, entry.id)
                Button {
                    showDetails(entry, from: target)
                } label: {
                    let shape = RoundedRectangle(cornerRadius: 14)
                    Color(white: 0.09)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            CatalogArtwork(url: BetterPosters.url(for: entry.title.imdbID, showTrendTags: false),
                                           fallbackURL: entry.title.poster, isPoster: true)
                        }
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                        .contentShape(.hoverEffect, shape)
                        .hoverEffect(.lift)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(names[entry.id] ?? entry.title.name)
                .focused($focus, equals: target)
                .prefersDefaultFocus(restoreTarget == target || postLoadFocus == target, in: focusScope)
                .id(gridID(entry.id))
            }

            if isLoading {
                let emptySlots = Self.columnCount - entries.count % Self.columnCount
                ForEach(0..<emptySlots, id: \.self) { index in
                    let placeholder = RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.055))
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    if entries.isEmpty && failures.isEmpty && index == 0 {
                        placeholder
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focus, equals: .loading)
                            .accessibilityLabel("Loading titles")
                    } else {
                        placeholder.accessibilityHidden(true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func status(hasResults: Bool, isLoading: Bool) -> some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !isLoading {
                    Text(hasResults ? "Couldn’t Load More Titles" : "Couldn’t Load Titles")
                        .font(.title3)
                }
                Button {
                    guard isActive, !isLoading else { return }
                    request = LoadRequest(offsets: pagination.retryOffsets)
                } label: {
                    if isLoading {
                        Text("Loading Titles…")
                    } else {
                        Text("Try Again")
                    }
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .retry)
            }
        } else if !hasResults && !isLoading {
            Text("No Titles Available")
                .font(.title3)
                .foregroundStyle(.secondary)
                .focusable()
                .focusEffectDisabled()
                .focused($focus, equals: .loading)
        }
    }

    private func loadMoreIfNeeded() {
        let offsets = pagination.automaticOffsets
        guard isActive, isNearEnd, postLoadFocus == nil, restoreTarget == nil,
              request == nil, !offsets.isEmpty else { return }
        request = LoadRequest(offsets: offsets)
    }

    private func load(_ request: LoadRequest) async {
        let client = CinemetaClient()
        let responses = await withTaskGroup(of: (CinemetaKind, [CinemetaTitle]?).self) { group in
            for (kind, skip) in request.offsets {
                group.addTask { (kind, await client.loadGenre(genre, kind: kind, skip: skip)) }
            }
            var responses: [(CinemetaKind, [CinemetaTitle]?)] = []
            for await response in group { responses.append(response) }
            return responses
        }
        guard !Task.isCancelled, self.request?.id == request.id else { return }
        let wasEmpty = entries.isEmpty
        var batch: [CinemetaKind: [CinemetaSearchResult]] = [:]
        for (kind, response) in responses {
            guard let skip = request.offsets[kind] else { continue }
            let page = response?.map { CinemetaSearchResult(title: $0, kind: kind) }
            pagination.receive(page.map { Set($0.map(\.id)) }, kind: kind, skip: skip)
            batch[kind] = page
            if skip == 0, let page, firstPage[kind] == nil { firstPage[kind] = page }
        }
        let movies = batch[.movie] ?? []
        let shows = batch[.series] ?? []
        var visibleIDs = Set(entries.map(\.id))
        let appended = (0..<max(movies.count, shows.count)).flatMap { index in
            [movies, shows].compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }.filter { visibleIDs.insert($0.id).inserted }
        entries += appended
        if isActive {
            if focus == .retry, failures.isEmpty {
                postLoadFocus = (appended.first ?? entries.last).map { .poster(allShelf, $0.id) } ?? .loading
            } else if wasEmpty, focus == nil || focus == .loading {
                postLoadFocus = !sections.hero.isEmpty ? .hero
                    : entries.first.map { .poster(allShelf, $0.id) } ?? (failures.isEmpty ? .loading : .retry)
            }
        }
        self.request = nil
        // A short page may only fill the existing last grid row.
        if appended.count < Self.columnCount { loadMoreIfNeeded() }
    }

    private func showDetails(_ entry: CinemetaSearchResult, from origin: HomeFocusTarget) {
        guard isActive else { return }
        postLoadFocus = nil
        restoreTarget = nil
        titles.show(onDismiss: { restoreTarget = origin }) { close in
            TitleDetailsView(title: entry.title, kind: entry.kind, onDismiss: close)
        }
    }
}
