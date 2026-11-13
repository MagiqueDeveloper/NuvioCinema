import AetherEngine
import SwiftUI

struct AetherPlaybackOptions: View {
    static let seekIntervalKey = "playback.seekInterval"
    static let defaultSeekInterval = 15

    @ObservedObject var engine: AetherEngine
    @Binding var playbackRate: Float
    @Binding var seekInterval: Int
    let onDismiss: () -> Void
    var onAudioSelected: (TrackInfo) -> Void = { _ in }

    @FocusState private var focus: Control?
    @State private var audioDelay: Int = 0
    @State private var audioShaping = AudioShaping()
    @State private var lastVideoRoute: VideoRoute = .none
    @State private var lastAudioTracks: [TrackInfo] = []

    private enum Control: Hashable {
        case audio, speed
    }

    private static let speeds: [Float] = [0.25, 0.5, 1, 1.25, 1.5, 2]
    private static let intervals = [5, 10, 15, 30, 60]
    // Upstream AudioDelayPolicy clamps the offset to ±2 seconds.
    private static let maximumDelay = 2_000
    private static let delayStep = 50

    // Rebuilding the same source briefly clears the route and its tracks.
    private var videoRoute: VideoRoute {
        engine.videoRoute == .none ? lastVideoRoute : engine.videoRoute
    }

    private var audioTracks: [TrackInfo] {
        engine.audioTracks.isEmpty ? lastAudioTracks : engine.audioTracks
    }

    private var canChangeAudio: Bool {
        videoRoute != .remoteBypass && !audioTracks.isEmpty
    }

    private var canAdjustAudio: Bool {
        (videoRoute == .loopback || videoRoute == .software) && !audioTracks.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 20) {
                Text("Playback Options")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button("Done", action: onDismiss)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    optionGroup("Audio") { audioOptions }
                    optionGroup("Playback") { playbackOptions }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: 840, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30))
        .padding(.trailing, 24)
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .focusSection()
        .defaultFocus($focus, canChangeAudio ? .audio : .speed)
        .onAppear {
            audioDelay = Int((engine.audioDelaySeconds * 1_000).rounded())
            audioShaping = engine.audioShaping
        }
        .onChange(of: engine.videoRoute, initial: true) { _, route in
            if route != .none { lastVideoRoute = route }
        }
        .onChange(of: engine.audioTracks, initial: true) { _, tracks in
            if !tracks.isEmpty { lastAudioTracks = tracks }
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        if canChangeAudio {
            Menu {
                ForEach(audioTracks) { track in
                    choice(trackTitle(track), selected: track.id == engine.activeAudioTrackIndex) {
                        onAudioSelected(track)
                        engine.selectAudioTrack(index: track.id)
                    }
                }
            } label: {
                row("Audio Track", value: currentTrackTitle, icon: "waveform")
            }
            .focused($focus, equals: .audio)
        } else {
            Text(audioTracks.isEmpty ? "No audio tracks available." : "This stream manages its audio tracks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(12)
        }

        if canAdjustAudio {
            audioSync
            dialogueMenu
            Button {
                var shaping = audioShaping
                shaping.compressor = shaping.compressor == nil ? .night : nil
                applyAudioShaping(shaping)
            } label: {
                row("Reduce Loud Sounds", value: audioShaping.compressor == nil
                    ? String(localized: "Off") : String(localized: "On"), icon: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
        }
    }

    private var currentTrackTitle: String {
        guard let current = audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) else {
            return String(localized: "Automatic")
        }
        return trackTitle(current)
    }

    private var audioSync: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Audio Sync", icon: "clock")
                .padding(.horizontal, 18)
            HStack(spacing: 12) {
                Button("Audio Earlier", systemImage: "minus") { setAudioDelay(audioDelay - Self.delayStep) }
                    .labelStyle(.iconOnly)
                    .disabled(audioDelay <= -Self.maximumDelay)

                Button {
                    setAudioDelay(0)
                } label: {
                    Text("\(audioDelay.formatted(.number.sign(strategy: .always(includingZero: false)))) ms")
                        .monospacedDigit()
                        .frame(minWidth: 100)
                }
                .accessibilityLabel("Reset Audio Sync")
                .accessibilityValue(Text("\(audioDelay) milliseconds"))

                Button("Audio Later", systemImage: "plus") { setAudioDelay(audioDelay + Self.delayStep) }
                    .labelStyle(.iconOnly)
                    .disabled(audioDelay >= Self.maximumDelay)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 18)
        }
        .padding(.vertical, 12)
    }

    private var dialogueMenu: some View {
        Menu {
            ForEach([0, 6, 12], id: \.self) { gain in
                choice(dialogueTitle(gain), selected: Double(gain) == audioShaping.dialogueGainDB) {
                    var shaping = audioShaping
                    shaping.dialogueGainDB = Double(gain)
                    applyAudioShaping(shaping)
                }
            }
        } label: {
            row("Enhance Dialogue", value: dialogueTitle(Int(audioShaping.dialogueGainDB)), icon: "person.wave.2")
        }
    }

    @ViewBuilder
    private var playbackOptions: some View {
        Menu {
            ForEach(Self.speeds.filter { $0 <= engine.maxSupportedRate }, id: \.self) { speed in
                choice(speedTitle(speed), selected: speed == playbackRate) {
                    playbackRate = speed
                    engine.setRate(speed)
                }
            }
        } label: {
            row("Playback Speed", value: speedTitle(playbackRate), icon: "speedometer")
        }
        .focused($focus, equals: .speed)

        Menu {
            ForEach(Self.intervals, id: \.self) { interval in
                choice(intervalTitle(interval), selected: interval == seekInterval) {
                    seekInterval = interval
                }
            }
        } label: {
            row("Skip Interval", value: intervalTitle(seekInterval), icon: "forward")
        }

        if engine.canSeek && !engine.mediaChapters.isEmpty {
            Menu {
                ForEach(engine.mediaChapters) { chapter in
                    Button(chapter.name) {
                        onDismiss()
                        Task { await engine.seek(to: chapter.startSeconds) }
                    }
                }
            } label: {
                row("Chapters", icon: "list.bullet")
            }
        }
    }

    private func optionGroup<Content: View>(_ title: LocalizedStringKey,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(10)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 22))
        }
        .focusSection()
    }

    private func row(_ title: LocalizedStringKey, value: String? = nil, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 34)
                .accessibilityHidden(true)
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func trackTitle(_ track: TrackInfo) -> String {
        let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let genericName = name.isEmpty || name.range(of: #"^Track\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let title = genericName || name.caseInsensitiveCompare(track.language ?? "") == .orderedSame
            ? language ?? String(localized: "Track \(track.id)") : name
        let format = track.isAtmos ? "Dolby Atmos" : track.isDTSX ? "DTS:X" : track.codec.uppercased()
        let channels: String? = switch track.channels {
        case 1: String(localized: "Mono")
        case 2: String(localized: "Stereo")
        case 6: "5.1"
        case 8: "7.1"
        default: nil
        }
        let role: String? = if track.isCommentary {
            String(localized: "Commentary")
        } else if track.isVisualImpaired {
            String(localized: "Audio Description")
        } else {
            nil
        }
        return [title, role, format, channels].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func dialogueTitle(_ gain: Int) -> String {
        switch gain {
        case 0: String(localized: "Off")
        case 6: String(localized: "Enhance")
        default: String(localized: "Boost")
        }
    }

    private func speedTitle(_ speed: Float) -> String {
        speed == 1 ? String(localized: "Normal") : "\(speed.formatted())×"
    }

    private func intervalTitle(_ seconds: Int) -> String {
        String(localized: "\(seconds) sec")
    }

    private func setAudioDelay(_ milliseconds: Int) {
        audioDelay = min(max(milliseconds, -Self.maximumDelay), Self.maximumDelay)
        engine.setAudioDelay(Double(audioDelay) / 1_000)
    }

    private func applyAudioShaping(_ shaping: AudioShaping) {
        audioShaping = shaping
        engine.setAudioShaping(shaping)
    }
}
