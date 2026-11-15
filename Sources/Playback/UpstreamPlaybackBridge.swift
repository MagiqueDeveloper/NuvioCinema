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
    @State private var recorder = PlaybackProgressRecorder()
    @State private var recordingEpisode: NuvioVideo?
    @State private var isMounted = false
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
        _viewModel = StateObject(wrappedValue: Self.makeViewModel(for: request))
    }

    private static func makeViewModel(for request: TitlePlaybackRequest) -> PlayerViewModel {
        let viewModel = PlayerViewModel()
        let accountID = request.accountID ?? ""
        let profileID = request.profileID.map(String.init) ?? "guest"
        viewModel.configureTitleSubtitlePreferences(profileScope: "\(accountID.utf8.count):\(accountID):\(profileID)")
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
        [currentEpisode].compactMap { $0 } + request.followingEpisodes.map(Self.video)
    }

    private var activeEpisodeID: String? {
        viewModel.panelCurrentEpisodeId ?? currentEpisode?.id
    }

    private var canRecordProgress: Bool {
        viewModel.hasRenderedFirstFrame && !viewModel.isAwaitingStreamStart && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek && !viewModel.isSwitchingSource && !viewModel.isReloadingStream
            && !viewModel.didDetectReplacementStream && !viewModel.isLiveStream
            && !viewModel.sessionCoordinator.isProgressSaveSuspended
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
            sourceID: url.absoluteString, episodes: episodes, currentEpisode: currentEpisode,
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
        .onAppear { isMounted = true }
        .onReceive(viewModel.clock.$position) { position in
            guard viewModel.status == .playing, canRecordProgress else { return }
            sample(position, duration: viewModel.clock.duration, checkpoint: .periodic)
        }
        .onReceive(viewModel.$status) { status in
            guard canRecordProgress else { return }
            if status == .ended {
                sample(viewModel.clock.position, duration: viewModel.clock.duration, checkpoint: .ended)
            } else if status == .paused {
                sample(viewModel.clock.position, duration: viewModel.clock.duration, checkpoint: .flush)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushProgress() }
        }
        .task { await mergeInitialSubtitles() }
        .onDisappear {
            isMounted = false
            flushProgress()
            let manager = PictureInPictureManager.shared
            if !manager.isPictureInPictureActive {
                UpstreamPiPRestore.remove(owner: restoreID, from: manager)
            }
        }
    }

    private func sample(_ position: Double, duration: Double, checkpoint: PlaybackCheckpoint) {
        let activeEpisode = episodes.first { $0.id == activeEpisodeID } ?? currentEpisode
        if activeEpisode?.id != recordingEpisode?.id {
            flushProgress()
            recordingEpisode = activeEpisode
            recorder = PlaybackProgressRecorder()
        }
        let initialPosition = activeEpisode?.id == currentEpisode?.id ? request.position : 0
        recorder.sample(position, duration: duration, initialPosition: initialPosition, checkpoint: checkpoint,
                        using: writeProgress)
    }

    private func flushProgress() {
        recorder.flush(using: writeProgress)
    }

    private func writeProgress(_ position: Int64, _ duration: Int64, _ completed: Bool) {
        guard let profileID = request.profileID, request.accountID == account.playbackAccountID else { return }
        let episode = recordingEpisode ?? currentEpisode
        account.recordPlayback(
            contentID: request.contentID, kind: request.kind, title: request.title,
            season: episode?.season, episode: episode?.episode, position: position,
            duration: duration, completed: completed, profileID: profileID
        )
    }

    private func close() {
        flushProgress()
        let manager = PictureInPictureManager.shared
        if manager.isPictureInPictureActive,
           manager.activeCoordinator === viewModel.sessionCoordinator, let onRestorePlayer {
            UpstreamPiPRestore.install(owner: restoreID, manager: manager, request: request, stream: stream,
                                       restore: onRestorePlayer)
        }
        onClose(sourceRequest(), nil)
    }

    private func returnToSources() {
        flushProgress()
        if case .error = viewModel.status {
            onClose(sourceRequest(), String(localized: "This source couldn’t play on Apple TV. Try another source or refresh the links."))
        } else {
            onClose(sourceRequest(), nil)
        }
    }

    private func openPlaybackTitle() {
        flushProgress()
        onOpenPlaybackTitle()
    }

    private func sourceRequest() -> TitlePlaybackRequest {
        // During a switch the recorder still belongs to the previous episode until
        // the replacement stream produces a valid time sample.
        let position = recordingEpisode?.id == activeEpisodeID ? recorder.resumePosition : nil
        if let episode = request.followingEpisodes.first(where: { $0.id == activeEpisodeID }),
           let advanced = request.advancing(to: episode, position: position ?? 0) {
            return advanced
        }
        var updated = request
        updated.position = position ?? request.position
        return updated
    }

    private func mergeInitialSubtitles() async {
        let tracks = await AddonStreams().subtitles(
            addons: request.addons, kind: request.kind, videoIDs: request.videoIDs, stream: stream
        )
        guard !Task.isCancelled, isMounted, !viewModel.isSwitchingSource, !viewModel.isReloadingStream,
              viewModel.panelCurrentEpisodeId == currentEpisode?.id,
              viewModel.sessionCoordinator.lastRequest?.videoURL == url else { return }
        viewModel.mergeExternalSubtitles(Self.subtitles(tracks))
    }

    private func resolveNextStream(_ episode: NuvioVideo, _ startupToken: UUID?) async -> PreparedNextStream? {
        let result = await findSources(for: episode.id)
        let preferred = result.first { $0.addon == stream.addon } ?? result.first
        guard !Task.isCancelled, let preferred else { return nil }
        return await prepare(preferred, videoIDs: videoIDs(for: episode.id), subtitle: Self.episodeLabel(episode))
    }

    private func reloadCurrentStream(_ episode: NuvioVideo?, _ excludedURLs: [String]) async -> PreparedNextStream? {
        let result = await findSources(for: episode?.id ?? request.contentID)
        let excluded = Set(excludedURLs)
        let alternative = result.first {
            guard case .video(let url) = $0.destination else { return false }
            return !excluded.contains(url.absoluteString)
        }
        guard !Task.isCancelled, let alternative else { return nil }
        return await prepare(alternative, videoIDs: videoIDs(for: episode?.id ?? request.contentID),
                             subtitle: episode.map(Self.episodeLabel) ?? "")
    }

    private func fetchPlaybackSources(_ contentID: String, _ type: String) -> AsyncStream<[NuvioStream]> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let result = await findSources(for: contentID)
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                var seen = Set<URL>()
                let sources = result.compactMap { stream -> NuvioStream? in
                    guard case .video(let url) = stream.destination, seen.insert(url).inserted else { return nil }
                    return NuvioStream(
                        url: url.absoluteString, name: stream.name, description: stream.description, addonName: stream.addon,
                        subtitles: Self.subtitles(stream.subtitles, source: stream.addon), filename: stream.filename,
                        videoSize: stream.videoSize, videoHash: stream.videoHash, httpHeaders: stream.requestHeaders
                    )
                }
                continuation.yield(sources)
                continuation.finish()
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
        return await prepare(selected, videoIDs: videoIDs(for: contentID), subtitle: subtitle)
    }

    private func findSources(for contentID: String) async -> [AddonStream] {
        let result = await AddonStreams().load(addons: request.addons, kind: request.kind, videoIDs: videoIDs(for: contentID))
        return result.streams.filter {
            if case .video = $0.destination { return true }
            return false
        }
    }

    private func videoIDs(for contentID: String) -> [String] {
        guard let episode = request.followingEpisodes.first(where: { $0.id == contentID }) else {
            return request.videoIDs
        }
        return request.videoIDs(for: episode)
    }

    private func prepare(_ stream: AddonStream, videoIDs: [String], subtitle: String) async -> PreparedNextStream? {
        guard case .video(let sourceURL) = stream.destination else { return nil }
        let matches = await AddonStreams().subtitles(
            addons: request.addons, kind: request.kind, videoIDs: videoIDs, stream: stream
        )
        guard !Task.isCancelled else { return nil }
        var seen = Set<String>()
        let subtitles = (Self.subtitles(stream.subtitles, source: stream.addon) + Self.subtitles(matches))
            .filter { seen.insert($0.url).inserted }
        return PreparedNextStream(
            url: sourceURL, httpHeaders: stream.requestHeaders, subtitleLine: subtitle,
            subtitles: subtitles, streamName: stream.name, streamDescription: stream.description,
            filename: stream.filename, addonName: stream.addon, videoSize: stream.videoSize, videoHash: stream.videoHash,
            provider: "Direct", sourceID: sourceURL.absoluteString
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
private enum UpstreamPiPRestore {
    private static var owner: UUID?

    static func install(
        owner: UUID, manager: PictureInPictureManager, request: TitlePlaybackRequest, stream: AddonStream,
        restore: @escaping (AddonStream, TitlePlaybackRequest) -> Bool
    ) {
        self.owner = owner
        manager.onRestoreUI = { [weak manager] context, completion in
            guard let manager, self.owner == owner else {
                completion(false)
                return
            }
            guard let restored = restoredSession(context: context, request: request, stream: stream, manager: manager),
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
        context: ActivePlaybackContext, request: TitlePlaybackRequest, stream: AddonStream,
        manager: PictureInPictureManager
    ) -> (stream: AddonStream, request: TitlePlaybackRequest)? {
        guard context.meta.id == request.contentID, UpstreamPlaybackBridge.isHTTPS(context.url) else { return nil }
        let position = max(0, manager.activeCoordinator?.activeEngine.positionMs ?? request.position)
        var restoredRequest = request
        if let current = context.currentEpisode,
           current.season != request.season || current.episode != request.episodeNumber {
            guard let episode = request.followingEpisodes.first(where: { $0.id == current.id }),
                  let advanced = request.advancing(to: episode, position: position) else { return nil }
            restoredRequest = advanced
        }
        restoredRequest.position = position
        let restoredStream = AddonStream(
            id: stream.destination == .video(context.url) ? stream.id : UUID(),
            addon: stream.addon, name: stream.name, description: stream.description,
            filename: context.filename, videoHash: context.videoHash, videoSize: context.videoSize,
            notWebReady: stream.notWebReady,
            subtitles: context.externalSubtitles.compactMap(UpstreamPlaybackBridge.addonSubtitle),
            destination: .video(context.url), requestHeaders: context.httpHeaders
        )
        return (restoredStream, restoredRequest)
    }
}
#endif
