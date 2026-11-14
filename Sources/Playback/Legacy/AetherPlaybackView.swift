import AetherEngine
import AVFoundation
import MediaPlayer
import SwiftUI

struct AetherPlaybackView: View {
    let url: URL
    let title: String
    let episode: String?
    let position: Int64
    let trackPreferenceKey: PlaybackTrackPreferences.Key
    let requestHeaders: [String: String]
    let subtitles: [AddonSubtitle]
    let loadSubtitles: () async -> [AddonSubtitle]
    let onBack: () -> Void
    let onNext: (() -> Void)?
    let onProgress: (Double, Double, PlaybackCheckpoint) -> Void
    let onFailure: (PlaybackFailure, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AetherPlaybackOptions.seekIntervalKey) private var seekInterval = AetherPlaybackOptions.defaultSeekInterval
    @FocusState private var focus: Control?
    @State private var engine: AetherEngine?
    @State private var playbackState: PlaybackState = .idle
    @State private var playbackPhase: PlaybackPhase = .idle
    @State private var startupProgress: StartupProgress?
    @State private var isAwaitingDisplaySwitch = false
    @State private var hasPicture = false
    @State private var nativePlayer: AVPlayer?
    @State private var nativePictureReady = false
    @State private var nativeTransportVisible = false
    @State private var videoRoute: VideoRoute = .none
    @State private var isSessionReady = false
    @State private var seekTask: Task<Void, Never>?
    @State private var showsControls = false
    @State private var interaction = UUID()
    @State private var playAttempt = 0
    @State private var isClosing = false
    @State private var showsSubtitlePanel = false
    @State private var subtitleDelay = 0.0
    @State private var subtitleRate = 1.0
    @State private var isScrubbing = false
    @State private var hasStarted = false
    @State private var addonSubtitles: [AddonSubtitle] = []
    @State private var registeredSubtitleURLs = Set<URL>()
    @State private var subtitleSyncTask: Task<Void, Never>?
    @State private var subtitleSyncStatus: String?
    @State private var selectedSubtitleID: Int?
    @State private var availableSubtitleTracks: [TrackInfo] = []
    @State private var restoredAudio = false
    @State private var restoredSubtitles = false
    @State private var skipChapter: ChapterInfo?

    private enum Control: Hashable {
        case picture, scrubber, playPause, subtitles, next, skip
    }

    private var playerForAVKit: AVPlayer? {
        guard videoRoute == .loopback || videoRoute == .remoteBypass else { return nil }
        return nativePlayer
    }

    private var isReady: Bool {
        if let player = playerForAVKit { return nativePictureReady || (player.isExternalPlaybackActive && isSessionReady) }
        return hasPicture || startupProgress?.isComplete == true || (videoRoute == .audio && isSessionReady)
    }

    private var isOpening: Bool {
        !hasStarted && !isReady && playbackState != .ended && !isClosing
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if let engine {
                playerSurface(engine)
                    .onReceive(engine.$hasFirstFrameReadyForDisplay) { hasPicture = $0; updateStarted() }
                    .onReceive(engine.$videoRoute) { videoRoute = $0; updateStarted() }
                    .onReceive(engine.$currentAVPlayer, perform: nativePlayerChanged)
                    .onReceive(engine.$isSessionReady) { isSessionReady = $0; updateStarted() }
                    .onReceive(engine.$playbackPhase) { playbackPhase = $0; updateStarted() }
                    .onReceive(engine.$startupProgress) { startupProgress = $0; updateStarted() }
                    .onReceive(engine.$isAwaitingDisplaySwitch) { isAwaitingDisplaySwitch = $0 }
                    .onReceive(engine.$subtitleTracks) { availableSubtitleTracks = $0 }
                    .onChange(of: availableSubtitleTracks) { _, _ in restoreTrackChoices(in: engine) }
                    .onReceive(engine.$activeSubtitleTrackIndex, perform: subtitleSelectionChanged)
                    .onChange(of: selectedSubtitleID) { _, id in
                        guard id != nil, (PlaybackTrackPreferences.subtitle(for: trackPreferenceKey) ?? .off) == .off else { return }
                        engine.clearSubtitle()
                    }
                    .onReceive(engine.clock.$currentTime) { time in
                        if hasStarted, playbackState == .playing, !engine.isSeeking {
                            onProgress(time, engine.duration, .periodic)
                            let chapter = skippableChapter(at: time, in: engine)
                            if skipChapter != chapter { skipChapter = chapter }
                        }
                    }
                    .onReceive(engine.$state) { state in
                        playbackState = state
                        if state == .ended { savePosition(engine, checkpoint: .ended) }
                        if state == .paused { savePosition(engine, checkpoint: .flush) }
                        if case .error = state {
                            fail(PlaybackFailure(info: engine.errorInfo))
                        }
                    }

                AetherPlaybackSubtitleOverlay(engine: engine, delay: subtitleDelay, rate: subtitleRate,
                                              controlsVisible: playerForAVKit != nil ? nativeTransportVisible : showsControls)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if playerForAVKit == nil {
                pictureControls
                if let engine, showsControls, !showsSubtitlePanel {
                    transport(engine).transition(.opacity)
                } else if let chapter = skipChapter, !showsSubtitlePanel, playbackState == .playing {
                    skipButton(chapter)
                        .padding(.trailing, 90)
                        .padding(.bottom, 70)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            playbackStatus

            if let engine, showsSubtitlePanel {
                Color.black.opacity(0.28).ignoresSafeArea().accessibilityHidden(true)
                HStack {
                    Spacer(minLength: 0)
                    AetherPlaybackSubtitlePanel(engine: engine, delay: $subtitleDelay, rate: $subtitleRate,
                                                onClose: closeSubtitles,
                                                onAutoSync: referenceSubtitle(in: engine) == nil ? nil : { alignSubtitles(in: engine) },
                                                autoSyncStatus: subtitleSyncStatus, isAutoSyncing: subtitleSyncTask != nil,
                                                onAudioSync: canSyncByAudio ? { alignSubtitlesByAudio(in: engine) } : nil,
                                                onSubtitleSelected: saveSubtitleChoice)
                }
                .padding(.vertical, 30)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .defaultFocus($focus, .picture)
        .onExitCommand(perform: backCommand)
        .onPlayPauseCommand(perform: playerForAVKit == nil ? fallbackPlayPause : nil)
        .task(id: playAttempt) { await start() }
        .task(id: isOpening) {
            guard isOpening else { return }
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard isOpening, !Task.isCancelled else { return }
            fail(PlaybackFailure(info: nil, timedOut: true))
        }
        .task {
            let tracks = await loadSubtitles()
            guard !Task.isCancelled, !isClosing else { return }
            addonSubtitles = tracks
            if let engine, isSessionReady { addSubtitles(to: engine) }
        }
        .task(id: interaction) { await hideControlsWhenIdle() }
        .onChange(of: focus) { _, target in
            if showsControls, target != .picture { interaction = UUID() }
        }
        .onChange(of: seekInterval) { _, seconds in engine?.remoteSkipInterval = Double(seconds) }
        .onChange(of: playbackState) { _, state in
            if (state == .paused || state == .ended), !showsSubtitlePanel {
                revealControls(moveFocus: true)
                if state == .ended, onNext != nil { focus = .next }
            } else if state == .playing {
                interaction = UUID()
                if let engine { restoreTrackChoices(in: engine) }
            }
        }
        .onDisappear(perform: stop)
    }

    private var fallbackPlayPause: (() -> Void)? { isScrubbing ? nil : { togglePlayback() } }
    private var backCommand: (() -> Void)? {
        playerForAVKit == nil || showsSubtitlePanel ? { handleBack() } : nil
    }

    private func playerSurface(_ engine: AetherEngine) -> some View {
        ZStack {
            if let player = playerForAVKit {
                PlayerController(player: player, onBack: handleBack, aetherActions: nativeActions)
                    .accessibilityHidden(showsSubtitlePanel)
                    .allowsHitTesting(!showsSubtitlePanel)
                AetherHeldPicture(engine: engine)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                AetherPlayerSurface(engine: engine)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var nativeActions: PlayerController.AetherActions {
        PlayerController.AetherActions(
            controlsEnabled: !showsSubtitlePanel,
            pictureReady: { nativePictureReady = true; updateStarted() },
            transportVisibilityChanged: { nativeTransportVisible = $0 },
            subtitles: openSubtitles,
            skip: nativeSkipAction,
            next: nativeEndAction
        )
    }

    private var nativeSkipAction: PlayerController.ContextAction? {
        guard playbackState == .playing, let chapter = skipChapter, let label = chapterAction(chapter) else { return nil }
        return .init(id: "chapter-\(chapter.id)", title: label) { skipChapter(chapter) }
    }

    private var nativeEndAction: PlayerController.ContextAction? {
        guard playbackState == .ended else { return nil }
        if let onNext {
            return .init(id: "next", title: String(localized: "Next Episode")) { advance(onNext) }
        }
        return .init(id: "replay", title: String(localized: "Play Again")) { playAttempt += 1 }
    }

    private func nativePlayerChanged(_ player: AVPlayer?) {
        guard nativePlayer !== player else { return }
        nativePlayer = player
        nativePictureReady = false
        nativeTransportVisible = false
    }

    private var pictureControls: some View {
        Button { revealControls(moveFocus: true) } label: {
            Color.clear
                .frame(width: 100, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(PictureButtonStyle())
        .focusEffectDisabled()
        .disabled(showsSubtitlePanel)
        .focused($focus, equals: .picture)
        .accessibilityLabel("Playback controls")
        .onMoveCommand(perform: moveFromPicture)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if isAwaitingDisplaySwitch {
            PlaybackLoadingStatus("Adjusting display for this video…")
        } else if playbackPhase == .stalled(reconnecting: true) {
            PlaybackLoadingStatus("Reconnecting to the source…")
        } else if isOpening {
            PlaybackLoadingStatus(startupLabel, progress: startupProgress?.fraction)
        } else if playerForAVKit == nil, playbackPhase == .rebuffering {
            PlaybackLoadingStatus("Buffering more video…")
        } else if playbackPhase == .stalled(reconnecting: false) {
            PlaybackLoadingStatus("Waiting for the source to respond…")
        }
    }

    private var startupLabel: LocalizedStringKey {
        switch startupProgress?.stage ?? .connecting {
        case .connecting: "Connecting to the source…"
        case .openingContainer: "Reading the media file…"
        case .analyzingStreams: "Analyzing video and audio tracks…"
        case .preparingDisplay: "Preparing the display…"
        case .selectingRoute: "Choosing a playback mode…"
        case .buildingSession: "Setting up the player…"
        case .preparingPlayback: "Buffering the start of the video…"
        case .awaitingFirstFrame, .presenting: "Waiting for the first frame…"
        }
    }

    private struct PictureButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }

    private func transport(_ engine: AetherEngine) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                if let episode { Text(episode).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            AetherPlaybackScrubber(engine: engine, step: Double(seekInterval), isFocused: focus == .scrubber,
                                    onEditingChange: scrubStateChanged, onMoveDown: { focus = .playPause }) {
                seek(to: $0, exact: true)
            }
                .focused($focus, equals: .scrubber)
            HStack(spacing: 24) {
                Button(playbackState == .playing ? "Pause" : "Play",
                       systemImage: playbackState == .playing ? "pause.fill" : "play.fill",
                       action: togglePlayback)
                    .focused($focus, equals: .playPause)

                if playbackState == .ended, let onNext {
                    Button("Next Episode", systemImage: "forward.end.fill") { advance(onNext) }
                        .labelStyle(.titleAndIcon)
                        .focused($focus, equals: .next)
                }

                Spacer()

                if let chapter = skipChapter, playbackState != .ended { skipButton(chapter) }

                Button("Subtitles", systemImage: "captions.bubble", action: openSubtitles)
                    .focused($focus, equals: .subtitles)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 90)
        .padding(.top, 64)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
                .allowsHitTesting(false)
        }
    }

    private func skippableChapter(at time: Double, in engine: AetherEngine) -> ChapterInfo? {
        guard time.isFinite, engine.canSeek else { return nil }
        return engine.mediaChapters.first { chapter in
            let end = chapter.startSeconds + chapter.durationSeconds
            guard (3...180).contains(chapter.durationSeconds), end.isFinite, time >= chapter.startSeconds,
                  time < end - 1, end < engine.duration else { return false }
            return chapterAction(chapter) != nil
        }
    }

    private func chapterAction(_ chapter: ChapterInfo) -> String? {
        switch chapter.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "intro", "opening", "opening credits", "op": String(localized: "Skip Intro")
        case "recap", "previously on": String(localized: "Skip Recap")
        case "outro", "ending", "ending credits", "end credits", "credits", "ed": String(localized: "Skip Credits")
        default: nil
        }
    }

    private func skipButton(_ chapter: ChapterInfo) -> some View {
        Button(chapterAction(chapter) ?? String(localized: "Skip Chapter"), systemImage: "forward.end") { skipChapter(chapter) }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .focused($focus, equals: .skip)
    }

    private func skipChapter(_ chapter: ChapterInfo) {
        skipChapter = nil
        seek(to: chapter.startSeconds + chapter.durationSeconds, exact: true)
        if !showsControls, playerForAVKit == nil { focus = .picture }
    }

    private func advance(_ action: () -> Void) {
        guard !isClosing else { return }
        isClosing = true
        stop()
        action()
    }

    private func start() async {
        guard !isClosing else { return }
        do {
            let player: AetherEngine
            if let engine {
                player = engine
            } else {
                player = try AetherEngine()
                configureNowPlaying(player)
                engine = player
            }
            try Task.checkCancellation()
            guard !isClosing else { return }
            let seconds = playAttempt == 0 ? Double(max(0, position)) / 1_000 : 0
            restoredSubtitles = false
            let initialTracks = externalTracks()
            registeredSubtitleURLs = Set(initialTracks.map(\.url))
            try await player.load(url: url, startPosition: seconds,
                                  options: LoadOptions(httpHeaders: requestHeaders, serveIFramePlaylist: true,
                                                       externalSubtitles: initialTracks))
            guard !Task.isCancelled, !isClosing else { return }
            addSubtitles(to: player)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            fail(PlaybackFailure(info: engine?.errorInfo))
        }
    }

    private func configureNowPlaying(_ engine: AetherEngine) {
        engine.ownsSoftwareNowPlaying = true
        engine.ownsAudioNowPlaying = true
        engine.deactivatesAudioSessionOnStop = true
        engine.remoteSkipInterval = Double(seekInterval)
        engine.setExternalMetadata(PlaybackMetadata.items(title: title, episode: episode))
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let episode { info[MPMediaItemPropertyAlbumTitle] = episode }
        engine.setNowPlayingInfo(info)
    }

    private func moveFromPicture(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: skip(-Double(seekInterval))
        case .right: skip(Double(seekInterval))
        case .up, .down: revealControls(moveFocus: true)
        @unknown default: break
        }
    }

    private func togglePlayback() {
        guard let engine, !isClosing, isReady || playbackState == .ended else { return }
        revealControls(moveFocus: true)
        if playbackState == .ended {
            playAttempt += 1
        } else {
            engine.togglePlayPause()
        }
    }

    private func skip(_ seconds: Double) {
        guard let engine, !isClosing, isReady, engine.canSeek, seekTask == nil else { return }
        let current = engine.currentTime
        guard current.isFinite else { return }
        let duration = engine.duration
        let target = max(0, current + seconds)
        let position = duration.isFinite && duration > 0 ? min(target, duration) : target
        revealControls()
        seek(to: position, exact: false)
    }

    private func seek(to position: Double, exact: Bool) {
        guard let engine, !isClosing, engine.canSeek, seekTask == nil else { return }
        seekTask = Task {
            guard !Task.isCancelled else { return }
            await engine.seek(to: position, exact: exact)
            if !Task.isCancelled { seekTask = nil }
        }
    }

    private func revealControls(moveFocus: Bool = false) {
        guard isReady || playbackState == .ended else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showsControls = true }
        if moveFocus, !showsSubtitlePanel {
            focus = engine?.canSeek == true && playbackState != .ended ? .scrubber : .playPause
        }
        interaction = UUID()
    }

    private func hideControlsWhenIdle() async {
        guard showsControls, !showsSubtitlePanel, !isScrubbing, playbackState == .playing else { return }
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard !showsSubtitlePanel, !isScrubbing, playbackState == .playing else { return }
        focus = .picture
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showsControls = false }
    }

    private func scrubStateChanged(_ active: Bool) {
        isScrubbing = active
        interaction = UUID()
    }

    private func openSubtitles() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) { showsSubtitlePanel = true }
        interaction = UUID()
    }

    private func closeSubtitles() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { showsSubtitlePanel = false }
        if playerForAVKit == nil { focus = .subtitles }
        interaction = UUID()
    }

    private func handleBack() {
        if showsSubtitlePanel {
            closeSubtitles()
        } else if playerForAVKit == nil, showsControls, playbackState != .ended {
            guard !isScrubbing else { return }
            focus = .picture
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showsControls = false }
        } else {
            close()
        }
    }

    private func externalTracks() -> [ExternalSubtitleTrack] {
        var seen = Set<URL>()
        return (subtitles + addonSubtitles).filter { $0.isHTTPS && seen.insert($0.url).inserted }.map {
            ExternalSubtitleTrack(url: $0.url, name: $0.name, language: $0.lang, httpHeaders: [:])
        }
    }

    private func referenceSubtitle(in engine: AetherEngine) -> TrackInfo? {
        guard engine.videoRoute != .remoteBypass,
              let selected = availableSubtitleTracks.first(where: { $0.id == selectedSubtitleID }),
              selected.isExternal, ["subrip", "srt", "ass", "ssa", "webvtt"].contains(selected.codec),
              let language = languageCode(selected.language) else { return nil }
        let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "ttml"]
        return availableSubtitleTracks.first {
            !$0.isExternal && !$0.isNativelyRenderedSubtitle && !$0.isForced && textCodecs.contains($0.codec)
                && languageCode($0.language) == language
        }
    }

    private func subtitleSelectionChanged(_ id: Int?) {
        guard selectedSubtitleID != id else { return }
        selectedSubtitleID = id
        subtitleSyncTask?.cancel()
        subtitleSyncStatus = nil
        subtitleDelay = 0
        subtitleRate = 1
    }

    private func updateStarted() {
        if isReady, playbackPhase == .playing { hasStarted = true }
    }

    private func languageCode(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return Locale.Language(identifier: identifier).languageCode?.identifier
    }

    private func alignSubtitles(in engine: AetherEngine) {
        guard subtitleSyncTask == nil, let reference = referenceSubtitle(in: engine),
              let primary = engine.activeSubtitleTrackIndex else { return }
        subtitleSyncStatus = String(localized: "Matching subtitle lines…")
        engine.selectSecondarySubtitleTrack(index: reference.id)
        subtitleSyncTask = Task {
            defer {
                if !isClosing { engine.clearSecondarySubtitle() }
                subtitleSyncTask = nil
            }
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard engine.activeSubtitleTrackIndex == primary else { subtitleSyncStatus = nil; return }
                let external = engine.subtitleCues.compactMap { cue in cue.text.map { (start: cue.startTime, text: $0) } }
                let embedded = engine.secondarySubtitleCues.compactMap { cue in cue.text.map { (start: cue.startTime, text: $0) } }
                if let fit = await Task.detached(priority: .utility, operation: {
                    SubtitleCueAlignment.fit(external: external, reference: embedded)
                }).value, !Task.isCancelled, engine.activeSubtitleTrackIndex == primary {
                    subtitleDelay = fit.delay
                    subtitleRate = fit.rate
                    subtitleSyncStatus = String(localized: "Matched to the built-in subtitle track.")
                    return
                }
            }
            subtitleSyncStatus = String(localized: "Couldn’t find enough matching lines. Adjust subtitle timing manually.")
        }
    }

    private var canSyncByAudio: Bool {
        (videoRoute == .loopback || videoRoute == .software)
            && availableSubtitleTracks.contains { $0.id == selectedSubtitleID && $0.isExternal && !$0.isNativelyRenderedSubtitle }
    }

    private func alignSubtitlesByAudio(in engine: AetherEngine) {
        guard subtitleSyncTask == nil, canSyncByAudio, let primary = selectedSubtitleID else { return }
        guard playbackPhase == .playing else {
            subtitleSyncStatus = String(localized: "Resume playback to sync with dialogue.")
            return
        }
        let cues = engine.subtitleCues
        let rate = subtitleRate
        let delay = subtitleDelay
        subtitleSyncStatus = String(localized: "Listening to dialogue for up to 50 seconds…")
        subtitleSyncTask = Task {
            defer { subtitleSyncTask = nil }
            do {
                let result = try await SubtitleAudioAlignment.estimate(engine: engine, cues: cues, startingDelay: delay, rate: rate)
                guard !Task.isCancelled, selectedSubtitleID == primary else { return }
                subtitleDelay = result
                subtitleSyncStatus = String(localized: "Matched subtitles to the dialogue timing.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedSubtitleID == primary else { return }
                subtitleSyncStatus = String(localized: "Couldn’t match the dialogue reliably. Try a dialogue-heavy scene or adjust timing manually.")
            }
        }
    }

    private func addSubtitles(to engine: AetherEngine) {
        guard !isClosing else { return }
        for track in externalTracks() where registeredSubtitleURLs.insert(track.url).inserted {
            engine.addExternalSubtitleTrack(track)
        }
        restoreTrackChoices(in: engine)
    }

    private func saveSubtitleChoice(_ track: TrackInfo?) {
        restoredSubtitles = true
        PlaybackTrackPreferences.saveSubtitle(track, for: trackPreferenceKey)
    }

    private func restoreTrackChoices(in engine: AetherEngine) {
        guard !isClosing, engine.isSessionReady else { return }
        if !restoredAudio, engine.videoRoute != .remoteBypass,
           let track = PlaybackTrackPreferences.audio(for: trackPreferenceKey)?.match(in: engine.audioTracks) {
            restoredAudio = true
            if engine.activeAudioTrackIndex != track.id {
                engine.selectAudioTrack(index: track.id)
                return
            }
        }
        guard !restoredSubtitles else { return }
        let preference = PlaybackTrackPreferences.subtitle(for: trackPreferenceKey) ?? .off
        switch preference {
        case .off:
            restoredSubtitles = true
            engine.clearSubtitle()
        case .embedded(let track), .addon(let track):
            if let match = track.matchSubtitle(in: engine.subtitleTracks) {
                restoredSubtitles = true
                if engine.activeSubtitleTrackIndex != match.id { engine.selectSubtitleTrack(index: match.id) }
            }
        }
    }

    private func savePosition(_ engine: AetherEngine, checkpoint: PlaybackCheckpoint) {
        guard hasStarted, !engine.isSeeking || checkpoint == .ended else { return }
        onProgress(engine.currentTime, engine.duration, checkpoint)
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        stop()
        onBack()
    }

    private func stop() {
        subtitleSyncTask?.cancel()
        seekTask?.cancel()
        seekTask = nil
        guard let engine else { return }
        savePosition(engine, checkpoint: .flush)
        self.engine = nil
        engine.stop()
    }

    private func fail(_ error: PlaybackFailure) {
        guard !isClosing else { return }
        isClosing = true
        let started = hasStarted
        stop()
        onFailure(error, started)
    }

    struct PlaybackFailure: LocalizedError {
        private let kind: PlaybackErrorKind?
        private let timedOut: Bool

        fileprivate init(info: PlaybackErrorInfo?, timedOut: Bool = false) {
            kind = info?.kind
            self.timedOut = timedOut
        }

        var allowsNativeFallback: Bool { kind != .sourceRefused && kind != .sourceRateLimited }

        var errorDescription: String? {
            if timedOut { return String(localized: "The source took too long to start. Try again or choose another source.") }
            if kind == .sourceRateLimited {
                return String(localized: "The streaming server is busy. Try again shortly.")
            }
            if kind == .sourceRefused {
                return String(localized: "The streaming server refused this link. Refresh the sources and try again.")
            }
            return String(localized: "This source couldn’t play on Apple TV. Try another source.")
        }
    }
}

struct PlaybackLoadingStatus: View {
    let message: LocalizedStringKey
    let progress: Double?

    init(_ message: LocalizedStringKey, progress: Double? = nil) {
        self.message = message
        self.progress = progress
    }

    var body: some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress) {
                    Text(message).font(.headline)
                }
                .progressViewStyle(.linear)
                .frame(width: 430)
            } else {
                ProgressView { Text(message).font(.headline) }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .foregroundStyle(.white)
        .tint(.white)
        .background(.black.opacity(0.78), in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct AetherHeldPicture: UIViewRepresentable {
    let engine: AetherEngine

    func makeCoordinator() -> AetherEngine { engine }

    func makeUIView(context: Context) -> AetherStillView {
        let view = AetherStillView(frame: .zero)
        engine.bindStillView(view)
        return view
    }

    func updateUIView(_ view: AetherStillView, context: Context) {}

    static func dismantleUIView(_ view: AetherStillView, coordinator: AetherEngine) {
        coordinator.unbindStillView(view)
    }
}
