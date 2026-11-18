#if NUVIO_UPSTREAM_PLAYER
import SwiftUI

struct UpstreamPlaybackBridge: View {
    let url: URL
    let request: TitlePlaybackRequest
    let stream: AddonStream
    let account: NuvioAccount
    let onClose: (TitlePlaybackRequest, String?) -> Void
    let onOpenPlaybackTitle: () -> Void
    var onRestorePlayer: ((AddonStream, TitlePlaybackRequest) -> Bool)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: PlayerViewModel
    @State private var restoreID = UUID()

    init(url: URL, request: TitlePlaybackRequest, stream: AddonStream, account: NuvioAccount,
         onClose: @escaping (TitlePlaybackRequest, String?) -> Void,
         onOpenPlaybackTitle: @escaping () -> Void,
         onRestorePlayer: ((AddonStream, TitlePlaybackRequest) -> Bool)? = nil) {
        self.url = url
        self.request = request
        self.stream = stream
        self.account = account
        self.onClose = onClose
        self.onOpenPlaybackTitle = onOpenPlaybackTitle
        self.onRestorePlayer = onRestorePlayer
        _viewModel = StateObject(wrappedValue: Self.makeViewModel(for: request, account: account))
    }

    private static func makeViewModel(for request: TitlePlaybackRequest, account: NuvioAccount) -> PlayerViewModel {
        let viewModel = PlayerViewModel()
        let accountID = request.accountID ?? ""
        let profileID = request.profileID.map(String.init) ?? "guest"
        viewModel.configureTitleSubtitlePreferences(profileScope: "\(accountID.utf8.count):\(accountID):\(profileID)")
        viewModel.sessionCoordinator.cinemaProgress = CinemaPlaybackProgressSession(request: request, account: account)
        viewModel.cinemaNextEpisode = { current in
            guard let episode = request.episodeGuide.first(where: {
                $0.season == current.season && $0.episode == current.episode
            }) else { return nil }
            return request.followingEpisodes(after: episode).first.map(Self.video)
        }
        viewModel.cinemaSubtitleLoader = { episode, stream in
            let videoIDs: [String]
            if let episode, episode.id != request.selectedEpisode?.id,
               let item = request.episodeGuide.first(where: { $0.id == episode.id }) {
                videoIDs = request.videoIDs(for: item)
            } else {
                videoIDs = request.videoIDs
            }
            let tracks = await AddonStreams().subtitles(
                addons: request.addons, kind: request.kind, videoIDs: videoIDs, stream: stream
            )
            return Self.subtitles(tracks)
        }
        return viewModel
    }

    private var currentEpisode: NuvioVideo? {
        if let episode = request.selectedEpisode { return Self.video(episode) }
        guard let season = request.season, let number = request.episodeNumber else { return nil }
        let id = request.videoIDs.first ?? "\(request.contentID):\(season):\(number)"
        return NuvioVideo(id: id, title: request.episode ?? String(localized: "Episode \(number)"),
                          season: season, episode: number)
    }

    private var episodes: [NuvioVideo] {
        var playable = request.playableEpisodes.map(Self.video)
        if let currentEpisode {
            if let index = playable.firstIndex(where: {
                $0.season == currentEpisode.season && $0.episode == currentEpisode.episode
            }) {
                playable[index] = currentEpisode
            } else {
                playable.insert(currentEpisode, at: 0)
            }
        }
        return playable
    }

    private var activeEpisode: NuvioVideo? {
        episodes.first { $0.id == viewModel.panelCurrentEpisodeId } ?? currentEpisode
    }

    private var progress: CinemaPlaybackProgressSession? {
        viewModel.sessionCoordinator.cinemaProgress
    }

    private var meta: NuvioMeta {
        let title = request.metadata
        let imdbID = title?.imdbID ?? NuvioMeta.canonicalImdbID(from: request.contentID)
        return NuvioMeta(
            id: request.contentID, name: request.title, description: title?.description,
            posterUrl: BetterPosters.url(for: imdbID)?.absoluteString, backgroundUrl: title?.background?.absoluteString,
            logoUrl: title?.logo?.absoluteString, imdbId: imdbID,
            type: request.kind.rawValue, year: title?.releaseYear.flatMap(Int.init), genres: title?.genres,
            rating: title?.imdbRating, releaseInfo: title?.releaseInfo, runtime: title?.runtime,
            cast: title?.cast, director: title?.directors, writer: title?.writers,
            certification: title?.contentRating, country: title?.countries.first,
            language: title?.languages.first, released: title?.released?.formatted(.iso8601),
            status: title?.status, videos: episodes
        )
    }

    var body: some View {
        PlayerView(
            url: url, meta: meta, subtitle: currentEpisode.map(Self.episodeLabel) ?? "",
            httpHeaders: stream.requestHeaders,
            externalSubtitles: Self.subtitles(stream.subtitles, source: stream.addon),
            resumeFrom: request.position > 0 || request.startsFromBeginning ? Double(request.position) / 1_000 : nil,
            addonName: stream.addon, provider: "Direct",
            filename: stream.filename, videoSize: stream.videoSize, videoHash: stream.videoHash,
            sourceID: stream.playbackSourceID, episodes: episodes, currentEpisode: currentEpisode,
            resolveNextStream: episodes.count > 1 ? resolveNextStream : nil,
            reloadCurrentStream: reloadCurrentStream,
            fetchPlaybackSources: fetchPlaybackSources,
            resolvePlaybackStream: resolvePlaybackStream,
            onRequestSources: returnToSources,
            onOpenPlaybackTitle: openPlaybackTitle,
            viewModel: viewModel,
            onBack: close,
            onRemoteBack: close
        )
        .environment(\.cinemaPlaybackArtwork, request.startupArtwork)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { progress?.flush() }
        }
        .onDisappear {
            progress?.flush()
            let manager = PictureInPictureManager.shared
            if !manager.isPictureInPictureActive {
                UpstreamPiPRestore.remove(owner: restoreID, from: manager)
            }
        }
    }

    private func close() {
        progress?.flush()
        let manager = PictureInPictureManager.shared
        if manager.isPictureInPictureActive,
           manager.activeCoordinator === viewModel.sessionCoordinator, let onRestorePlayer {
            progress?.startPictureInPicture(coordinator: viewModel.sessionCoordinator, episode: activeEpisode)
            UpstreamPiPRestore.install(owner: restoreID, manager: manager, request: request, stream: stream,
                                       addon: viewModel.cinemaActiveAddon ?? stream.addon,
                                       restore: onRestorePlayer)
            viewModel.detachCinemaForPictureInPicture()
        }
        onClose(sourceRequest(), nil)
    }

    private func returnToSources() {
        progress?.flush()
        if case .error = viewModel.status {
            onClose(sourceRequest(), String(localized: "This source couldn’t play on Apple TV. Try another source or refresh the links."))
        } else {
            onClose(sourceRequest(), nil)
        }
    }

    private func openPlaybackTitle() {
        progress?.flush()
        onOpenPlaybackTitle()
    }

    private func sourceRequest() -> TitlePlaybackRequest {
        let episode = activeEpisode
        let position = progress?.resumePosition(for: episode)
        if episode?.id != currentEpisode?.id,
           let selected = request.episodeGuide.first(where: { $0.id == episode?.id }) {
            return request.changingEpisode(to: selected, position: position ?? progress?.savedResume(for: episode) ?? 0)
        }
        var updated = request
        if let position {
            updated.position = position
            updated.startsFromBeginning = position == 0
        }
        return updated
    }

    private func resolveNextStream(_ episode: NuvioVideo, _ startupToken: UUID?) async -> PreparedNextStream? {
        let activeAddon = viewModel.cinemaActiveAddon ?? stream.addon
        let result = await findSources(for: episode.id)
        let preferred = result.first { $0.addon == activeAddon } ?? result.first
        guard !Task.isCancelled, let preferred else { return nil }
        return prepare(preferred, subtitle: Self.episodeLabel(episode))
    }

    private func reloadCurrentStream(_ episode: NuvioVideo?, _ excludedSourceIDs: [String]) async -> PreparedNextStream? {
        let result = await findSources(for: episode?.id ?? request.contentID)
        let excluded = Set(excludedSourceIDs)
        let alternative = result.first { !excluded.contains($0.playbackSourceID) }
        guard !Task.isCancelled, let alternative else { return nil }
        return prepare(alternative, subtitle: episode.map(Self.episodeLabel) ?? "")
    }

    private func fetchPlaybackSources(_ contentID: String, _ type: String) -> AsyncStream<[NuvioStream]> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                defer { continuation.finish() }
                let updates = AddonStreams().updates(
                    addons: request.addons, kind: request.kind, videoIDs: videoIDs(for: contentID)
                )
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    let sources = update.streams.compactMap { stream -> NuvioStream? in
                        guard case .video(let url) = stream.destination else { return nil }
                        return NuvioStream(
                            url: url.absoluteString, name: stream.name, description: stream.description, addonName: stream.addon,
                            subtitles: Self.subtitles(stream.subtitles, source: stream.addon), filename: stream.filename,
                            videoSize: stream.videoSize, videoHash: stream.videoHash, httpHeaders: stream.requestHeaders,
                            cinemaSourceID: stream.playbackSourceID
                        )
                    }
                    continuation.yield(sources)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolvePlaybackStream(
        _ source: NuvioStream, _ contentID: String, _ subtitle: String, _ startupToken: UUID?
    ) async -> PreparedNextStream? {
        guard let sourceURL = source.directURL.flatMap(URL.init(string:)), Self.isHTTPS(sourceURL) else { return nil }
        let selected = AddonStream(
            id: UUID(), addon: source.addonName ?? "", name: source.name ?? "", description: source.description,
            filename: source.filename, videoHash: source.videoHash, videoSize: source.videoSize, notWebReady: false,
            subtitles: source.subtitles.compactMap(Self.addonSubtitle), destination: .video(sourceURL),
            requestHeaders: source.httpHeaders ?? [:]
        )
        return prepare(selected, subtitle: subtitle)
    }

    private func findSources(for contentID: String) async -> [AddonStream] {
        let result = await AddonStreams().load(addons: request.addons, kind: request.kind, videoIDs: videoIDs(for: contentID))
        return result.streams.filter {
            if case .video = $0.destination { return true }
            return false
        }
    }

    private func videoIDs(for contentID: String) -> [String] {
        guard contentID != currentEpisode?.id, let episode = request.episodeGuide.first(where: { $0.id == contentID }) else {
            return request.videoIDs
        }
        return request.videoIDs(for: episode)
    }

    private func prepare(_ stream: AddonStream, subtitle: String) -> PreparedNextStream? {
        guard case .video(let sourceURL) = stream.destination else { return nil }
        var seen = Set<String>()
        let subtitles = Self.subtitles(stream.subtitles, source: stream.addon)
            .filter { seen.insert($0.url).inserted }
        return PreparedNextStream(
            url: sourceURL, httpHeaders: stream.requestHeaders, subtitleLine: subtitle,
            subtitles: subtitles, streamName: stream.name, streamDescription: stream.description,
            filename: stream.filename, addonName: stream.addon, videoSize: stream.videoSize, videoHash: stream.videoHash,
            provider: "Direct", sourceID: stream.playbackSourceID
        )
    }

    private static func video(_ episode: CinemetaEpisode) -> NuvioVideo {
        NuvioVideo(id: episode.id, title: episode.name, season: episode.season, episode: episode.episode,
                   thumbnail: episode.thumbnail?.absoluteString, overview: episode.overview,
                   released: episode.releasedAt?.formatted(.iso8601))
    }

    private static func episodeLabel(_ episode: NuvioVideo) -> String {
        "S\(episode.season) · E\(episode.episode) · \(episode.title)"
    }

    fileprivate static func subtitles(_ tracks: [AddonSubtitle], source: String? = nil) -> [NuvioSubtitle] {
        tracks.filter(\.isHTTPS).map {
            NuvioSubtitle(url: $0.url.absoluteString, language: $0.lang ?? "und", label: $0.name, source: $0.source ?? source)
        }
    }

    fileprivate static func addonSubtitle(_ track: NuvioSubtitle) -> AddonSubtitle? {
        guard let url = URL(string: track.url), isHTTPS(url) else { return nil }
        return AddonSubtitle(url: url, lang: track.language, name: track.label, source: track.source)
    }

    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host() != nil && url.user() == nil && url.password() == nil
    }
}

@MainActor
final class CinemaPlaybackProgressSession {
    private let request: TitlePlaybackRequest
    private weak var account: NuvioAccount?
    private var recordingEpisode: NuvioVideo?
    private var recorder = PlaybackProgressRecorder()
    private var initialPosition: Int64
    private var pipTask: Task<Void, Never>?
    private var pipEpisode: NuvioVideo?

    init(request: TitlePlaybackRequest, account: NuvioAccount) {
        self.request = request
        self.account = account
        initialPosition = request.position
    }

    var isCurrentProfile: Bool {
        guard let account else { return false }
        return account.playbackAccountID == request.accountID && account.profileID == request.profileID
    }

    func matches(_ session: CinemaPlaybackProgressSession?) -> Bool {
        guard let session else { return false }
        return request.accountID == session.request.accountID && request.profileID == session.request.profileID
            && request.contentID == session.request.contentID && request.kind == session.request.kind
    }

    func savedResume(for episode: NuvioVideo?) -> Int64? {
        guard isCurrentProfile, let account else { return nil }
        return TitlePlaybackRequest.resumePosition(for: account.progress(
            for: request.contentID, kind: request.kind, season: episode?.season, episode: episode?.episode
        ))
    }

    func resumePosition(for episode: NuvioVideo?) -> Int64? {
        recordingEpisode?.id == episode?.id ? recorder.resumePosition : nil
    }

    func sample(_ position: Double, duration: Double, episode: NuvioVideo?, checkpoint: PlaybackCheckpoint) {
        guard isCurrentProfile else { return }
        if recordingEpisode?.id != episode?.id {
            flush()
            recordingEpisode = episode
            recorder = PlaybackProgressRecorder()
            if episode?.season == request.season && episode?.episode == request.episodeNumber {
                initialPosition = request.position
            } else {
                initialPosition = savedResume(for: episode) ?? 0
            }
        }
        recorder.sample(position, duration: duration, initialPosition: initialPosition, checkpoint: checkpoint,
                        using: write)
    }

    func flush() {
        recorder.flush(using: write)
    }

    private func write(_ position: Int64, _ duration: Int64, _ completed: Bool) {
        guard isCurrentProfile, let account, let profileID = request.profileID else { return }
        account.recordPlayback(
            contentID: request.contentID, kind: request.kind, title: request.title,
            season: recordingEpisode?.season, episode: recordingEpisode?.episode, position: position,
            duration: duration, completed: completed, profileID: profileID
        )
    }

    func startPictureInPicture(coordinator: PlaybackSessionCoordinator, episode: NuvioVideo?) {
        pipTask?.cancel()
        pipEpisode = episode
        pipTask = Task { @MainActor [weak self, weak coordinator] in
            while !Task.isCancelled {
                guard let coordinator, let self,
                      PictureInPictureManager.shared.activeCoordinator === coordinator else { return }
                self.samplePictureInPicture(coordinator: coordinator)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopPictureInPicture(coordinator: PlaybackSessionCoordinator) {
        guard pipTask != nil else { return }
        pipTask?.cancel()
        pipTask = nil
        samplePictureInPicture(coordinator: coordinator)
        pipEpisode = nil
        flush()
    }

    private func samplePictureInPicture(coordinator: PlaybackSessionCoordinator) {
        guard isCurrentProfile, !coordinator.isProgressSaveSuspended,
              coordinator.lastRequest?.isLiveStream == false else { return }
        let engine = coordinator.activeEngine
        engine.refreshPlaybackState()
        guard engine.hasCoherentTimeSample, !engine.isPlayerLoading, engine.currentErrorMessage.isEmpty else { return }
        let checkpoint: PlaybackCheckpoint
        if engine.isPlayerEnded && engine.isAtEndOfFile {
            checkpoint = .ended
        } else if engine.isPlayerPlaying {
            checkpoint = .periodic
        } else {
            checkpoint = .flush
        }
        sample(Double(engine.positionMs) / 1_000, duration: Double(engine.durationMs) / 1_000,
               episode: pipEpisode, checkpoint: checkpoint)
    }
}

@MainActor
private enum UpstreamPiPRestore {
    private static var owner: UUID?

    static func install(
        owner: UUID, manager: PictureInPictureManager, request: TitlePlaybackRequest, stream: AddonStream, addon: String,
        restore: @escaping (AddonStream, TitlePlaybackRequest) -> Bool
    ) {
        self.owner = owner
        manager.onRestoreUI = { [weak manager] context, completion in
            guard let manager, self.owner == owner else {
                completion(false)
                return
            }
            guard manager.activeCoordinator?.cinemaProgress?.isCurrentProfile == true,
                  let restored = restoredSession(context: context, request: request, stream: stream,
                                                 addon: addon, manager: manager),
                  restore(restored.stream, restored.request) else {
                remove(owner: owner, from: manager)
                completion(false)
                return
            }
            remove(owner: owner, from: manager)
            completion(true)
        }
        manager.onDidStopPiPWithoutRestoring = { [weak manager] in
            guard let manager, self.owner == owner else { return }
            if let coordinator = manager.activeCoordinator {
                coordinator.cinemaProgress?.stopPictureInPicture(coordinator: coordinator)
                PlaybackWakeLock.release(ownerID: coordinator.wakeLockOwnerID)
            }
            remove(owner: owner, from: manager)
        }
    }

    static func remove(owner: UUID, from manager: PictureInPictureManager) {
        guard self.owner == owner else { return }
        self.owner = nil
        manager.onRestoreUI = nil
        manager.onDidStopPiPWithoutRestoring = nil
    }

    private static func restoredSession(
        context: ActivePlaybackContext, request: TitlePlaybackRequest, stream: AddonStream, addon: String,
        manager: PictureInPictureManager
    ) -> (stream: AddonStream, request: TitlePlaybackRequest)? {
        guard context.meta.id == request.contentID, UpstreamPlaybackBridge.isHTTPS(context.url) else { return nil }
        let position = max(0, manager.activeCoordinator?.activeEngine.positionMs ?? request.position)
        var restoredRequest = request
        if let current = context.currentEpisode,
           current.season != request.season || current.episode != request.episodeNumber {
            guard let episode = request.episodeGuide.first(where: { $0.id == current.id }) else { return nil }
            restoredRequest = request.changingEpisode(to: episode, position: position)
        }
        restoredRequest.position = position
        restoredRequest.startsFromBeginning = position == 0
        let restoredStream = AddonStream(
            id: stream.destination == .video(context.url) ? stream.id : UUID(),
            addon: addon, name: stream.name, description: stream.description,
            filename: context.filename, videoHash: context.videoHash, videoSize: context.videoSize,
            notWebReady: stream.notWebReady,
            subtitles: context.externalSubtitles.compactMap(UpstreamPlaybackBridge.addonSubtitle),
            destination: .video(context.url), requestHeaders: context.httpHeaders
        )
        return (restoredStream, restoredRequest)
    }
}
#endif
