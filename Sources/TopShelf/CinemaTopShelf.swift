#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

struct CinemaTopShelf: ViewModifier {
    let account: NuvioAccount
    let titles: CinemaTitleNavigation

    @State private var shelfRouteID: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: configureLayout)
            .onChange(of: entries, initial: true) { _, entries in
                guard let entries else { return }
                TopShelfFeedStore.write(entries, title: String(localized: "Continue Watching"))
            }
            .onOpenURL { url in
                guard let link = ShelfLink(url: url) else { return }
                if let shelfRouteID { titles.dismiss(id: shelfRouteID) }
                shelfRouteID = titles.show { close in
                    ShelfDestination(link: link, onDismiss: close)
                }
            }
    }

    private var entries: [TopShelfEntry]? {
        if account.isRestoringTopShelfProfile { return nil }
        guard account.canShareContinueWatchingWithTopShelf else { return [] }
        return Array(account.continueWatching.lazy.compactMap { item in
            let title = item.entry.title
            guard let imdbID = title.imdbID, title.background != nil || title.poster != nil else { return nil }
            let progress = item.progress
            let started = NuvioAccount.hasStarted(progress)
            return TopShelfEntry(
                contentId: imdbID, contentType: item.entry.kind.rawValue, title: title.name,
                subtitle: Self.status(for: progress, started: started), imageURL: title.poster?.absoluteString,
                backdropURL: title.background?.absoluteString,
                progress: started && progress.duration > 0 ? progress.fraction : nil,
                summary: title.description, genres: title.genres, year: title.releaseYear.flatMap(Int.init),
                releaseDate: title.released?.formatted(.iso8601), runtimeMinutes: TopShelfEntry.runtimeMinutes(title.runtime),
                logoURL: title.logo?.absoluteString, cast: Array(title.cast.prefix(4)),
                directors: Array(title.directors.prefix(2)), imdbId: imdbID
            )
        }.prefix(10))
    }

    private func configureLayout() {
        guard TopShelfFeedStore.isAvailable else { return }
        let layout = TopShelfConfiguration(showsEpisodeLabels: true, style: .carouselDetails, includesUpNext: false,
                                           includesToday: false, includesLibrary: false, catalogRowIDs: [], playsTrailers: false)
        if TopShelfConfigurationStore.load() != layout { TopShelfConfigurationStore.save(layout) }
    }

    private static func status(for progress: NuvioProgress, started: Bool) -> String {
        let episodeLabel: String?
        if let season = progress.season, let episode = progress.episode {
            episodeLabel = started ? String(localized: "S\(season), E\(episode)") : String(localized: "Play S\(season), E\(episode)")
        } else {
            episodeLabel = nil
        }
        guard started else { return episodeLabel ?? String(localized: "Play") }
        guard progress.duration > 0 else { return episodeLabel ?? String(localized: "In Progress") }
        let remaining = progress.duration - min(progress.position, progress.duration)
        let minutes = max(1, Int(ceil(Double(remaining) / 60_000)))
        let time = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return [episodeLabel, String(localized: "\(time) left")].compactMap { $0 }.joined(separator: " · ")
    }

    private struct ShelfLink {
        let contentID: String
        let kind: CinemetaKind
        let resume: Bool

        init?(url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "nuvio-cinema", components.user == nil, components.password == nil,
                  components.port == nil, components.path.isEmpty,
                  let host = components.host, ["continue-watching", "details"].contains(host),
                  let contentID = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  contentID.hasPrefix("tt"), (3...24).contains(contentID.utf8.count),
                  contentID.utf8.dropFirst(2).allSatisfy({ (48...57).contains($0) }),
                  let type = components.queryItems?.first(where: { $0.name == "type" })?.value,
                  let kind = CinemetaKind(rawValue: type) else { return nil }
            self.contentID = contentID
            self.kind = kind
            self.resume = host == "continue-watching"
        }

        func matches(_ item: CinemaContinueWatchingItem) -> Bool {
            item.entry.kind == kind && item.entry.title.imdbID == contentID
        }
    }

    private struct ShelfDestination: View {
        let link: ShelfLink
        let onDismiss: () -> Void

        @Environment(NuvioAccount.self) private var account
        @State private var title: CinemetaTitle?
        @State private var resume: CinemaContinueWatchingItem?
        @State private var loadFailed = false
        @State private var loadAttempt = 0

        var body: some View {
            if let title {
                TitleDetailsView(title: title, kind: link.kind, initialResume: resume, onDismiss: onDismiss)
            } else {
                VStack(spacing: 24) {
                    if loadFailed {
                        Text("Couldn’t load this title.")
                            .font(.title)
                            .accessibilityAddTraits(.isHeader)
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            loadFailed = false
                            loadAttempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView("Loading title…")
                    }
                    Button("Back", action: onDismiss)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { CinemaStyle.background.ignoresSafeArea() }
                .onExitCommand(perform: onDismiss)
                .task(id: loadAttempt) { await loadTitle() }
            }
        }

        private func loadTitle() async {
            if link.resume, account.isSignedIn {
                if !account.continueWatching.contains(where: link.matches) {
                    await account.waitForContinueWatchingSync()
                }
                guard !Task.isCancelled else { return }
                if account.canShareContinueWatchingWithTopShelf,
                   let item = account.continueWatching.first(where: link.matches) {
                    resume = item
                    title = item.entry.title
                    return
                }
            }

            let loaded = await CinemetaClient().details(imdbID: link.contentID, kind: link.kind)
            guard !Task.isCancelled else { return }
            title = loaded
            loadFailed = loaded == nil
        }
    }
}
#endif
