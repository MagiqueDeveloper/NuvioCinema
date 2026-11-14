#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

struct CinemaTopShelf: ViewModifier {
    let featuredEntries: [CinemetaSearchResult]
    let titles: CinemaTitleNavigation

    @Environment(\.scenePhase) private var scenePhase
    @State private var shelfRouteID: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                configureLayout()
                if !entries.isEmpty, TopShelfFeedStore.isAvailable, !TopShelfFeedStore.hasHomeFeaturedFeed {
                    publish(entries)
                }
            }
            .onChange(of: entries, initial: true) { _, entries in
                guard !entries.isEmpty else { return }
                publish(entries)
            }
            .onOpenURL { url in
                guard let link = ShelfLink(url: url) else { return }
                if let shelfRouteID { titles.dismiss(id: shelfRouteID) }
                let preview = featuredEntries.first(where: link.matches)?.title
                shelfRouteID = titles.show { close in
                    ShelfDestination(link: link, preview: preview, onDismiss: close)
                }
            }
    }

    private var entries: [TopShelfEntry] {
        featuredEntries.compactMap { entry in
            let title = entry.title
            guard let imdbID = title.imdbID, title.background != nil || title.poster != nil else { return nil }
            return TopShelfEntry(
                contentId: imdbID, contentType: entry.kind.rawValue, title: title.name,
                subtitle: nil, imageURL: title.poster?.absoluteString, backdropURL: title.background?.absoluteString,
                progress: nil, action: .details,
                summary: title.description, genres: title.genres, year: title.releaseYear.flatMap(Int.init),
                releaseDate: title.released?.formatted(.iso8601), runtimeMinutes: TopShelfEntry.runtimeMinutes(title.runtime),
                logoURL: title.logo?.absoluteString, cast: Array(title.cast.prefix(4)),
                directors: Array(title.directors.prefix(2)), imdbId: imdbID, imdbRating: title.imdbRating
            )
        }
    }

    private func configureLayout() {
        guard let directory = TopShelfFeedStore.containerURL else { return }
        let layout = TopShelfConfiguration.homeFeatured
        if TopShelfConfigurationStore.read(in: directory) != layout {
            TopShelfConfigurationStore.save(layout)
        }
    }

    private func publish(_ entries: [TopShelfEntry]) {
        TopShelfFeedStore.writeHomeFeatured(entries, title: String(localized: "Featured on Nuvio Cinema"))
    }

    private struct ShelfLink {
        let contentID: String
        let kind: CinemetaKind

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
        }

        func matches(_ entry: CinemetaSearchResult) -> Bool {
            entry.kind == kind && entry.title.imdbID == contentID
        }
    }

    private struct ShelfDestination: View {
        let link: ShelfLink
        let preview: CinemetaTitle?
        let onDismiss: () -> Void

        @State private var title: CinemetaTitle?
        @State private var loadFailed = false
        @State private var loadAttempt = 0

        var body: some View {
            if let title = preview ?? title {
                TitleDetailsView(title: title, kind: link.kind, onDismiss: onDismiss)
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
                        TitleLoadingSkeleton()
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
            let loaded = await CinemetaClient().details(imdbID: link.contentID, kind: link.kind)
            guard !Task.isCancelled else { return }
            title = loaded
            loadFailed = loaded == nil
        }
    }
}
#endif
