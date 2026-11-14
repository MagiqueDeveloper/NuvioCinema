import SwiftUI

struct GenreCollectionView: View {
    let genre: HomeGenre
    let preview: [CinemetaSearchResult]
    let onDismiss: () -> Void

    @Environment(CinemaTitleNavigation.self) private var titles
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var focusScope
    @FocusState private var focus: FocusTarget?
    @State private var entries: [CinemetaSearchResult]
    @State private var fetchedIDs: Set<CinemetaSearchResult.ID> = []
    @State private var offsets: [CinemetaKind: Int] = [.movie: 0, .series: 0]
    @State private var failures: Set<CinemetaKind> = []
    @State private var request: LoadRequest? = LoadRequest(offsets: [.movie: 0, .series: 0])
    @State private var isNearEnd = false
    @State private var postLoadFocus: FocusTarget?
    @State private var restorePosterID: CinemetaSearchResult.ID?
    @State private var requestedInitialFocus = false

    private let preloadDistance: CGFloat = 450
    private static let columnCount = 5
    private static let posterSpacing: CGFloat = 38
    private static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: posterSpacing), count: columnCount)

    private enum FocusTarget: Hashable {
        case poster(CinemetaSearchResult.ID), loading, retry
    }

    private struct ScrollEdge: Equatable {
        let contentHeight: CGFloat
        let isNearEnd: Bool
    }

    private struct LoadRequest: Identifiable {
        let id = UUID()
        let offsets: [CinemetaKind: Int]
    }

    private var isActive: Bool { titles.screens.count == 1 }

    init(genre: HomeGenre, preview: [CinemetaSearchResult] = [], onDismiss: @escaping () -> Void) {
        self.genre = genre
        self.preview = preview
        self.onDismiss = onDismiss
        var seen = Set<CinemetaSearchResult.ID>()
        _entries = State(initialValue: preview.filter { seen.insert($0.id).inserted })
    }

    var body: some View {
        let entries = entries
        let currentRequest = request
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    heading
                    grid(entries, isLoading: currentRequest != nil)
                    status(hasResults: !entries.isEmpty, isLoading: currentRequest != nil)
                }
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 64)
            }
            .scrollIndicators(.hidden)
            .focusScope(focusScope)
            .defaultFocus($focus, preferredFocus)
            .task {
                guard isActive, !requestedInitialFocus else { return }
                requestedInitialFocus = true
                focus = entries.first.map { FocusTarget.poster($0.id) } ?? .loading
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
                guard !Task.isCancelled, isActive, focus == nil, restorePosterID == nil, postLoadFocus == nil else { return }
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
                guard isActive, restorePosterID == nil, let target = postLoadFocus else { return }
                // Retry may be below the last populated row; initial load is already at the top.
                if case .retry? = focus, case let .poster(id) = target { scroll.scrollTo(id) }
                await Task.yield()
                guard !Task.isCancelled, isActive, restorePosterID == nil, postLoadFocus == target else { return }
                if focus == nil || focus == .loading || focus == .retry {
                    focus = target
                }
                postLoadFocus = nil
                loadMoreIfNeeded()
            }
            .task(id: isActive ? restorePosterID : nil) {
                guard isActive, let id = restorePosterID else { return }
                scroll.scrollTo(id)
                do {
                    try await Task.sleep(for: .milliseconds(45))
                    guard isActive, restorePosterID == id else { return }
                    if focus != .poster(id) {
                        resetFocus(in: focusScope)
                        focus = .poster(id)
                    }
                    restorePosterID = nil
                    loadMoreIfNeeded()
                } catch {
                    // A new navigation action supersedes this focus restoration.
                }
            }
        }
        .background { background }
        .onExitCommand(perform: isActive ? onDismiss : nil)
        .task(id: currentRequest?.id) {
            if let currentRequest { await load(currentRequest) }
        }
    }

    private var preferredFocus: FocusTarget {
        if let restorePosterID { return .poster(restorePosterID) }
        if let postLoadFocus { return postLoadFocus }
        if let first = entries.first { return .poster(first.id) }
        return request == nil && !failures.isEmpty ? .retry : .loading
    }

    private var heading: some View {
        Text(genre.name)
            .font(.system(size: 76, weight: .bold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
    }

    private func grid(_ entries: [CinemetaSearchResult], isLoading: Bool) -> some View {
        let names = CinemetaSearchResult.disambiguatedNames(for: entries)
        return LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: Self.posterSpacing) {
            ForEach(entries) { entry in
                Button {
                    showDetails(entry)
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
                .focused($focus, equals: .poster(entry.id))
                .prefersDefaultFocus(restorePosterID == entry.id || postLoadFocus == .poster(entry.id), in: focusScope)
                .id(entry.id)
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
                    request = LoadRequest(offsets: offsets.filter { failures.contains($0.key) })
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

    private var background: some View {
        CinemaStyle.background
            .overlay(alignment: .top) {
                ZStack {
                    if let url = preview.lazy.compactMap(\.title.background).first {
                        CatalogArtwork(url: url)
                            .opacity(0.32)
                    }
                    LinearGradient(
                        colors: [CinemaStyle.background.opacity(0.25), CinemaStyle.background],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .frame(height: 560)
            }
            .ignoresSafeArea()
    }

    private func loadMoreIfNeeded() {
        guard isActive, isNearEnd, postLoadFocus == nil, restorePosterID == nil,
              request == nil, failures.isEmpty, !offsets.isEmpty else { return }
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
            guard let response else {
                failures.insert(kind)
                continue
            }
            failures.remove(kind)
            let fresh = response.map { CinemetaSearchResult(title: $0, kind: kind) }
                .filter { fetchedIDs.insert($0.id).inserted }
            batch[kind] = fresh
            // A page already visible in the preview can still be a new server page.
            offsets[kind] = fresh.isEmpty ? nil : skip + 50
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
                postLoadFocus = (appended.first ?? entries.last).map { .poster($0.id) } ?? .loading
            } else if wasEmpty, focus == nil || focus == .loading {
                postLoadFocus = entries.first.map { .poster($0.id) } ?? (failures.isEmpty ? .loading : .retry)
            }
        }
        self.request = nil
        // A short page may only fill the existing last grid row.
        if appended.count < Self.columnCount { loadMoreIfNeeded() }
    }

    private func showDetails(_ entry: CinemetaSearchResult) {
        guard isActive else { return }
        postLoadFocus = nil
        restorePosterID = nil
        titles.show(onDismiss: { restorePosterID = entry.id }) { close in
            TitleDetailsView(title: entry.title, kind: entry.kind, onDismiss: close)
        }
    }
}
