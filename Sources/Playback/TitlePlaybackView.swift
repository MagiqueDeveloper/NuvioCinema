import AVKit
import OSLog
import SwiftUI

struct CinemaPlaybackArtwork: Sendable {
    let backdropURLs: [URL]
    let logoURL: URL?
}

struct TitlePlaybackRequest: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let episode: String?
    let kind: CinemetaKind
    let videoIDs: [String]
    var position: Int64
    let addons: [NuvioAddon]
    let contentID: String
    let season: Int?
    let episodeNumber: Int?
    let profileID: Int?
    let accountID: String?
    let episodeGuide: [CinemetaEpisode]
    var metadata: CinemetaTitle? = nil
    var selectedEpisode: CinemetaEpisode? = nil
    var startupArtwork = CinemaPlaybackArtwork(backdropURLs: [], logoURL: nil)
    var startsFromBeginning = false

    var playableEpisodes: [CinemetaEpisode] {
        let now = Date.now
        return episodeGuide.filter { !$0.isUpcoming(at: now) }
    }

    var followingEpisodes: [CinemetaEpisode] {
        guard let selectedEpisode else { return [] }
        return followingEpisodes(after: selectedEpisode)
    }

    func followingEpisodes(after current: CinemetaEpisode, at date: Date = .now) -> [CinemetaEpisode] {
        Array(episodeGuide.lazy.filter {
            ($0.season, $0.episode) > (current.season, current.episode)
                && (current.season == 0 ? $0.season == 0 : $0.season > 0)
        }.prefix { !$0.isUpcoming(at: date) })
    }

    func videoIDs(for episode: CinemetaEpisode) -> [String] {
        let suffix = ":\(episode.season):\(episode.episode)"
        let catalogIDs = [metadata?.imdbID, metadata?.id].compactMap { $0 }.map { $0 + suffix }
        var seen = Set<String>()
        return ([contentID + suffix, episode.id] + catalogIDs).filter { seen.insert($0).inserted }
    }

    func changingEpisode(to episode: CinemetaEpisode, position: Int64) -> TitlePlaybackRequest {
        let label = String(localized: "S\(episode.season), E\(episode.episode) · \(episode.name)")
        return TitlePlaybackRequest(title: title, episode: label, kind: kind,
                                    videoIDs: videoIDs(for: episode), position: position, addons: addons,
                                    contentID: contentID, season: episode.season, episodeNumber: episode.episode,
                                    profileID: profileID, accountID: accountID,
                                    episodeGuide: episodeGuide, metadata: metadata, selectedEpisode: episode,
                                    startupArtwork: startupArtwork, startsFromBeginning: position == 0)
    }

    @MainActor static func resumePosition(for progress: NuvioProgress?) -> Int64? {
        progress.flatMap { NuvioAccount.hasStarted($0) && $0.fraction < 0.95 ? $0.position : nil }
    }
}

struct TitlePlaybackView: View {
    let account: NuvioAccount
    let isPresented: () -> Bool
    let onDismiss: () -> Void

    @State private var request: TitlePlaybackRequest

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedItem: FocusTarget?
    @State private var results: AddonStreamResults?
    @State private var selected: AddonStream?
    @State private var loadAttempt = 0
    @State private var playbackError: String?
    @State private var playerFailure: String?
    @State private var lastSourceID: AddonStream.ID?
    @State private var lastSourceKeys: [AddonStream.FocusKey] = []
    @State private var isOpen = false
    @State private var isClosing = false
    @State private var advancingEpisode = false

    init(request: TitlePlaybackRequest, account: NuvioAccount, isPresented: @escaping () -> Bool,
         onDismiss: @escaping () -> Void) {
        _request = State(initialValue: request)
        self.account = account
        self.isPresented = isPresented
        self.onDismiss = onDismiss
    }

    private enum FocusTarget: Hashable {
        case status, retry, source(AddonStream.ID)
    }

    private var preferredFocus: FocusTarget {
        if let lastSourceID, results?.streams.contains(where: { $0.id == lastSourceID }) == true {
            return .source(lastSourceID)
        }
        if let first = results?.streams.first { return .source(first.id) }
        return results.map { $0.failedAddons > 0 } == true ? .retry : .status
    }

    var body: some View {
        playbackContent
        .task {
            await Task.yield()
            guard !Task.isCancelled, !isClosing else { return }
            withAnimation(sheetAnimation(opening: true), completionCriteria: .removed) {
                isOpen = true
            } completion: {
                if !isClosing && focusedItem == nil { focusedItem = preferredFocus }
            }
        }
        .task(id: loadAttempt) { [loadAttempt, request] in
            for await loaded in AddonStreams().updates(addons: request.addons, kind: request.kind, videoIDs: request.videoIDs) {
                guard !Task.isCancelled, !isClosing, self.loadAttempt == loadAttempt else { return }
                let needsFocus = focusedItem == nil || focusedItem == .status || focusedItem == .retry
                if lastSourceID == nil, let stream = loaded.stream(matching: lastSourceKeys) {
                    rememberSource(stream, in: loaded)
                }
                results = loaded
                if selected == nil, needsFocus {
                    focusedItem = loaded.streams.isEmpty && !loaded.isComplete ? .status : preferredFocus
                }
            }
        }
        #if !NUVIO_UPSTREAM_PLAYER
        .fullScreenCover(item: $selected, onDismiss: restoreSourceFocus, content: player)
        #endif
        .alert("Source Unavailable", isPresented: Binding(
            get: { playbackError != nil }, set: { if !$0 { playbackError = nil } }
        )) {
            Button("Refresh Sources", action: resultsReset)
            Button("OK", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "")
        }
    }

    @ViewBuilder
    private var playbackContent: some View {
        #if NUVIO_UPSTREAM_PLAYER
        // Keep the player in the same presentation so Back is routed to its focused menu.
        ZStack {
            sourcePicker
                .disabled(selected != nil)
                .allowsHitTesting(selected == nil)
                .accessibilityHidden(selected != nil)
                .task(id: selected == nil) {
                    guard selected == nil, !isClosing else { return }
                    await Task.yield()
                    guard !Task.isCancelled, selected == nil, !isClosing, focusedItem == nil else { return }
                    focusedItem = preferredFocus
                }
            if let selected {
                player(selected)
                    .id(selected.id)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        #else
        sourcePicker
        #endif
    }

    private var sourcePicker: some View {
        GeometryReader { geometry in
            let panelWidth = min(740, geometry.size.width * 0.48)
            ZStack(alignment: .trailing) {
                Color.black.opacity(isOpen ? 0.58 : 0)
                    .accessibilityHidden(true)

                panel
                    .frame(width: panelWidth)
                    .offset(x: isOpen || reduceMotion ? 0 : panelWidth + 56)
                    .opacity(isOpen || !reduceMotion ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focusedItem, preferredFocus)
        .onExitCommand(perform: sourceExitAction)
    }

    private var sourceExitAction: (() -> Void)? {
        #if NUVIO_UPSTREAM_PLAYER
        if selected != nil { return nil }
        #endif
        return close
    }

    private func sheetAnimation(opening: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: opening ? 0.15 : 0.12) : .smooth(duration: opening ? 0.4 : 0.3)
    }

    private func selectSource(_ stream: AddonStream?) {
        #if NUVIO_UPSTREAM_PLAYER
        withAnimation(.easeInOut(duration: reduceMotion ? 0.16 : 0.28)) { selected = stream }
        #else
        selected = stream
        #endif
    }

    @ViewBuilder
    private func player(_ stream: AddonStream) -> some View {
        if case let .video(url) = stream.destination {
            #if NUVIO_UPSTREAM_PLAYER
            UpstreamPlaybackBridge(url: url, request: request, stream: stream, account: account,
                                   onClose: returnFromUpstreamPlayer, onOpenPlaybackTitle: onDismiss,
                                   onRestorePlayer: restoreUpstreamPlayer)
            #else
            StreamPlaybackScreen(url: url, request: request, stream: stream, account: account,
                                 onNext: nextEpisodeAction, onFailure: playbackFailed)
            #endif
        }
    }

    #if NUVIO_UPSTREAM_PLAYER
    private func returnFromUpstreamPlayer(_ updatedRequest: TitlePlaybackRequest, _ failure: String?) {
        guard selected != nil else { return }
        updateRequest(updatedRequest)
        playerFailure = failure
        selectSource(nil)
        restoreSourceFocus()
    }

    private func restoreUpstreamPlayer(_ stream: AddonStream, _ restoredRequest: TitlePlaybackRequest) -> Bool {
        guard isPresented(), !isClosing, selected == nil else { return false }
        updateRequest(restoredRequest)
        selectSource(stream)
        return true
    }
    #endif

    private func playbackFailed(_ failure: String) {
        playerFailure = failure
        selected = nil
    }

    private var nextEpisodeAction: (() -> Void)? {
        guard !request.followingEpisodes.isEmpty else { return nil }
        return { advanceEpisode() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            Divider()
                .padding(.horizontal, 42)

            if let results, !results.streams.isEmpty || results.isComplete {
                sourceList(results)
            } else {
                loadingSources
            }
        }
        .padding(.top, 62)
        .padding(.bottom, 52)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thickMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28))
        .focusSection()
    }

    private func sourceList(_ results: AddonStreamResults) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if results.streams.isEmpty {
                        emptyState(results)
                    } else {
                        ForEach(results.streams) { stream in
                            Button { open(stream) } label: {
                                sourceLabel(stream)
                            }
                            .buttonStyle(.card)
                            .focused($focusedItem, equals: .source(stream.id))
                            .id(stream.id)
                            .accessibilityHint(stream.destination.isExternal ? Text("Opens in another app") : Text("Plays this source"))
                        }
                        if !results.isComplete {
                            ProgressView("Checking more add-ons…")
                                .padding(.horizontal, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 42)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .task {
                guard let lastSourceID, preferredFocus == .source(lastSourceID) else { return }
                scroll.scrollTo(lastSourceID, anchor: .center)
                await Task.yield()
                guard !Task.isCancelled, !isClosing, selected == nil, preferredFocus == .source(lastSourceID) else { return }
                focusedItem = .source(lastSourceID)
            }
        }
    }

    private var loadingSources: some View {
        VStack(spacing: 18) {
            ForEach(0..<4) { row in
                HStack(alignment: .top, spacing: 20) {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.14))
                            .frame(maxWidth: row.isMultiple(of: 2) ? 250 : 310)
                            .frame(height: 18)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.09))
                            .frame(maxWidth: 120)
                            .frame(height: 13)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.07))
                            .frame(maxWidth: .infinity)
                            .frame(height: 13)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedItem, equals: .status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading sources…")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a Source")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(request.title)
                .font(.headline)
                .lineLimit(2)
            if let episode = request.episode {
                Text(episode)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 42)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(_ results: AddonStreamResults) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(emptyMessage(results))
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .focusable(results.failedAddons == 0)
                .focusEffectDisabled()
                .focused($focusedItem, equals: .status)
            if results.failedAddons > 0 {
                Button("Try Again", systemImage: "arrow.clockwise", action: resultsReset)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .focused($focusedItem, equals: .retry)
            }
        }
        .padding(.vertical, 10)
    }

    private func sourceLabel(_ stream: AddonStream) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: stream.destination.isExternal ? "arrow.up.right" : "play.fill")
                .font(.headline)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(stream.addon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let description = stream.description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func emptyMessage(_ results: AddonStreamResults) -> String {
        if !request.addons.contains(where: \.enabled) {
            return String(localized: "Link your Nuvio account and sync a profile with an enabled streaming add-on in Settings.")
        }
        if results.unsupportedStreams > 0 {
            return String(localized: "The sources returned for this title aren’t supported by the Apple TV player.")
        }
        if results.failedAddons > 0 {
            return String(localized: "Some add-ons couldn’t be reached. Try again to check for sources.")
        }
        return String(localized: "Your enabled add-ons didn’t return a source for this title.")
    }

    private func open(_ stream: AddonStream) {
        guard !isClosing else { return }
        if let results { rememberSource(stream, in: results) }
        switch stream.destination {
        case .video:
            selectSource(stream)
        case .external(let url):
            Task {
                let opened = await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
                if !opened && !isClosing { playbackError = String(localized: "No installed Apple TV app can open this link.") }
            }
        }
    }

    private func restoreSourceFocus() {
        if advancingEpisode {
            advancingEpisode = false
            guard let episode = request.followingEpisodes.first else { return }
            let saved = account.progress(for: request.contentID, kind: request.kind,
                                         season: episode.season, episode: episode.episode)
            let position = TitlePlaybackRequest.resumePosition(for: saved) ?? 0
            updateRequest(request.changingEpisode(to: episode, position: position))
            return
        }
        focusedItem = preferredFocus
        if let playerFailure {
            self.playerFailure = nil
            playbackError = playerFailure
        }
    }

    private func advanceEpisode() {
        advancingEpisode = true
        selected = nil
    }

    private func resultsReset() {
        if case let .source(id) = focusedItem, let results, let stream = results.streams.first(where: { $0.id == id }) {
            rememberSource(stream, in: results)
        }
        reloadSources()
    }

    private func rememberSource(_ stream: AddonStream, in results: AddonStreamResults) {
        lastSourceID = stream.id
        lastSourceKeys = results.focusKeys(for: stream)
    }

    private func updateRequest(_ updatedRequest: TitlePlaybackRequest) {
        let needsSources = request.contentID != updatedRequest.contentID || request.kind != updatedRequest.kind
            || request.season != updatedRequest.season || request.episodeNumber != updatedRequest.episodeNumber
            || request.videoIDs != updatedRequest.videoIDs
        request = updatedRequest
        if needsSources {
            lastSourceKeys = []
            reloadSources()
        }
    }

    private func reloadSources() {
        guard !isClosing else { return }
        lastSourceID = nil
        results = nil
        focusedItem = .status
        loadAttempt += 1
    }

    private func close() {
        guard !isClosing, selected == nil else { return }
        isClosing = true
        withAnimation(sheetAnimation(opening: false), completionCriteria: .removed) {
            isOpen = false
        } completion: {
            onDismiss()
        }
    }
}

private extension AddonStream.Destination {
    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

#if !NUVIO_UPSTREAM_PLAYER
private struct StreamPlaybackScreen: View {
    let url: URL
    let request: TitlePlaybackRequest
    let stream: AddonStream
    let account: NuvioAccount
    let onNext: (() -> Void)?
    let onFailure: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var useNativePlayer = false
    @State private var recorder = PlaybackProgressRecorder()

    private static let logger = Logger(subsystem: "com.nuviocinema.app", category: "Playback")

    var body: some View {
        Group {
            if useNativePlayer {
                NativePlaybackScreen(url: url, title: request.title, episode: request.episode,
                                     position: request.position, onBack: { dismiss() },
                                     onProgress: saveProgress) { error in
                    report(error, engine: "AVPlayer")
                }
            } else {
                AetherPlaybackView(url: url, title: request.title, episode: request.episode, position: request.position,
                                   trackPreferenceKey: .init(accountID: request.accountID, profileID: request.profileID,
                                                             contentID: request.contentID, kind: request.kind),
                                   requestHeaders: stream.requestHeaders,
                                   subtitles: stream.subtitles, loadSubtitles: loadSubtitles,
                                   onBack: { dismiss() }, onNext: onNext, onProgress: saveProgress) { error, started in
                    log(error, engine: "AetherEngine")
                    if started || stream.prefersAether || !error.allowsNativeFallback {
                        onFailure(error.localizedDescription)
                    } else {
                        useNativePlayer = true
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.flush(using: writeProgress) }
        }
        .onDisappear { recorder.flush(using: writeProgress) }
    }

    private func loadSubtitles() async -> [AddonSubtitle] {
        await AddonStreams().subtitles(addons: request.addons, kind: request.kind, videoIDs: request.videoIDs, stream: stream)
    }

    private func saveProgress(_ position: Double, _ duration: Double, _ checkpoint: PlaybackCheckpoint) {
        recorder.sample(position, duration: duration, initialPosition: request.position,
                        checkpoint: checkpoint, using: writeProgress)
    }

    private func writeProgress(_ position: Int64, _ duration: Int64, _ completed: Bool) {
        guard let profileID = request.profileID, request.accountID == account.playbackAccountID else { return }
        account.recordPlayback(contentID: request.contentID, kind: request.kind, title: request.title,
                               season: request.season, episode: request.episodeNumber, position: position,
                               duration: duration, completed: completed, profileID: profileID)
    }

    private func log(_ error: Error?, engine: String) {
        let details = error.map { $0 as NSError }
        Self.logger.error("\(engine, privacy: .public) playback failure (\(details?.domain ?? "unknown", privacy: .private), code \(details?.code ?? 0, privacy: .public))")
    }

    private func report(_ error: Error?, engine: String) {
        log(error, engine: engine)
        let details = error.map { $0 as NSError }
        if details?.domain == NSURLErrorDomain,
           [URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue,
            URLError.timedOut.rawValue].contains(details?.code ?? 0) {
            onFailure(String(localized: "The connection to this source was interrupted. Try it again or choose another source."))
        } else {
            onFailure(String(localized: "The player couldn’t open this source. Try another source, or reopen the source list to refresh the links."))
        }
    }
}

private struct NativePlaybackScreen: View {
    let url: URL
    let title: String
    let episode: String?
    let position: Int64
    let onBack: () -> Void
    let onProgress: (Double, Double, PlaybackCheckpoint) -> Void
    let onFailure: (Error?) -> Void

    @State private var player: AVPlayer?
    @State private var itemObservation: NSKeyValueObservation?
    @State private var playbackObservation: NSKeyValueObservation?
    @State private var timeObserver: Any?
    @State private var hasStarted = false
    @State private var reportedFailure = false
    @State private var itemReady = false
    @State private var restoringPosition = false

    private var startupLabel: LocalizedStringKey {
        if restoringPosition { return "Finding your saved position…" }
        if itemReady { return "Buffering the start of the video…" }
        return "Opening with Apple’s video player…"
    }

    var body: some View {
        ZStack {
            if let player {
                PlayerController(player: player, onBack: close)
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime,
                                                                   object: player.currentItem)) { note in
                        fail(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? player.currentItem?.error)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime,
                                                                   object: player.currentItem)) { _ in
                        sample(player, checkpoint: .ended)
                    }
            }
            if !hasStarted && !reportedFailure { PlaybackLoadingStatus(startupLabel) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea()
        .onExitCommand(perform: close)
        .task { await start() }
        .task(id: hasStarted) {
            guard !hasStarted else { return }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard !Task.isCancelled, !hasStarted else { return }
            fail(URLError(.timedOut))
        }
        .onDisappear {
            itemObservation = nil
            playbackObservation = nil
            if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
            if let player { sample(player, checkpoint: .flush) }
            player?.pause()
        }
    }

    private func start() async {
        let item = AVPlayerItem(url: url)
        item.externalMetadata = PlaybackMetadata.items(title: title, episode: episode)
        let player = AVPlayer(playerItem: item)
        self.player = player

        itemObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in
                guard itemObservation != nil else { return }
                itemReady = status == .readyToPlay
                if status == .failed { fail(error) }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard playbackObservation != nil else { return }
                if status == .playing { hasStarted = true }
                if status == .paused { sample(player, checkpoint: .flush) }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: .main) { _ in
            Task { @MainActor in
                if timeObserver != nil, player.timeControlStatus == .playing { sample(player, checkpoint: .periodic) }
            }
        }

        if position > 0 {
            let duration = try? await item.asset.load(.duration)
            let offset = CMTime(value: position, timescale: 1_000)
            if !Task.isCancelled, !reportedFailure, let duration, duration.isNumeric, offset < duration {
                restoringPosition = true
                await player.seek(to: offset)
                restoringPosition = false
            }
        }
        guard !Task.isCancelled, !reportedFailure else { return }
        player.play()
    }

    private func fail(_ error: Error?) {
        guard !reportedFailure else { return }
        reportedFailure = true
        if let player { sample(player, checkpoint: .flush) }
        onFailure(error)
    }

    private func close() {
        if let player { sample(player, checkpoint: .flush) }
        onBack()
    }

    private func sample(_ player: AVPlayer, checkpoint: PlaybackCheckpoint) {
        guard hasStarted, let duration = player.currentItem?.duration.seconds else { return }
        onProgress(player.currentTime().seconds, duration, checkpoint)
    }
}
#endif

enum PlaybackCheckpoint {
    case periodic, flush, seek, ended
}

@MainActor
final class PlaybackProgressRecorder {
    private var latest: (position: Int64, duration: Int64, explicitSeek: Bool)?
    private var previousPlaying: (position: Double, duration: Double, uptime: TimeInterval)?
    private var reachedEndingDuringPlayback = false
    private var secondsPlayedNearEnd: TimeInterval = 0
    private var lastSaved: Int64?
    private var lastSaveTime = ContinuousClock.now
    private var completed = false

    var resumePosition: Int64? {
        if completed { return 0 }
        return latest?.position
    }

    func sample(_ position: Double, duration: Double, initialPosition: Int64, checkpoint: PlaybackCheckpoint,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                using write: (Int64, Int64, Bool) -> Void) {
        guard !completed, position.isFinite, position >= 0, duration.isFinite, duration > 0,
              duration < 1_000_000_000 else { return }
        let length = Int64((duration * 1_000).rounded())
        let fraction = position / duration

        if checkpoint == .seek {
            previousPlaying = nil
            reachedEndingDuringPlayback = false
            secondsPlayedNearEnd = 0
        } else if checkpoint == .periodic {
            let previous = previousPlaying
            previousPlaying = (position, duration, uptime)
            if let previous, previous.position != position {
                let elapsed = uptime - previous.uptime
                let delta = position - previous.position
                let continuous = elapsed >= 0 && delta > 0 && delta <= min(4 * elapsed + 0.5, 8.5)
                    && abs(previous.duration - duration) < 2
                if !continuous {
                    reachedEndingDuringPlayback = false
                    secondsPlayedNearEnd = 0
                } else if fraction >= 0.85 {
                    if previous.position / previous.duration < 0.85 {
                        reachedEndingDuringPlayback = true
                    }
                    secondsPlayedNearEnd += min(elapsed, delta)
                }
            }
        } else if checkpoint == .flush {
            previousPlaying = nil
        }

        let playedThroughCredits = reachedEndingDuringPlayback
            && checkpoint == .periodic && duration >= 60 && fraction >= 0.90
        let playedToNaturalEnd = checkpoint == .ended
            && (reachedEndingDuringPlayback || secondsPlayedNearEnd >= 5)
            && max(fraction, (previousPlaying?.position ?? 0) / duration) >= 0.85
        if playedThroughCredits || playedToNaturalEnd {
            completed = true
            write(length, length, true)
            return
        }
        if checkpoint == .ended || fraction >= 0.90 {
            // A seek into the ending leaves the last usable resume point in place.
            if checkpoint != .periodic { flush(using: write) }
            return
        }
        guard position > 0 || checkpoint == .seek else { return }
        let offset = Int64((min(position, duration) * 1_000).rounded())
        if checkpoint != .seek, latest == nil, abs(offset - initialPosition) < 2_000 { return }
        latest = (offset, length, checkpoint == .seek)
        if checkpoint != .periodic || lastSaveTime.duration(to: .now) >= .seconds(15) {
            flush(using: write)
        }
    }

    func flush(using write: (Int64, Int64, Bool) -> Void) {
        guard !completed, let latest, latest.position >= 5_000 || latest.explicitSeek,
              latest.position != lastSaved else { return }
        write(latest.position, latest.duration, false)
        lastSaved = latest.position
        lastSaveTime = .now
    }
}

#if !NUVIO_UPSTREAM_PLAYER
enum PlaybackMetadata {
    static func items(title: String, episode: String?) -> [AVMetadataItem] {
        let values: [(AVMetadataIdentifier, String?)] = [(.commonIdentifierTitle, title), (.iTunesMetadataTrackSubTitle, episode)]
        return values.compactMap { identifier, value in
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as? AVMetadataItem
        }
    }
}

struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let onBack: () -> Void
    var aetherActions: AetherActions?

    struct AetherActions {
        let controlsEnabled: Bool
        let pictureReady: () -> Void
        let transportVisibilityChanged: (Bool) -> Void
        let subtitles: () -> Void
        let skip: ContextAction?
        let next: ContextAction?
    }

    struct ContextAction {
        let id: String
        let title: String
        let perform: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = false
        if aetherActions != nil {
            controller.appliesPreferredDisplayCriteriaAutomatically = false
            controller.transportBarCustomMenuItems = [
                UIAction(title: String(localized: "Subtitle Tools"), image: UIImage(systemName: "captions.bubble")) { [weak coordinator = context.coordinator] _ in
                    coordinator?.aetherActions?.subtitles()
                },
            ]
        }
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onBack = onBack
        coordinator.aetherActions = aetherActions
        if controller.player !== player {
            controller.player = player
            if aetherActions != nil { coordinator.observeFirstPicture(of: controller) }
        }
        if let aetherActions {
            if controller.view.isUserInteractionEnabled != aetherActions.controlsEnabled {
                controller.view.isUserInteractionEnabled = aetherActions.controlsEnabled
                controller.setNeedsFocusUpdate()
            }
            let actions = [aetherActions.skip, aetherActions.next].compactMap { $0 }
            let ids = actions.map(\.id)
            if coordinator.contextActionIDs != ids {
                coordinator.contextActionIDs = ids
                controller.contextualActions = actions.map { action in
                    UIAction(title: action.title, identifier: UIAction.Identifier(action.id)) { [weak coordinator] _ in
                        [coordinator?.aetherActions?.skip, coordinator?.aetherActions?.next]
                            .compactMap { $0 }.first { $0.id == action.id }?.perform()
                    }
                }
            }
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.firstPictureTask?.cancel()
        controller.delegate = nil
        controller.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onBack: (() -> Void)?
        var aetherActions: AetherActions?
        var contextActionIDs: [String] = []
        var firstPictureTask: Task<Void, Never>?

        func observeFirstPicture(of controller: AVPlayerViewController) {
            firstPictureTask?.cancel()
            firstPictureTask = Task { [weak self, weak controller] in
                for _ in 0..<450 {
                    guard !Task.isCancelled, let controller else { return }
                    if controller.isReadyForDisplay {
                        self?.aetherActions?.pictureReady()
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              willTransitionToVisibilityOfTransportBar visible: Bool,
                                              with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
            Task { @MainActor in aetherActions?.transportVisibilityChanged(visible) }
        }

        nonisolated func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            Task { @MainActor in onBack?() }
            return false
        }
    }
}
#endif
