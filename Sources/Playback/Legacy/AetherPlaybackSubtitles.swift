import AetherEngine
import AVFoundation
import SwiftUI
import Vision

struct AetherPlaybackSubtitlePanel: View {
    let engine: AetherEngine
    @Binding var delay: Double
    @Binding var rate: Double
    let onClose: () -> Void
    var onAutoSync: (() -> Void)? = nil
    var autoSyncStatus: String? = nil
    var isAutoSyncing = false
    var onAudioSync: (() -> Void)? = nil
    var onSubtitleSelected: (TrackInfo?) -> Void = { _ in }

    @FocusState private var focus: Target?
    @State private var tracks: [TrackInfo] = []
    @State private var selected: Int?
    @State private var isLoading = false
    @State private var showsAppearance = false
    @AppStorage(CaptionPreference.sizeKey) private var captionSize = CaptionPreference.Size.system

    private enum Target: Hashable {
        case off, track(Int), appearance, captionSize
    }

    private var selectedTrack: TrackInfo? { tracks.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(showsAppearance ? "Subtitle Appearance" : "Subtitles")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(showsAppearance ? "Subtitles" : "Done") {
                    if showsAppearance {
                        showsAppearance = false
                        focus = .appearance
                    } else {
                        onClose()
                    }
                }
                .buttonStyle(.bordered)
            }

            if showsAppearance {
                appearanceControls
            } else {
                trackList
                if isLoading {
                    ProgressView("Loading subtitles…")
                        .font(.callout)
                }
                if let selectedTrack, !selectedTrack.isNativelyRenderedSubtitle {
                    timingControls
                }
                Button("Appearance", systemImage: "textformat") {
                    showsAppearance = true
                    focus = .captionSize
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .appearance)
            }
        }
        .padding(34)
        .frame(width: 620)
        .frame(maxHeight: 790)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30))
        .defaultFocus($focus, selected.map(Target.track) ?? .off)
        .onReceive(engine.$subtitleTracks) { tracks = $0 }
        .onReceive(engine.$activeSubtitleTrackIndex) { selected = $0 }
        .onReceive(engine.$isLoadingSubtitles) { isLoading = $0 }
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                trackRow(String(localized: "Off"), isSelected: selected == nil) {
                    engine.clearSubtitle()
                    onSubtitleSelected(nil)
                }
                    .focused($focus, equals: .off)

                ForEach(tracks) { track in
                    trackRow(trackName(track), isSelected: selected == track.id, isExternal: track.isExternal) {
                        engine.selectSubtitleTrack(index: track.id)
                        onSubtitleSelected(track)
                    }
                    .focused($focus, equals: .track(track.id))
                }
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
        .focusSection()
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionButton("Size", value: captionSize.label) { captionSize = captionSize.next }
                .focused($focus, equals: .captionSize)
        }
        .focusSection()
    }

    private func optionButton(_ title: LocalizedStringKey, value: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint("Changes to the next option")
    }

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Subtitle Timing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(timingLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Earlier", systemImage: "minus") { changeDelay(by: -0.05) }
                    .disabled(delay <= -30 || isAutoSyncing)
                Button("Later", systemImage: "plus") { changeDelay(by: 0.05) }
                    .disabled(delay >= 30 || isAutoSyncing)
                Button("Reset") { delay = 0 }
                    .disabled(delay == 0 || isAutoSyncing)
            }
            .buttonStyle(.bordered)
            if selectedTrack?.supportsDriftCorrection == true {
                optionButton("Drift Correction", value: driftLabel) { rate = driftPreset?.next.rate ?? 1 }
                    .accessibilityHint("Cycles from video frame rate to subtitle frame rate")
                    .disabled(isAutoSyncing)
            }
            if selectedTrack?.isExternal == true, let onAutoSync {
                Button("Auto Sync", systemImage: "waveform", action: onAutoSync)
                    .buttonStyle(.bordered)
                    .disabled(isAutoSyncing)
            }
            if selectedTrack?.supportsDriftCorrection == true, let onAudioSync {
                Button("Sync by Audio", systemImage: "waveform.badge.magnifyingglass", action: onAudioSync)
                    .buttonStyle(.bordered)
                    .disabled(isAutoSyncing)
            }
            if let autoSyncStatus {
                Text(autoSyncStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .focusSection()
    }

    private var driftPreset: SubtitleDriftPreset? {
        SubtitleDriftPreset.allCases.first { abs($0.rate - rate) < 0.000_001 }
    }

    private var driftLabel: LocalizedStringKey {
        if let driftPreset { return driftPreset.label }
        let percent = rate.formatted(.percent.precision(.fractionLength(2)))
        return "\(percent)"
    }

    private var timingLabel: String {
        let seconds = abs(delay).formatted(.number.precision(.fractionLength(2)))
        if delay < 0 { return String(localized: "\(seconds) s earlier") }
        if delay > 0 { return String(localized: "\(seconds) s later") }
        return String(localized: "No offset")
    }

    private func changeDelay(by delta: Double) {
        delay = min(30, max(-30, ((delay + delta) * 20).rounded() / 20))
    }

    private func trackRow(_ name: String, isSelected: Bool, isExternal: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                if isExternal { Image(systemName: "puzzlepiece.extension").accessibilityLabel("Add-on subtitle") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func trackName(_ track: TrackInfo) -> String {
        let number = (tracks.firstIndex { $0.id == track.id } ?? 0) + 1
        let language = track.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
        let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGenericExternal = track.isExternal && title.range(of: #"^External(?: \d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let name = title.isEmpty || isGenericExternal ? language ?? String(localized: "Track \(number)") : title
        if track.isForced { return String(localized: "\(name) (Forced)") }
        if track.isHearingImpaired { return String(localized: "\(name) (SDH)") }
        return name
    }
}

struct AetherPlaybackSubtitleOverlay: View {
    let engine: AetherEngine
    let delay: Double
    let rate: Double
    let controlsVisible: Bool

    @State private var cues: [SubtitleCue] = []
    @State private var visibleCues: [SubtitleCue] = []
    @State private var isSeeking = false
    @State private var allowsDriftCorrection = false
    @StateObject private var bitmapCaptions = LegacyBitmapCaptions()
    @State private var captionStyle = SubtitleCaptionStyle.current()
    @State private var captionObservation: SubtitleCaptionStyle.Observation?
    @AppStorage(CaptionPreference.sizeKey) private var captionSize = CaptionPreference.Size.system

    var body: some View {
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let displayed = isSeeking ? [] : visibleCues
            VStack(spacing: 5) {
                ForEach(displayed) { cue in
                    if case .image(let image) = cue.body {
                        switch bitmapCaptions.result(for: cue.id, image: image) {
                        case .text(let text):
                            caption(text, width: frame.width)
                        case .unreadable:
                            let size = bitmapSize(image, in: frame)
                            BitmapSubtitleFallback(image: image.cgImage)
                                .frame(width: size.width, height: size.height)
                        case nil:
                            EmptyView()
                        }
                    } else if let text = cue.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        caption(text, width: frame.width)
                    }
                }
            }
            .padding(.bottom, controlsVisible ? 190 : 42)
            .frame(width: frame.width, height: frame.height, alignment: .bottom)
            .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(engine.clock.$sourceTime) { updateVisible(at: $0) }
        .onReceive(engine.$subtitleCues) { value in
            cues = value
            updateVisible(at: engine.clock.sourceTime, cues: value)
        }
        .onReceive(engine.$isSeeking.removeDuplicates()) { seeking in
            isSeeking = seeking
            if seeking {
                bitmapCaptions.reset()
            } else {
                updateVisible(at: engine.clock.sourceTime)
            }
        }
        .onReceive(engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex)) { tracks, selected in
            let track = tracks.first { $0.id == selected }
            bitmapCaptions.selectTrack(id: selected, language: track?.language)
            allowsDriftCorrection = track?.supportsDriftCorrection == true
            updateVisible(at: engine.clock.sourceTime)
        }
        .onChange(of: delay) { _, _ in updateVisible(at: engine.clock.sourceTime) }
        .onChange(of: rate) { _, _ in updateVisible(at: engine.clock.sourceTime) }
        .onAppear {
            captionObservation = SubtitleCaptionStyle.observeChanges { style in
                Task { @MainActor in captionStyle = style }
            }
        }
        .onDisappear {
            bitmapCaptions.reset()
            captionObservation = nil
        }
    }

    private func updateVisible(at sourceTime: Double, cues replacement: [SubtitleCue]? = nil) {
        let time = (sourceTime - delay) * (allowsDriftCorrection ? rate : 1)
        let available = replacement ?? cues
        let active = available.filter { $0.startTime <= time && time < $0.endTime }
        if active != visibleCues { visibleCues = active }
        if !isSeeking { bitmapCaptions.prepare(available, at: time) }
    }

    private func caption(_ text: String, width: CGFloat) -> some View {
        let size = max(25, width * 0.023) * (captionSize.scale ?? captionStyle.sizeScale)
        return Text(verbatim: text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: width * 0.85)
    }

    private func videoFrame(in size: CGSize) -> CGRect {
        if let rect = engine.nativePlayerLayer?.videoRect, rect.width > 0, rect.height > 0 {
            return rect
        }
        let source = engine.softwareDisplaySize ?? CGSize(
            width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio,
            height: Double(engine.sourceVideoHeight)
        )
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: size) }
        return AVMakeRect(aspectRatio: source, insideRect: CGRect(origin: .zero, size: size))
    }

    private func bitmapSize(_ image: SubtitleImage, in frame: CGRect) -> CGSize {
        var canvasHeight = frame.height
        if image.canvasSize.width > 0, image.canvasSize.height > 0, engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            let codedWidth = Double(engine.sourceVideoWidth)
            let codedHeight = Double(engine.sourceVideoHeight)
            canvasHeight = image.canvasSize.height * (codedWidth / image.canvasSize.width) * (frame.height / codedHeight)
        }
        let width = image.position.width * frame.width
        let scale = min(1, frame.width * 0.85 / max(width, 1))
        return CGSize(width: width * scale, height: image.position.height * canvasHeight * scale)
    }
}

@MainActor
private final class LegacyBitmapCaptions: ObservableObject {
    enum Result {
        case text(String)
        case unreadable
    }

    private struct Key: Hashable {
        let id: Int
        let image: ObjectIdentifier

        init(_ id: Int, _ image: SubtitleImage) {
            self.id = id
            self.image = ObjectIdentifier(image.cgImage)
        }
    }

    @Published private var results: [Key: Result] = [:]
    private var order: [Key] = []
    private var task: Task<Void, Never>?
    private var trackID: Int?
    private var language: String?
    private nonisolated static let visionQueue = DispatchQueue(
        label: "com.nuviocinema.subtitle-recognition", qos: .userInitiated
    )

    func selectTrack(id: Int?, language: String?) {
        guard trackID != id || self.language != language else { return }
        trackID = id
        self.language = language
        reset()
    }

    func result(for id: Int, image: SubtitleImage) -> Result? {
        results[Key(id, image)]
    }

    func reset() {
        task?.cancel()
        task = nil
        order.removeAll()
        if !results.isEmpty { results.removeAll() }
    }

    func prepare(_ cues: [SubtitleCue], at time: Double) {
        guard task == nil, time.isFinite else { return }
        let upcoming = cues.lazy.filter { $0.endTime > time && $0.startTime <= time + 12 }
            .compactMap { cue -> (Key, SubtitleImage)? in
                guard case .image(let image) = cue.body else { return nil }
                return (Key(cue.id, image), image)
            }
            .prefix(16)
        let next = Array(upcoming.lazy.filter { self.results[$0.0] == nil }.prefix(8))
        guard !next.isEmpty else { return }
        task = Task { [weak self, language] in
            for (key, image) in next {
                guard !Task.isCancelled else { return }
                let text = await Self.recognize(image, language: language)
                guard !Task.isCancelled, let self else { return }
                self.store(text.map(Result.text) ?? .unreadable, for: key)
            }
            self?.task = nil
        }
    }

    private func store(_ result: Result, for key: Key) {
        if order.count >= 32 { results.removeValue(forKey: order.removeFirst()) }
        order.append(key)
        results[key] = result
    }

    private nonisolated static func recognize(_ image: SubtitleImage, language: String?) async -> String? {
        await withCheckedContinuation { continuation in
            visionQueue.async {
                continuation.resume(returning: autoreleasepool {
                    recognizeSynchronously(image.cgImage, language: language)
                })
            }
        }
    }

    private nonisolated static func recognizeSynchronously(_ image: CGImage, language: String?) -> String? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        if let language {
            let primary = Locale.Language(identifier: language).languageCode?.identifier(.alpha2) ?? language
            if primary.lowercased() != "und" {
                guard let supported = try? request.supportedRecognitionLanguages(),
                      let match = supported.first(where: {
                          $0.caseInsensitiveCompare(primary) == .orderedSame
                              || $0.lowercased().hasPrefix(primary.lowercased() + "-")
                      }) else { return nil }
                request.recognitionLanguages = [match]
            }
        }
        do {
            try VNImageRequestHandler(cgImage: flattened).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private extension TrackInfo {
    var supportsDriftCorrection: Bool {
        // External text cues are decoded together. Embedded and bitmap cues are streamed within
        // a fixed window, so a conversion over a feature-length video could outrun the cues.
        isExternal && !isNativelyRenderedSubtitle && ["subrip", "ass", "webvtt"].contains(codec)
    }
}

private enum CaptionPreference {
    static let sizeKey = "playback.subtitleAppearance.size"

    enum Size: String, PlaybackOption {
        case system, small, medium, large

        var label: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }

        var scale: Double? {
            switch self {
            case .system: nil
            case .small: 0.85
            case .medium: 1
            case .large: 1.3
            }
        }
    }
}

private enum SubtitleDriftPreset: PlaybackOption {
    case none, from24to23976, from23976to24, from25to23976, from23976to25

    var label: LocalizedStringKey {
        switch self {
        case .none: "None"
        case .from24to23976: "24 → 23.976 fps"
        case .from23976to24: "23.976 → 24 fps"
        case .from25to23976: "25 → 23.976 fps"
        case .from23976to25: "23.976 → 25 fps"
        }
    }

    // At one video frame, evaluate the timestamp for the same frame in the subtitle track.
    var rate: Double {
        let fps23976 = 24_000.0 / 1_001
        switch self {
        case .none: return 1
        case .from24to23976: return fps23976 / 24
        case .from23976to24: return 24 / fps23976
        case .from25to23976: return fps23976 / 25
        case .from23976to25: return 25 / fps23976
        }
    }
}

private protocol PlaybackOption: CaseIterable, Equatable where AllCases == [Self] {}

private extension PlaybackOption {
    var next: Self {
        let values = Self.allCases
        let index = values.firstIndex(of: self) ?? 0
        return values[(index + 1) % values.count]
    }
}
