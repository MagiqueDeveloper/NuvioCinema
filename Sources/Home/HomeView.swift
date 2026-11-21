import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted by Settings to reload Home's catalogs without waiting for the hourly refresh.
    static let cinemaRefreshHome = Notification.Name("com.nuviocinema.refreshHome")
}

enum CinemaStyle {
    static let background = Color(white: 0.105)
}

enum HomeFocusTarget: Hashable {
    case hero, nextFeatured
    /// Genre page placeholders while titles load or after a failure.
    case loading, retry
    case poster(HomeCollection.ID, CinemetaSearchResult.ID)

    var isPoster: Bool {
        if case .poster = self { return true }
        return false
    }
}

struct HomeHeroScrollPosition: Equatable {
    var distance: CGFloat = 0
    var shelfOffset: CGFloat = 0
    var artworkBottom: CGFloat?

    var shelfProgress: CGFloat { min(1, distance / max(1, shelfOffset)) }
}

@Observable
final class HomeHeroScroll {
    var position = HomeHeroScrollPosition()

    func update(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

struct HomeHeroScrollBehavior: ScrollTargetBehavior {
    let restoredShelfOffset: CGFloat?

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard let restoredShelfOffset else { return }
        target.rect.origin.y = max(target.rect.minY, restoredShelfOffset)
    }
}

struct HeroCarousel {
    enum Artwork: Sendable {
        case image(CGImage)
        case unavailable

        nonisolated static func load(_ url: URL) async -> Self {
            let delays: [Duration] = [.zero, .seconds(1), .seconds(3)]
            for delay in delays {
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    return .image(try await CinemaImageCache.shared.image(for: url))
                } catch let error as URLError where error.code != .cancelled {
                    continue
                } catch CinemaImageError.response(let status) where status == 408 || (500..<600).contains(status) {
                    continue
                } catch CinemaImageError.throttled {
                    continue
                } catch {
                    return .unavailable
                }
            }
            return .unavailable
        }
    }

    struct BackdropSlice: Equatable {
        let index: Int
        let coverage: Range<Double>
        let horizontalOffset: Double
    }

    struct Banner {
        let index: Int
        let opacity: Double
    }

    struct Slide: Identifiable {

        private static let revealCurve = UnitCurve.bezier(
            startControlPoint: UnitPoint(x: 0.24, y: 0),
            endControlPoint: UnitPoint(x: 0.26, y: 1)
        )
        private static let slideCurve = UnitCurve.bezier(
            startControlPoint: UnitPoint(x: 0.32, y: 0),
            endControlPoint: UnitPoint(x: 0.48, y: 1)
        )
        private static let artworkTravel = 0.05

        let id = UUID()
        let outgoingArtwork: [BackdropSlice]
        let outgoingBanner: Banner
        let step: Int
        let start: ContinuousClock.Instant
        let isInterruption: Bool

        private var wipeDelay: Duration { isInterruption ? .zero : .milliseconds(75) }
        private var fadeOutDuration: Duration { isInterruption ? .milliseconds(45) : wipeDelay }
        private var wipeDuration: Duration { isInterruption ? .milliseconds(340) : .milliseconds(600) }
        private var fadeInDuration: Duration { isInterruption ? .milliseconds(95) : .milliseconds(175) }
        private var wipeEnd: Duration { wipeDelay + wipeDuration }
        var duration: Duration { wipeEnd + fadeInDuration }

        func banner(at now: ContinuousClock.Instant, entering index: Int) -> Banner {
            let elapsed = max(.zero, start.duration(to: now))
            if elapsed < wipeEnd {
                let fadeOut = Self.fraction(elapsed, of: fadeOutDuration)
                let opacity = outgoingBanner.opacity * (1 - UnitCurve.easeInOut.value(at: fadeOut))
                return Banner(index: outgoingBanner.index, opacity: opacity)
            }
            let fadeIn = Self.fraction(elapsed - wipeEnd, of: fadeInDuration)
            return Banner(index: index, opacity: Self.revealCurve.value(at: fadeIn))
        }

        func backdrop(at now: ContinuousClock.Instant, entering index: Int) -> [BackdropSlice] {
            let elapsed = start.duration(to: now) - wipeDelay
            let progress = Self.slideCurve.value(at: Self.fraction(elapsed, of: wipeDuration))
            let visible = step < 0 ? progress..<1 : 0..<(1 - progress)
            let travel = step < 0 ? -Self.artworkTravel : Self.artworkTravel
            let remaining = outgoingArtwork.compactMap { slice -> BackdropSlice? in
                let lower = max(slice.coverage.lowerBound, visible.lowerBound)
                let upper = min(slice.coverage.upperBound, visible.upperBound)
                guard lower < upper else { return nil }
                let offset = slice.horizontalOffset * (1 - progress) - travel * progress
                // The wipe hides the displaced edges, including when a slide is interrupted.
                return BackdropSlice(index: slice.index, coverage: lower..<upper,
                                     horizontalOffset: min(lower, max(upper - 1, offset)))
            }
            let incoming = step < 0 ? 0..<visible.lowerBound : visible.upperBound..<1
            guard !incoming.isEmpty else { return remaining }
            let slice = BackdropSlice(index: index, coverage: incoming, horizontalOffset: travel * (1 - progress))
            return step < 0 ? [slice] + remaining : remaining + [slice]
        }

        private static func fraction(_ elapsed: Duration, of duration: Duration) -> Double {
            min(1, max(0, elapsed / duration))
        }
    }

    var entries: [CinemetaSearchResult] = []
    var index = 0
    var slide: Slide?
    var artwork: [URL: Artwork] = [:]

    var entry: CinemetaSearchResult? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    func banner(at now: ContinuousClock.Instant) -> Banner {
        slide?.banner(at: now, entering: index) ?? Banner(index: index, opacity: 1)
    }

    func transition(to destination: Int, step: Int, at now: ContinuousClock.Instant, animated: Bool) -> Self {
        var next = self
        next.index = destination
        next.slide = if animated {
            Slide(outgoingArtwork: slide?.backdrop(at: now, entering: index)
                    ?? [BackdropSlice(index: index, coverage: 0..<1, horizontalOffset: 0)],
                  outgoingBanner: banner(at: now), step: step, start: now, isInterruption: slide != nil)
        } else {
            nil
        }
        return next
    }

}

struct HomeView: View {
    let isActive: Bool
    @Binding var carousel: HeroCarousel
    let heroScroll: HomeHeroScroll

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(NuvioAccount.self) private var account
    @Environment(CinemaTitleNavigation.self) private var titles
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var focusScope
    @State private var catalog: HomeCatalog?
    @State private var pendingCatalog: HomeCatalog?
    @State private var continueWatching: [CinemaContinueWatchingItem] = []
    @State private var lastRefresh: ContinuousClock.Instant?
    @State private var retryCount = 0
    @State private var completedRequest: Int?
    @State private var detailOrigin: DetailOrigin?
    @State private var verticalPosition = ScrollPosition()
    @State private var homeScrollRequest: HomeScrollRequest?
    @FocusState private var focusedItem: HomeFocusTarget?

    private struct DetailOrigin: Equatable {
        let target: HomeFocusTarget
        let verticalOffset: CGFloat
    }

    private struct LoadRequest: Equatable {
        let isAvailable: Bool
        let retryCount: Int
    }

    private struct HomeScrollRequest: Equatable {
        let id = UUID()
        let offset: CGFloat
    }

    private let heroGap: CGFloat = 22
    private let heroControlsHeight: CGFloat = 112
    private let refreshInterval: Duration = .seconds(3600)
    private let clock = ContinuousClock()

    private var isAvailable: Bool {
        isActive && scenePhase == .active && titles.screens.isEmpty
    }

    private var canApplyContinueWatching: Bool {
        guard isAvailable, detailOrigin == nil, carousel.slide == nil else { return false }
        if case let .poster(shelf, _)? = focusedItem {
            return shelf != .continueWatching && continueWatching.isEmpty == account.continueWatching.isEmpty
        }
        return true
    }

    private var preferredReturnFocus: HomeFocusTarget? {
        guard let detailOrigin else { return nil }
        switch detailOrigin.target {
        case .poster(.continueWatching, let id):
            let current = account.continueWatching
            if current.contains(where: { $0.id == id }) { return detailOrigin.target }
            if let first = current.first { return .poster(.continueWatching, first.id) }
            return firstDiscoveryFocus
        default:
            return detailOrigin.target
        }
    }

    private var firstDiscoveryFocus: HomeFocusTarget? {
        if let firstRow = catalog?.collections.first, let first = firstRow.entries.first {
            return .poster(firstRow.id, first.id)
        }
        return carousel.entries.isEmpty ? nil : .hero
    }

    var body: some View {
        let request = LoadRequest(isAvailable: isAvailable, retryCount: retryCount)
        return GeometryReader { safeViewport in
            let leadingInset = max(safeViewport.safeAreaInsets.leading, safeViewport.frame(in: .global).minX)
            GeometryReader { viewport in
                homeContent(in: viewport, leadingInset: leadingInset)
            }
            .ignoresSafeArea(.container, edges: .leading)
        }
        .ignoresSafeArea(.container, edges: [.trailing, .bottom])
        .focusScope(focusScope)
        .task(id: isAvailable ? detailOrigin : nil) {
            if isAvailable, let detailOrigin { await restoreFocus(from: detailOrigin) }
        }
        .task(id: request) {
            await refreshCatalog(for: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaRefreshHome)) { _ in
            // Settings asked for fresh catalogs; reload now, or when Home is next shown.
            retryCount += 1
        }
        .onChange(of: isAvailable) { _, _ in reconcilePendingCatalog() }
        .onChange(of: focusedItem) { _, _ in reconcilePendingCatalog() }
        .onChange(of: preferredReturnFocus) { _, _ in reconcilePendingCatalog() }
        .onChange(of: carousel.slide?.id) { _, _ in reconcilePendingCatalog() }
        .onChange(of: canApplyContinueWatching) { _, canApply in
            if canApply { continueWatching = account.continueWatching }
        }
        .onChange(of: account.continueWatching, initial: true) { _, items in
            if items.isEmpty || canApplyContinueWatching {
                continueWatching = items
            } else {
                // Refresh release dates and progress without moving cards under focus.
                let updates = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                continueWatching = continueWatching.map { updates[$0.id] ?? $0 }
            }
        }
    }

    private func homeContent(in viewport: GeometryProxy, leadingInset: CGFloat) -> some View {
        let collections = catalog?.collections ?? []
        let shelves = HomeShelfViewport(width: viewport.size.width, leadingInset: leadingInset)
        let height = viewport.size.height
        let hasHero = !carousel.entries.isEmpty
        let firstStyle = continueWatching.isEmpty
            ? collections.first.map { HomeShelfStyle(shelf: $0.id) } ?? .editorial
            : .backdrop
        let previewCardHeight = shelves.layout(firstStyle).cardHeight
        let placeholderHeroHeight = max(0, height - heroGap - HomeShelfLayout.headingHeight - previewCardHeight / 4)
        let heroHeight = hasHero ? placeholderHeroHeight : 0
        let shelfOffset = max(0, heroHeight - heroControlsHeight)
        let artworkBottom = hasHero ? viewport.frame(in: .global).minY + heroHeight + heroGap / 2 : nil
        let restoresShelf = isAvailable && preferredReturnFocus?.isPoster == true && shelfOffset > 0

        return ScrollView {
            VStack(alignment: .leading, spacing: heroGap) {
                if hasHero || catalog?.isEmpty == false || !continueWatching.isEmpty {
                    if hasHero {
                        FeaturedHero(
                            height: heroHeight,
                            isActive: isAvailable,
                            carousel: $carousel,
                            focus: $focusedItem,
                            focusScope: focusScope,
                            prefersFocus: preferredReturnFocus == .hero,
                            onSelect: { showDetails($0, from: .hero) }
                        )
                        .padding(.leading, leadingInset)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        CatalogShelves(
                            collections: collections,
                            shelfOrder: catalog?.shelfOrder ?? [],
                            genrePreviews: catalog?.genrePreviews ?? [:],
                            continueWatching: continueWatching,
                            viewport: shelves,
                            focus: $focusedItem,
                            focusScope: focusScope,
                            returnFocus: preferredReturnFocus,
                            isRestoringFocus: isAvailable,
                            onSelect: openShelfItem,
                            onWatchAction: performWatchAction
                        )
                        if catalog?.isComplete != true {
                            HomeShelfSkeleton(viewport: shelves)
                        } else if catalog?.hasFailure == true {
                            CatalogStatus(message: "Some Home collections couldn’t load.", retry: retry)
                        }
                    }
                    .padding(.bottom, 52)
                    .frame(minHeight: height, alignment: .topLeading)
                } else if let catalog, catalog.isComplete {
                    CatalogStatus(
                        message: catalog.hasFailure ? "Couldn’t load Home collections." : "No titles available.",
                        retry: retry
                    )
                    .frame(height: height * 0.6)
                } else {
                    HomeLoadingSkeleton(heroHeight: placeholderHeroHeight, gap: heroGap, viewport: shelves)
                }
            }
        }
        .scrollPosition($verticalPosition)
        .scrollTargetBehavior(HomeHeroScrollBehavior(
            restoredShelfOffset: restoresShelf ? shelfOffset : nil
        ))
        .scrollIndicators(.hidden)
        .onChange(of: focusedItem) { previous, current in
            guard isAvailable, detailOrigin == nil, shelfOffset > 0, let current else { return }
            let distance = heroScroll.position.distance
            if !current.isPoster, previous?.isPoster != false,
               distance > 1 || (homeScrollRequest?.offset ?? 0) > 1 {
                animateHomeScroll(to: 0)
            } else if current.isPoster, previous?.isPoster != true,
                      distance < shelfOffset - 1 || (homeScrollRequest?.offset == 0 && distance <= shelfOffset + 1) {
                // Down can reverse the upward request before the content visibly moves.
                animateHomeScroll(to: shelfOffset)
            }
        }
        .onScrollPhaseChange { _, phase, context in
            // Only Back restoration should snap the shelf into its saved position.
            guard phase == .idle, restoresShelf,
                  context.geometry.contentOffset.y + context.geometry.contentInsets.top < shelfOffset - 1 else { return }
            restoreHomeScroll(to: shelfOffset)
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
    }

    private func openShelfItem(_ item: HomeShelfItem, shelf: HomeCollection.ID) {
        let origin = HomeFocusTarget.poster(shelf, item.id)
        switch item {
        case .title(let entry):
            showDetails(entry, from: origin)
        case .watching(let watching):
            showDetails(watching.entry, from: origin)
        case .genre(let genre, let preview):
            showScreen(from: origin) { close in
                GenreCollectionView(genre: genre, preview: preview, onDismiss: close)
            }
        }
    }

    private func performWatchAction(_ action: ContinueWatchingAction, item: CinemaContinueWatchingItem) {
        guard isAvailable, account.profileID != nil,
              let position = account.continueWatching.firstIndex(where: { $0.id == item.id }) else { return }
        let current = account.continueWatching[position]
        guard current.progress.season == item.progress.season,
              current.progress.episode == item.progress.episode else { return }
        switch action {
        case .restart:
            guard current.upcomingEpisode() == nil else { return }
            showScreen(from: .poster(.continueWatching, current.id)) { close in
                TitleDetailsView(title: current.entry.title, kind: current.entry.kind, restartItem: current, onDismiss: close)
            }
            return
        case .markWatched:
            account.setContinueWatchingItemWatched(current)
        case .remove:
            account.removeContinueWatchingItem(current)
        }

        let items = account.continueWatching
        let retainedIndex = items.firstIndex { $0.id == current.id }
        if retainedIndex != position {
            let returnTarget = items.isEmpty
                ? firstDiscoveryFocus
                : .poster(.continueWatching, items[retainedIndex ?? min(position, items.count - 1)].id)
            if let returnTarget {
                let offset = items.isEmpty ? 0 : heroScroll.position.distance
                detailOrigin = DetailOrigin(target: returnTarget, verticalOffset: offset)
            }
        }
        continueWatching = items
    }

    private func showDetails(_ entry: CinemetaSearchResult, from origin: HomeFocusTarget) {
        showScreen(from: origin) { close in
            TitleDetailsView(title: entry.title, kind: entry.kind, onDismiss: close)
        }
    }

    private func showScreen<Content: View>(from origin: HomeFocusTarget,
                                          @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        guard titles.screens.isEmpty else { return }
        detailOrigin = DetailOrigin(target: origin, verticalOffset: heroScroll.position.distance)
        titles.show(content: content)
    }

    private func restoreFocus(from origin: DetailOrigin) async {
        let target = preferredReturnFocus
        if case .poster(.continueWatching, let id) = origin.target,
           !account.continueWatching.contains(where: { $0.id == id }) {
            continueWatching = account.continueWatching
        }
        guard let target else {
            detailOrigin = nil
            return
        }
        restoreScroll(for: target, from: origin)
        // Both scroll views need to lay out the preferred card after Home becomes available.
        do {
            try await Task.sleep(for: .milliseconds(50))
            if focusedItem != target {
                resetFocus(in: focusScope)
                focusedItem = target
            }
            try await Task.sleep(for: .milliseconds(150))
            if focusedItem == target { restoreScroll(for: target, from: origin) }
            detailOrigin = nil
        } catch {
            // A new title or a change of tab invalidates this focus update.
        }
    }

    private func restoreScroll(for target: HomeFocusTarget, from origin: DetailOrigin) {
        // The selected card can be visible at the bottom before the hero has finished scrolling away.
        let offset = target.isPoster ? max(origin.verticalOffset, heroScroll.position.shelfOffset) : 0
        if abs(heroScroll.position.distance - offset) > 1 {
            restoreHomeScroll(to: offset)
        }
    }

    private func animateHomeScroll(to offset: CGFloat) {
        let animation = reduceMotion ? nil : Animation.smooth(duration: 0.42)
        let request = HomeScrollRequest(offset: offset)
        homeScrollRequest = request
        withAnimation(animation, completionCriteria: .removed) {
            verticalPosition.scrollTo(y: offset)
        } completion: {
            if homeScrollRequest == request { homeScrollRequest = nil }
        }
    }

    private func restoreHomeScroll(to offset: CGFloat) {
        homeScrollRequest = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { verticalPosition.scrollTo(y: offset) }
    }

    private func retry() {
        guard completedRequest == retryCount else { return }
        retryCount += 1
    }

    private func refreshCatalog(for request: LoadRequest) async {
        guard request.isAvailable else { return }
        do {
            while !Task.isCancelled {
                if completedRequest == request.retryCount, let lastRefresh {
                    try await clock.sleep(until: lastRefresh.advanced(by: refreshInterval))
                }
                let previous = pendingCatalog ?? catalog
                let updated = await CinemetaClient().loadHome { partial in
                    guard !Task.isCancelled, isAvailable, retryCount == request.retryCount else { return }
                    applyCatalog(partial.preservingAvailableCollections(from: previous))
                }
                try Task.checkCancellation()
                guard isAvailable, retryCount == request.retryCount else { return }
                applyCatalog(updated.preservingAvailableCollections(from: previous))
                lastRefresh = clock.now
                completedRequest = request.retryCount
            }
        } catch {
            // Leaving Home or starting a retry cancels the previous request.
        }
    }

    private func reconcilePendingCatalog() {
        if isAvailable, let pendingCatalog { applyCatalog(pendingCatalog) }
    }

    private func applyCatalog(_ next: HomeCatalog) {
        let heldFocus = preferredReturnFocus ?? focusedItem
        let protectedCatalog: HomeCatalog?
        if let catalog, case let .poster(shelf, id)? = heldFocus {
            protectedCatalog = next.preservingFocus(on: shelf, entryID: id, from: catalog)
        } else {
            protectedCatalog = nil
        }
        let entries = next.featuredEntries
        let currentID = carousel.entry?.id
        let changesCarousel = entries.map(\.id) != carousel.entries.map(\.id)
        let removesFocusedHero = (heldFocus == .hero || heldFocus == .nextFeatured)
            && (!entries.contains { $0.id == currentID } || (heldFocus == .nextFeatured && entries.count < 2))
        let movesFocusedShelf = heldFocus?.isPoster == true && entries.isEmpty != carousel.entries.isEmpty
        let protectsCarousel = changesCarousel && (carousel.slide != nil || removesFocusedHero || movesFocusedShelf)
        pendingCatalog = protectedCatalog != nil || protectsCarousel ? next : nil
        catalog = protectedCatalog ?? next
        guard !protectsCarousel else { return }

        if !changesCarousel {
            carousel.entries = entries
            return
        }

        let artworkURLs = Set(entries.flatMap { [$0.title.background, $0.title.logo].compactMap { $0 } })
        carousel = HeroCarousel(
            entries: entries,
            index: entries.firstIndex { $0.id == currentID } ?? 0,
            artwork: carousel.artwork.filter { artworkURLs.contains($0.key) }
        )
    }
}

struct FeaturedHero: View {
    let height: CGFloat
    let isActive: Bool
    @Binding var carousel: HeroCarousel
    let focus: FocusState<HomeFocusTarget?>.Binding
    let focusScope: Namespace.ID
    let prefersFocus: Bool
    let onSelect: (CinemetaSearchResult) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isVisible = false
    @State private var startedAt: ContinuousClock.Instant?

    private let clock = ContinuousClock()
    private let interval: Duration = .seconds(8)

    private var entries: [CinemetaSearchResult] { carousel.entries }
    private var isFocused: Bool { focus.wrappedValue == .hero || focus.wrappedValue == .nextFeatured }

    var body: some View {
        let entry = carousel.entry
        let urls = Set(entries.flatMap { [$0.title.background, $0.title.logo].compactMap { $0 } })
        let slide = carousel.slide
        let rotationEntryID = canRotate ? entry?.id : nil

        TimelineView(.animation(paused: slide == nil)) { _ in
            let banner = carousel.banner(at: clock.now)

            ZStack(alignment: .bottom) {
                featuredBanner(index: banner.index)
                    .opacity(banner.opacity)

                if entries.count > 1 {
                    indicators(activeIndex: carousel.index, rotates: rotationEntryID != nil)
                        .padding(.horizontal, 17)
                        .frame(height: 32)
                        .background(.black.opacity(0.44), in: Capsule())
                        .accessibilityHidden(true)
                        .padding(.bottom, 20)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            featuredActions(index: carousel.index)
        }
        .focusSection()
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { notification in
            // Let tvOS move between the buttons and play its navigation click. An outward move pages the carousel.
            guard isActive,
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            switch (focus.wrappedValue, context.focusHeading) {
            case (.hero?, .left): move(-1)
            case (.nextFeatured?, .right): move(1)
            default: break
            }
        }
        .onScrollVisibilityChange(threshold: 0.45) { isVisible = $0 }
        .task(id: urls) {
            // Artwork that failed (for example while offline at launch) is retried later instead of staying blank.
            for retryDelay in [Duration.zero, .seconds(30), .seconds(120), .seconds(600)] {
                if retryDelay > .zero {
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                }
                let missingURLs = urls.filter {
                    switch carousel.artwork[$0] {
                    case .image?: false
                    case .unavailable?: retryDelay > .zero
                    case nil: true
                    }
                }
                guard retryDelay == .zero || !missingURLs.isEmpty else { return }
                await withTaskGroup(of: (URL, HeroCarousel.Artwork).self) { group in
                    for url in missingURLs {
                        group.addTask { (url, await HeroCarousel.Artwork.load(url)) }
                    }
                    for await (url, artwork) in group {
                        guard !Task.isCancelled else { return }
                        if case .unavailable = artwork, case .image? = carousel.artwork[url] { continue }
                        carousel.artwork[url] = artwork
                    }
                }
                guard !Task.isCancelled else { return }
            }
        }
        .task(id: rotationEntryID) {
            guard !Task.isCancelled else { return }
            startedAt = nil
            guard let rotationEntryID, canRotate, carousel.entry?.id == rotationEntryID else { return }
            let start = clock.now
            startedAt = start
            do {
                try await clock.sleep(until: start.advanced(by: interval))
                try Task.checkCancellation()
                guard canRotate, startedAt == start, carousel.entry?.id == rotationEntryID else { return }
                move(1)
            } catch {
                // A different title or an offscreen hero cancels the countdown.
            }
        }
        .task(id: slide?.id) {
            guard let slide else { return }
            do {
                try await clock.sleep(until: slide.start.advanced(by: slide.duration))
                try Task.checkCancellation()
                guard carousel.slide?.id == slide.id else { return }
                carousel.slide = nil
            } catch {
                // Replacing the carousel cancels its transition.
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { carousel.slide = nil }
        }
    }

    private var canRotate: Bool {
        entries.count > 1 && isActive && !isFocused && isVisible && scenePhase == .active
            && !reduceMotion && !voiceOverEnabled && carousel.slide == nil
    }

    private var progress: Double {
        guard let startedAt else { return 0 }
        return min(1, max(0, startedAt.duration(to: clock.now) / interval))
    }

    private func move(_ step: Int) {
        guard isActive, entries.count > 1 else { return }
        let nextIndex = (carousel.index + step + entries.count) % entries.count
        startedAt = nil
        carousel = carousel.transition(to: nextIndex, step: step, at: clock.now, animated: !reduceMotion)
    }

    private func indicators(activeIndex: Int, rotates: Bool) -> some View {
        let activeWidth: CGFloat = 42
        return HStack(spacing: 10) {
            ForEach(entries.indices, id: \.self) { entry in
                let active = entry == activeIndex

                Capsule()
                    .fill(.white.opacity(active ? (rotates ? 0.38 : 0.85) : 0.55))
                    .frame(width: active ? activeWidth : 8, height: 8)
                    .overlay(alignment: .leading) {
                        if active && rotates {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                                Capsule()
                                    .fill(.white)
                                    .frame(width: activeWidth * progress)
                            }
                            .transaction { $0.animation = nil }
                            .transition(.identity)
                        }
                    }
                    .clipShape(Capsule())
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.31), value: activeIndex)
    }

    @ViewBuilder
    private func featuredActions(index: Int) -> some View {
        if entries.indices.contains(index) {
            let entry = entries[index]
            HStack(spacing: 14) {
                Button {
                    if carousel.slide == nil { onSelect(entry) }
                } label: {
                    Label("View Details", systemImage: "info.circle")
                }
                .focused(focus, equals: .hero)
                .prefersDefaultFocus(prefersFocus, in: focusScope)
                .accessibilityLabel("View details for \(entry.title.name)")
                .accessibilityValue(entries.count > 1 ? Text("\(index + 1) of \(entries.count)") : Text(""))
                .accessibilityActions {
                    if entries.count > 1 {
                        Button("Previous featured title") { move(-1) }
                    }
                }

                if entries.count > 1 {
                    Button {
                        move(1)
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .buttonBorderShape(.circle)
                    .focused(focus, equals: .nextFeatured)
                    .accessibilityLabel("Next featured title")
                }
            }
            .buttonStyle(.bordered)
            .padding(.leading, 14)
            .padding(.bottom, 10)
        }
    }

    private func featuredBanner(index: Int) -> some View {
        Group {
            if entries.indices.contains(index) {
                let title = entries[index].title

                VStack(alignment: .leading, spacing: 16) {
                    titleLogo(title)
                    heroMetadata(title)

                    if let description = title.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineSpacing(5)
                            .lineLimit(3)
                    }
                }
                .id(title.id)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: height, alignment: .bottomLeading)
        .clipped()
    }

    @ViewBuilder
    private func heroMetadata(_ title: CinemetaTitle) -> some View {
        let facts = [title.displayReleaseInfo, title.genres?.first, title.runtime]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !facts.isEmpty || title.imdbRating != nil {
            HStack(spacing: 16) {
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  •  "))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let rating = title.imdbRating {
                    HStack(spacing: 8) {
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
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
        }
    }

    private func titleLogo(_ title: CinemetaTitle) -> some View {
        Group {
            if let url = title.logo, case let .image(image)? = carousel.artwork[url] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            } else {
                Text(title.name)
                    .font(.system(size: 62, weight: .semibold, design: .serif))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: 510, minHeight: 132, maxHeight: 132, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.name)
        .accessibilityAddTraits(.isHeader)
    }
}

struct HomeHeroBackdrop: View {
    let carousel: HeroCarousel
    let heroScroll: HomeHeroScroll

    var body: some View {
        GeometryReader { geometry in
            let screen = geometry.frame(in: .global)
            let position = heroScroll.position
            let artworkHeight = max(0, screen.height - position.distance)
            let gapHeight = min(artworkHeight, max(0, (position.artworkBottom ?? screen.maxY) - screen.minY - position.distance))
            let visibleHeight = artworkHeight - (artworkHeight - gapHeight) * position.shelfProgress

            TimelineView(.animation(paused: carousel.slide == nil)) { _ in
                if let slide = carousel.slide {
                    let slices = slide.backdrop(at: ContinuousClock().now, entering: carousel.index)
                    slidingArtwork(slices, size: geometry.size)
                } else {
                    artwork(for: carousel.entry, size: geometry.size)
                }
            }
            .overlay {
                // Keep the title and synopsis readable on the left.
                LinearGradient(
                    colors: [CinemaStyle.background.opacity(0.76), .clear],
                    startPoint: UnitPoint(x: 0.04, y: 0.88),
                    endPoint: UnitPoint(x: 0.56, y: 0.38)
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .offset(y: -position.distance)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(alignment: .top) {
                Rectangle()
                    .frame(height: visibleHeight)
            }
            .clipped()
            // Scroll geometry already reports the animated offset on each frame.
            .transaction { $0.animation = nil }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func slidingArtwork(_ slices: [HeroCarousel.BackdropSlice], size: CGSize) -> some View {
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                if carousel.entries.indices.contains(slice.index) {
                    let left = size.width * slice.coverage.lowerBound
                    let right = size.width * slice.coverage.upperBound
                    let maskWidth = min(size.width, right + 1) - left
                    artwork(for: carousel.entries[slice.index], size: size,
                            horizontalOffset: size.width * slice.horizontalOffset)
                        .mask {
                            // Overlap the adjacent masks under the next slice to avoid a hairline.
                            Rectangle().frame(width: maskWidth, height: size.height)
                                .position(x: left + maskWidth / 2, y: size.height / 2)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func artwork(for entry: CinemetaSearchResult?, size: CGSize, horizontalOffset: CGFloat = 0) -> some View {
        if let url = entry?.title.background, case let .image(image)? = carousel.artwork[url] {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                .offset(x: horizontalOffset)
        } else {
            CinemaStyle.background
        }
    }
}

struct CatalogStatus: View {
    let message: LocalizedStringKey
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text(message)
                .foregroundStyle(.secondary)

            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

enum BetterPosters {
    static func url(for imdbID: String?, showTrendTags: Bool = true) -> URL? {
        guard let imdbID else { return nil }
        let url = URL(string: "https://btttr.cc/poster/imdb/poster-default/\(imdbID).jpg")
        var query = [URLQueryItem(name: "rs", value: "IM")]
        if !showTrendTags { query.append(URLQueryItem(name: "tag", value: "none")) }
        return url?.appending(queryItems: query)
    }
}

struct CatalogArtwork: View {
    let url: URL?
    var fallbackURL: URL? = nil
    var isPoster = false
    var alignment: Alignment = .center

    var body: some View {
        GeometryReader { geometry in
            CachedArtwork(url: url) { phase in
                if let fallbackURL, fallbackURL != url, url == nil || phase.error != nil {
                    CachedArtwork(url: fallbackURL) { fallbackPhase in
                        artwork(fallbackPhase, isRequesting: true, size: geometry.size)
                    }
                } else {
                    artwork(phase, isRequesting: url != nil, size: geometry.size)
                }
            }
        }
    }

    @ViewBuilder
    private func artwork(_ phase: AsyncImagePhase, isRequesting: Bool, size: CGSize) -> some View {
        if let image = phase.image {
            image.resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: alignment)
                .clipped()
        } else if isPoster {
            let isLoading = isRequesting && phase.error == nil
            Color(white: isLoading ? 0.16 : 0.09)
                .overlay {
                    if !isLoading {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
        } else {
            CinemaStyle.background
        }
    }
}
