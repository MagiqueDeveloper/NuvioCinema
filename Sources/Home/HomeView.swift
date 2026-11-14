import SwiftUI
import UIKit

enum CinemaStyle {
    static let background = Color(white: 0.105)
}

private enum HomeFocusTarget: Hashable {
    case hero, nextFeatured
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

private struct HomeHeroScrollBehavior: ScrollTargetBehavior {
    let shelfOffset: CGFloat
    let isBelowHero: Bool
    let prefersShelfPosition: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard shelfOffset > 0 else { return }
        let offset = target.rect.minY
        if prefersShelfPosition {
            target.rect.origin.y = max(offset, shelfOffset)
            return
        }
        if isBelowHero {
            guard offset <= shelfOffset else { return }
            target.rect.origin.y = offset < shelfOffset * 0.7 ? 0 : shelfOffset
        } else if offset >= shelfOffset * 0.3 {
            target.rect.origin.y = shelfOffset
        }
    }
}

struct HeroCarousel {
    enum Artwork: Sendable {
        case image(CGImage)
        case unavailable

        nonisolated static func load(_ url: URL) async -> Self {
            do {
                return .image(try await CinemaImageCache.shared.image(for: url))
            } catch {
                return .unavailable
            }
        }
    }

    struct Slide {
        static let fadeOutDuration: Duration = .milliseconds(90)
        static let wipeDuration: Duration = .milliseconds(345)
        static let fadeInDuration: Duration = .milliseconds(175)
        static let wipeEnd = fadeOutDuration + wipeDuration
        static let duration = wipeEnd + fadeInDuration

        private static let revealCurve = UnitCurve.bezier(
            startControlPoint: UnitPoint(x: 0.24, y: 0),
            endControlPoint: UnitPoint(x: 0.26, y: 1)
        )

        let outgoingIndex: Int
        let step: Int
        let start: ContinuousClock.Instant

        func isShowingIncoming(at now: ContinuousClock.Instant) -> Bool {
            start.duration(to: now) >= Self.wipeEnd
        }

        func contentOpacity(at now: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: now)
            if elapsed < Self.fadeOutDuration {
                return 1 - UnitCurve.easeInOut.value(at: elapsed / Self.fadeOutDuration)
            }
            if elapsed < Self.wipeEnd { return 0 }
            return Self.revealCurve.value(at: (elapsed - Self.wipeEnd) / Self.fadeInDuration)
        }

        func wipeProgress(at now: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: now) - Self.fadeOutDuration
            return Self.revealCurve.value(at: elapsed / Self.wipeDuration)
        }
    }

    var entries: [CinemetaSearchResult] = []
    var index = 0
    var slide: Slide?
    var artwork: [URL: Artwork] = [:]

    var entry: CinemetaSearchResult? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    func isReady(at index: Int) -> Bool {
        let title = entries[index].title
        return [title.background, title.logo].compactMap { $0 }.allSatisfy { artwork[$0] != nil }
    }

    func hasUsableBackdrop(at index: Int) -> Bool {
        guard let url = entries[index].title.background,
              case .image? = artwork[url] else { return false }
        return true
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
    @State private var isBelowHero = false
    @FocusState private var focusedItem: HomeFocusTarget?

    private struct DetailOrigin: Equatable {
        let target: HomeFocusTarget
        let verticalOffset: CGFloat
    }

    private struct LoadRequest: Equatable {
        let isAvailable: Bool
        let retryCount: Int
    }

    private let heroGap: CGFloat = 22
    private let heroControlsHeight: CGFloat = 112
    private let refreshInterval: Duration = .seconds(3600)
    private let clock = ContinuousClock()

    private var isAvailable: Bool {
        isActive && scenePhase == .active && titles.screens.isEmpty
    }

    private var canApplyCatalog: Bool {
        isAvailable && detailOrigin == nil && focusedItem == nil && carousel.slide == nil
    }

    private var canApplyContinueWatching: Bool {
        if case .poster? = focusedItem { return false }
        return isAvailable && detailOrigin == nil && carousel.slide == nil
    }

    private var preferredReturnFocus: HomeFocusTarget? {
        guard let detailOrigin else { return nil }
        switch detailOrigin.target {
        case .poster(.continueWatching, let id):
            let current = account.continueWatching
            if current.contains(where: { $0.id == id }) { return detailOrigin.target }
            if let first = current.first { return .poster(.continueWatching, first.id) }
            if let firstRow = catalog?.collections.first(where: { !$0.entries.isEmpty }),
               let first = firstRow.entries.first { return .poster(firstRow.id, first.id) }
            return carousel.entries.isEmpty ? nil : .hero
        default:
            return detailOrigin.target
        }
    }

    private var prefersShelfPosition: Bool {
        isAvailable && (preferredReturnFocus ?? focusedItem)?.isPoster == true
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
        .onChange(of: canApplyCatalog) { _, canApply in
            if canApply, let pendingCatalog {
                self.pendingCatalog = nil
                applyCatalog(pendingCatalog)
            }
        }
        .onChange(of: canApplyContinueWatching) { _, canApply in
            if canApply { continueWatching = account.continueWatching }
        }
        .onChange(of: account.continueWatching, initial: true) { _, items in
            if items.isEmpty || canApplyContinueWatching || items.map(\.id) == continueWatching.map(\.id) {
                continueWatching = items
            }
        }
    }

    private func homeContent(in viewport: GeometryProxy, leadingInset: CGFloat) -> some View {
        let posterLayout = HomeShelfLayout(viewportWidth: viewport.size.width, leadingInset: leadingInset, landscape: false)
        let landscapeLayout = HomeShelfLayout(viewportWidth: viewport.size.width, leadingInset: leadingInset, landscape: true)
        let height = viewport.size.height
        let hasHero = !carousel.entries.isEmpty
        let firstCardHeight = continueWatching.isEmpty ? posterLayout.cardHeight : landscapeLayout.cardHeight
        let heroHeight = hasHero ? max(0, height - heroGap - HomeShelfLayout.headingHeight - firstCardHeight / 4) : 0
        let shelfOffset = max(0, heroHeight - heroControlsHeight)
        let artworkBottom = hasHero ? viewport.frame(in: .global).minY + heroHeight + heroGap / 2 : nil

        return ScrollView {
            VStack(alignment: .leading, spacing: heroGap) {
                if catalog?.isEmpty == false || !continueWatching.isEmpty {
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
                        CatalogShelves(collections: catalog?.collections ?? [], continueWatching: continueWatching,
                                       posterLayout: posterLayout, landscapeLayout: landscapeLayout, focus: $focusedItem,
                                       focusScope: focusScope, returnFocus: preferredReturnFocus, isRestoringFocus: isAvailable) { item, shelf in
                            showDetails(item.entry, from: .poster(shelf, item.id))
                        }
                        if catalog?.hasFailure == true {
                            CatalogStatus(message: "Some Home collections couldn’t load.", retry: retry)
                        }
                    }
                    .padding(.bottom, 52)
                    .frame(minHeight: height, alignment: .topLeading)
                } else if let catalog {
                    CatalogStatus(
                        message: catalog.hasFailure ? "Couldn’t load Home collections." : "No titles available.",
                        retry: retry
                    )
                    .frame(height: height * 0.6)
                } else {
                    ProgressView("Loading Home…")
                        .frame(maxWidth: .infinity)
                        .frame(height: height * 0.6)
                }
            }
        }
        .scrollPosition($verticalPosition)
        .scrollTargetBehavior(HomeHeroScrollBehavior(
            shelfOffset: shelfOffset,
            isBelowHero: isBelowHero,
            prefersShelfPosition: prefersShelfPosition
        ))
        .scrollIndicators(.hidden)
        .onChange(of: focusedItem?.isPoster) { wasPoster, isPoster in
            guard isAvailable, detailOrigin == nil else { return }
            if isPoster == true, heroScroll.position.distance < shelfOffset - 1 {
                scrollHome(to: shelfOffset, animated: true)
            } else if wasPoster == true, isPoster == false {
                scrollHome(to: 0, animated: true)
            }
        }
        .onScrollPhaseChange { _, phase, context in
            guard phase == .idle, prefersShelfPosition,
                  context.geometry.contentOffset.y + context.geometry.contentInsets.top < shelfOffset - 1 else { return }
            scrollHome(to: shelfOffset, animated: false)
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
        .onScrollGeometryChange(for: Bool.self) { geometry in
            shelfOffset > 0 && geometry.contentOffset.y + geometry.contentInsets.top >= shelfOffset / 2
        } action: { _, belowHero in
            isBelowHero = belowHero
        }
    }

    private func showDetails(_ entry: CinemetaSearchResult, from origin: HomeFocusTarget) {
        guard titles.screens.isEmpty else { return }
        detailOrigin = DetailOrigin(target: origin, verticalOffset: heroScroll.position.distance)
        titles.show { close in
            TitleDetailsView(title: entry.title, kind: entry.kind, onDismiss: close)
        }
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
            scrollHome(to: offset, animated: false)
        }
    }

    private func scrollHome(to offset: CGFloat, animated: Bool) {
        let animation: Animation? = animated && !reduceMotion ? .smooth(duration: 0.42) : nil
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = animation == nil
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
                let updated = await CinemetaClient().loadHome()
                try Task.checkCancellation()
                guard isAvailable, retryCount == request.retryCount else { return }
                if catalog == nil || canApplyCatalog {
                    pendingCatalog = nil
                    applyCatalog(updated)
                } else {
                    pendingCatalog = updated
                }
                lastRefresh = clock.now
                completedRequest = request.retryCount
            }
        } catch {
            // Leaving Home or starting a retry cancels the previous request.
        }
    }

    private func applyCatalog(_ updated: HomeCatalog) {
        let next = updated.preservingAvailableCollections(from: catalog)
        catalog = next

        let entries = next.featuredEntries
        if entries.map(\.id) == carousel.entries.map(\.id) {
            carousel.entries = entries
            return
        }

        let currentID = carousel.entry?.id
        let artworkURLs = Set(entries.flatMap { [$0.title.background, $0.title.logo].compactMap { $0 } })
        carousel = HeroCarousel(
            entries: entries,
            index: entries.firstIndex { $0.id == currentID } ?? 0,
            artwork: carousel.artwork.filter { artworkURLs.contains($0.key) }
        )
    }
}

private struct FeaturedHero: View {
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
    @State private var pendingStep: Int?

    private let clock = ContinuousClock()
    private let interval: Duration = .seconds(8)

    private var entries: [CinemetaSearchResult] { carousel.entries }
    private var isFocused: Bool { focus.wrappedValue == .hero || focus.wrappedValue == .nextFeatured }

    var body: some View {
        let entry = carousel.entry
        let urls = entries.flatMap { [$0.title.background, $0.title.logo].compactMap { $0 } }
        let rotates = entries.count > 1 && isActive && !isFocused && isVisible && scenePhase == .active
            && !reduceMotion && !voiceOverEnabled && carousel.slide == nil && pendingStep == nil

        TimelineView(.animation(paused: carousel.slide == nil)) { _ in
            let now = clock.now
            let index = visibleIndex(at: now)
            let opacity = carousel.slide?.contentOpacity(at: now) ?? 1

            ZStack(alignment: .bottom) {
                featuredBanner(index: index)
                    .opacity(opacity)

                if entries.count > 1 {
                    indicators(activeIndex: index, rotates: rotates)
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
        .onChange(of: isActive) { _, active in
            if !active { pendingStep = nil }
        }
        .task(id: urls) {
            let missingURLs = Set(urls).filter { carousel.artwork[$0] == nil }
            await withTaskGroup(of: (URL, HeroCarousel.Artwork).self) { group in
                for url in missingURLs {
                    group.addTask { (url, await HeroCarousel.Artwork.load(url)) }
                }
                for await (url, artwork) in group {
                    guard !Task.isCancelled else { return }
                    carousel.artwork[url] = artwork
                    advancePendingStep()
                }
            }
        }
        .task(id: rotates ? entry?.id : nil) {
            startedAt = nil
            guard rotates else { return }
            let start = clock.now
            startedAt = start
            do {
                try await clock.sleep(until: start.advanced(by: interval))
                try Task.checkCancellation()
                move(1)
            } catch {
                // A different title or an offscreen hero cancels the countdown.
            }
        }
        .task(id: carousel.slide?.start) {
            guard let slide = carousel.slide else { return }
            do {
                try await clock.sleep(until: slide.start.advanced(by: HeroCarousel.Slide.duration))
                try Task.checkCancellation()
                carousel.slide = nil
                advancePendingStep()
            } catch {
                // Replacing the carousel cancels its transition.
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled {
                carousel.slide = nil
                advancePendingStep()
            }
        }
        .onChange(of: entries.map(\.id)) { _, _ in
            pendingStep = nil
        }
    }

    private var progress: Double {
        guard let startedAt else { return 0 }
        return min(1, max(0, startedAt.duration(to: clock.now) / interval))
    }

    private func move(_ step: Int) {
        guard entries.count > 1 else { return }
        pendingStep = step
        advancePendingStep()
    }

    private func advancePendingStep() {
        guard isActive, carousel.slide == nil, let step = pendingStep, entries.count > 1 else { return }
        for distance in 1..<entries.count {
            let nextIndex = (carousel.index + step * distance + entries.count) % entries.count
            guard carousel.isReady(at: nextIndex) else { return }
            guard carousel.hasUsableBackdrop(at: nextIndex) else { continue }

            pendingStep = nil
            startedAt = nil
            var next = carousel
            next.index = nextIndex
            if !reduceMotion {
                next.slide = HeroCarousel.Slide(outgoingIndex: carousel.index, step: step, start: clock.now)
            }
            carousel = next
            return
        }
        pendingStep = nil
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

    private func visibleIndex(at now: ContinuousClock.Instant) -> Int {
        if let slide = carousel.slide, !slide.isShowingIncoming(at: now) {
            return slide.outgoingIndex
        }
        return carousel.index
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
                let slide = carousel.slide
                let remaining = 1 - (slide?.wipeProgress(at: ContinuousClock().now) ?? 1)

                ZStack {
                    artwork(for: carousel.entry, size: geometry.size)

                    if let slide, remaining > 0, carousel.entries.indices.contains(slide.outgoingIndex) {
                        artwork(for: carousel.entries[slide.outgoingIndex], size: geometry.size)
                            .mask(alignment: slide.step == -1 ? .trailing : .leading) {
                                Rectangle()
                                    .frame(width: geometry.size.width * remaining)
                            }
                    }
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

    @ViewBuilder
    private func artwork(for entry: CinemetaSearchResult?, size: CGSize) -> some View {
        if let url = entry?.title.background, case let .image(image)? = carousel.artwork[url] {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
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

private struct HomeShelfLayout {
    static let headingTextHeight: CGFloat = 42
    static let headingGap: CGFloat = 20
    static let headingHeight = headingTextHeight + headingGap

    let cardsPerRow: Int
    let viewportWidth: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let leadingInset: CGFloat
    let inset: CGFloat
    let spacing: CGFloat

    var previewWidth: CGFloat { cardWidth / 6 }
    var pitch: CGFloat { cardWidth + spacing }
    var centeredInset: CGFloat { (viewportWidth - (CGFloat(cardsPerRow) * pitch - spacing)) / 2 }

    init(viewportWidth: CGFloat, leadingInset: CGFloat, landscape: Bool) {
        self.viewportWidth = viewportWidth
        self.leadingInset = leadingInset
        cardsPerRow = landscape ? 4 : 6
        // The wider Continue Watching card travels farther when tvOS lifts it.
        inset = landscape ? 34 : 14
        spacing = landscape ? 44 : 30
        let gaps = CGFloat(cardsPerRow) * spacing
        cardWidth = max(1, (viewportWidth - leadingInset - inset - gaps) / (CGFloat(cardsPerRow) + 1.0 / 6.0))
        cardHeight = cardWidth * (landscape ? 9.0 / 16.0 : 1.5)
    }
}

private struct HomeShelfItem: Identifiable {
    let entry: CinemetaSearchResult
    var watching: CinemaContinueWatchingItem?

    var id: String { watching?.id ?? entry.id }
}

private struct CatalogShelves: View {
    let collections: [HomeCollection]
    let continueWatching: [CinemaContinueWatchingItem]
    let posterLayout: HomeShelfLayout
    let landscapeLayout: HomeShelfLayout
    let focus: FocusState<HomeFocusTarget?>.Binding
    let focusScope: Namespace.ID
    let returnFocus: HomeFocusTarget?
    let isRestoringFocus: Bool
    let onSelect: (HomeShelfItem, HomeCollection.ID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            if !continueWatching.isEmpty {
                CatalogShelf(shelf: .continueWatching, items: continueWatching.map { HomeShelfItem(entry: $0.entry, watching: $0) },
                             layout: landscapeLayout, focus: focus, focusScope: focusScope, returnFocus: returnFocus,
                             isRestoringFocus: isRestoringFocus, onSelect: onSelect)
            }
            ForEach(collections) { collection in
                CatalogShelf(shelf: collection.id, items: collection.entries.map { HomeShelfItem(entry: $0) },
                             layout: posterLayout, focus: focus, focusScope: focusScope, returnFocus: returnFocus,
                             isRestoringFocus: isRestoringFocus, onSelect: onSelect)
            }
        }
    }
}

private struct CatalogShelf: View {
    let shelf: HomeCollection.ID
    let items: [HomeShelfItem]
    let layout: HomeShelfLayout
    let focus: FocusState<HomeFocusTarget?>.Binding
    let focusScope: Namespace.ID
    let returnFocus: HomeFocusTarget?
    let isRestoringFocus: Bool
    let onSelect: (HomeShelfItem, HomeCollection.ID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstVisibleIndex = 0

    private var returnItemID: String? {
        guard case let .poster(returnShelf, id)? = returnFocus, returnShelf == shelf else { return nil }
        return id
    }

    private var heading: Text {
        switch shelf {
        case .continueWatching: Text("Continue Watching")
        case .watching: Text("What We’re Watching")
        case .today: Text("Popular Today")
        case .newReleases: Text("New Releases")
        case .topRated: Text("Top Rated")
        case .popularMovies: Text("Popular Movies")
        case .popularSeries: Text("Popular Series")
        case .genre(let genre): Text(genre.title)
        }
    }

    var body: some View {
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
                            Button {
                                onSelect(item, shelf)
                            } label: {
                                if let watching = item.watching {
                                    ContinueWatchingCard(item: watching, size: CGSize(width: layout.cardWidth, height: layout.cardHeight))
                                } else {
                                    TitleCard(title: item.entry.title, layout: layout, rank: rank)
                                }
                            }
                            .focused(focus, equals: .poster(shelf, item.id))
                            .prefersDefaultFocus(item.id == returnItemID, in: focusScope)
                            .accessibilityLabel(accessibilityLabel(for: item, rank: rank))
                            .accessibilityHint(item.watching == nil ? Text("") : Text("Opens title details"))
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
                .padding(.vertical, 28)
                .clipped()
                .padding(.vertical, -28)
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

    private func accessibilityLabel(for item: HomeShelfItem, rank: Int?) -> Text {
        let title = item.entry.title.name
        if let rank {
            return Text("Rank \(rank), \(title)")
        }
        if let watching = item.watching {
            return Text(ContinueWatchingCard.accessibilityLabel(for: watching))
        }
        return Text(title)
    }
}

private struct TitleCard: View {
    let title: CinemetaTitle
    let layout: HomeShelfLayout
    let rank: Int?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)

        CatalogArtwork(url: BetterPosters.url(for: title.imdbID, showTrendTags: rank == nil),
                       fallbackURL: title.poster, isPoster: true)
            .frame(width: layout.cardWidth, height: layout.cardHeight)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if let rank {
                    Text(rank.formatted())
                        .font(.system(size: min(66, layout.cardWidth * 0.25), weight: .heavy).monospacedDigit())
                        .foregroundStyle(LinearGradient(
                            stops: [.init(color: .white, location: 0.35), .init(color: .white.opacity(0.32), location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .shadow(color: .black.opacity(0.60), radius: 8, x: 1, y: 2)
                        .padding(.leading, 16)
                        .padding(.top, 10)
                }
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            .accessibilityHidden(true)
    }
}

private struct ContinueWatchingCard: View {
    let item: CinemaContinueWatchingItem
    let size: CGSize

    private var title: CinemetaTitle { item.entry.title }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)

        CachedArtwork(url: title.background) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color(white: 0.11)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            RadialGradient(colors: [.black.opacity(0.40), .clear], center: .center,
                           startRadius: 0, endRadius: size.width * 0.46)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .clear, location: 0.52), .init(color: .black.opacity(0.90), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            CachedArtwork(url: title.logo) { phase in
                if let logo = phase.image {
                    logo.resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                } else {
                    Text(title.name)
                        .font(.system(size: 32, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: size.width * 0.57, height: size.height * 0.38)
        }
        .overlay(alignment: .bottomLeading) {
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

    static func accessibilityLabel(for item: CinemaContinueWatchingItem) -> String {
        var parts = [item.entry.title.name]
        if item.entry.kind == .series, let season = item.progress.season, let episode = item.progress.episode {
            parts.append(String(localized: "Season \(season), Episode \(episode)"))
            if let name = item.episode?.name { parts.append(name) }
        }
        if !NuvioAccount.hasStarted(item.progress) {
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
            Color(white: 0.09)
                .overlay {
                    if case .empty = phase, isRequesting {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
        } else {
            CinemaStyle.background
        }
    }
}
