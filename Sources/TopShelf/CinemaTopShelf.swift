#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

struct CinemaTopShelf: ViewModifier {
    let account: NuvioAccount

    @State private var link: ShelfLink?
    @State private var selection: ShelfSelection?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: configureLayout)
            .onChange(of: entries, initial: true) { _, entries in
                guard let entries else { return }
                TopShelfFeedStore.write(entries, title: String(localized: "Continue Watching"))
            }
            .onOpenURL { url in
                if let incoming = ShelfLink(url: url) { link = incoming }
            }
            .task(id: link?.id) {
                guard let link else { return }
                await open(link)
                if !Task.isCancelled, self.link?.id == link.id { self.link = nil }
            }
            .fullScreenCover(item: $selection) { selection in
                TitleDetailsView(title: selection.title, kind: selection.kind, initialResume: selection.resume) {
                    self.selection = nil
                }
                .environment(account)
            }
    }

    private var entries: [TopShelfEntry]? {
        if account.isRestoringTopShelfProfile { return nil }
        guard account.canShareContinueWatchingWithTopShelf else { return [] }
        return Array(account.continueWatching.lazy.compactMap { item in
            let title = item.entry.title
            guard let imdbID = title.imdbID, let backdrop = title.background else { return nil }
            let progress = item.progress
            let started = NuvioAccount.hasStarted(progress)
            return TopShelfEntry(
                contentId: imdbID, contentType: item.entry.kind.rawValue, title: title.name,
                subtitle: Self.status(for: progress, started: started), imageURL: nil,
                backdropURL: backdrop.absoluteString, progress: started && progress.duration > 0 ? progress.fraction : nil,
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

    private func open(_ link: ShelfLink) async {
        if link.resume, account.isSignedIn {
            if account.continueWatching.first(where: link.matches) == nil {
                await account.waitForContinueWatchingSync()
            }
            guard !Task.isCancelled else { return }
            if account.canShareContinueWatchingWithTopShelf,
               let item = account.continueWatching.first(where: link.matches) {
                selection = ShelfSelection(title: item.entry.title, kind: link.kind, resume: item)
                return
            }
        }

        let title = await CinemetaClient().details(imdbID: link.contentID, kind: link.kind)
        guard !Task.isCancelled, let title else { return }
        selection = ShelfSelection(title: title, kind: link.kind, resume: nil)
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
        let id = UUID()
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

    private struct ShelfSelection: Identifiable {
        let id = UUID()
        let title: CinemetaTitle
        let kind: CinemetaKind
        let resume: CinemaContinueWatchingItem?
    }
}
#endif
