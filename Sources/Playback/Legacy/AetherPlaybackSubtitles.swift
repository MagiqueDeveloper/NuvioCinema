import AetherEngine
import AVFoundation
import SwiftUI

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
    @AppStorage(CaptionPreference.textKey) private var captionTextColor = CaptionPreference.TextColor.system
    @AppStorage(CaptionPreference.backgroundKey) private var captionBackground = CaptionPreference.Background.system

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
            optionButton("Text Color", value: captionTextColor.label) { captionTextColor = captionTextColor.next }
            optionButton("Background", value: captionBackground.label) { captionBackground = captionBackground.next }
            Button("Use System Appearance") {
                captionSize = .system
                captionTextColor = .system
                captionBackground = .system
            }
            .buttonStyle(.bordered)
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
        let language = track.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
        let name = track.name.isEmpty ? language ?? String(localized: "Track \(track.id + 1)") : track.name
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
    @State private var captionStyle = SubtitleCaptionStyle.current()
    @State private var captionObservation: SubtitleCaptionStyle.Observation?
    @AppStorage(CaptionPreference.sizeKey) private var captionSize = CaptionPreference.Size.system
    @AppStorage(CaptionPreference.textKey) private var captionTextColor = CaptionPreference.TextColor.system
    @AppStorage(CaptionPreference.backgroundKey) private var captionBackground = CaptionPreference.Background.system

    var body: some View {
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let displayed = isSeeking ? [] : visibleCues
            let standard = displayed.filter { $0.placement == nil && $0.text != nil }
            let positioned = displayed.filter { $0.placement != nil || $0.text == nil }

            VStack(spacing: 5) {
                ForEach(standard) { caption($0, width: frame.width) }
            }
            .padding(.bottom, controlsVisible ? 190 : 42)
            .frame(width: frame.width, height: frame.height, alignment: .bottom)
            .position(x: frame.midX, y: frame.midY)

            ForEach(positioned) { cue in
                if case .image(let image) = cue.body {
                    let target = bitmapFrame(image, in: frame)
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                } else if let anchor = cue.placement?.position, anchor.x.isFinite, anchor.y.isFinite {
                    caption(cue, width: frame.width)
                        .position(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
                } else {
                    caption(cue, width: frame.width)
                        .padding(42)
                        .frame(width: frame.width, height: frame.height, alignment: alignment(for: cue.placement?.alignment))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(engine.clock.$sourceTime) { updateVisible(at: $0) }
        .onReceive(engine.$subtitleCues) { value in
            cues = value
            updateVisible(at: engine.clock.sourceTime, cues: value)
        }
        .onReceive(engine.$isSeeking) { isSeeking = $0 }
        .onReceive(engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex)) { tracks, selected in
            allowsDriftCorrection = tracks.first { $0.id == selected }?.supportsDriftCorrection == true
            updateVisible(at: engine.clock.sourceTime)
        }
        .onChange(of: delay) { _, _ in updateVisible(at: engine.clock.sourceTime) }
        .onChange(of: rate) { _, _ in updateVisible(at: engine.clock.sourceTime) }
        .onAppear {
            captionObservation = SubtitleCaptionStyle.observeChanges { style in
                Task { @MainActor in captionStyle = style }
            }
        }
        .onDisappear { captionObservation = nil }
    }

    private func updateVisible(at sourceTime: Double, cues replacement: [SubtitleCue]? = nil) {
        let time = (sourceTime - delay) * (allowsDriftCorrection ? rate : 1)
        let active = (replacement ?? cues).filter { $0.startTime <= time && time < $0.endTime }
        if active != visibleCues { visibleCues = active }
    }

    private func caption(_ cue: SubtitleCue, width: CGFloat) -> some View {
        let systemBackground = color(captionStyle.backgroundColor?.value,
                                     opacity: captionStyle.backgroundOpacity?.value ?? 0.6, defaultColor: .black)
        let background = captionBackground.override ?? systemBackground
        let size = max(25, width * 0.023) * (captionSize.scale ?? captionStyle.sizeScale)
        return Text(captionText(cue, size: size))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: width * 0.85)
    }

    private func captionText(_ cue: SubtitleCue, size: CGFloat) -> AttributedString {
        let runs: [SubtitleTextRun]
        switch cue.body {
        case .text(let text): runs = [SubtitleTextRun(text: text, color: nil)]
        case .richText(let value): runs = value
        case .image: runs = []
        }
        var result = AttributedString()
        for run in runs {
            var segment = AttributedString(run.text)
            let fontName = captionStyle.fontName?.resolved(cue: run.fontName) ?? run.fontName
            var font = fontName.map { Font.custom($0, size: size) } ?? .system(size: size, weight: .medium)
            if run.isBold { font = font.bold() }
            if run.isItalic { font = font.italic() }
            segment.font = font
            let foreground = captionStyle.textColor?.resolved(cue: run.color) ?? run.color
            segment.foregroundColor = captionTextColor.override
                ?? color(foreground, opacity: captionStyle.textOpacity?.value ?? 1, defaultColor: .white)
            if run.isUnderlined { segment.underlineStyle = .single }
            if run.isStruckThrough { segment.strikethroughStyle = .single }
            result.append(segment)
        }
        return result
    }

    private func color(_ value: SubtitleColor?, opacity: Double, defaultColor: Color) -> Color {
        guard let value else { return defaultColor.opacity(opacity) }
        return Color(red: Double(value.r) / 255, green: Double(value.g) / 255, blue: Double(value.b) / 255, opacity: opacity)
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

    private func bitmapFrame(_ image: SubtitleImage, in frame: CGRect) -> CGRect {
        var canvas = frame
        if image.canvasSize.width > 0, image.canvasSize.height > 0, engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            let codedWidth = Double(engine.sourceVideoWidth)
            let codedHeight = Double(engine.sourceVideoHeight)
            let mappedHeight = image.canvasSize.height * (codedWidth / image.canvasSize.width) * (frame.height / codedHeight)
            canvas = CGRect(x: frame.minX, y: frame.midY - mappedHeight / 2, width: frame.width, height: mappedHeight)
        }
        let normalized = image.position
        return CGRect(x: canvas.minX + normalized.minX * canvas.width,
                      y: canvas.minY + normalized.minY * canvas.height,
                      width: normalized.width * canvas.width,
                      height: normalized.height * canvas.height)
    }

    private func alignment(for value: Int?) -> Alignment {
        switch value {
        case 1: .bottomLeading
        case 3: .bottomTrailing
        case 4: .leading
        case 5: .center
        case 6: .trailing
        case 7: .topLeading
        case 8: .top
        case 9: .topTrailing
        default: .bottom
        }
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
    static let textKey = "playback.subtitleAppearance.text"
    static let backgroundKey = "playback.subtitleAppearance.background"

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

    enum TextColor: String, PlaybackOption {
        case system, white, yellow

        var label: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .white: "White"
            case .yellow: "Yellow"
            }
        }

        var override: Color? {
            switch self {
            case .system: nil
            case .white: .white
            case .yellow: .yellow
            }
        }
    }

    enum Background: String, PlaybackOption {
        case system, clear, translucent, solid

        var label: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .clear: "Clear"
            case .translucent: "Translucent Black"
            case .solid: "Solid Black"
            }
        }

        var override: Color? {
            switch self {
            case .system: nil
            case .clear: .clear
            case .translucent: .black.opacity(0.6)
            case .solid: .black
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
