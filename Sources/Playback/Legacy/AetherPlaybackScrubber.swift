import AetherEngine
import SwiftUI

struct AetherPlaybackScrubber: View {
    @ObservedObject var engine: AetherEngine
    let step: Double
    var isFocused = true
    var onEditingChange: (Bool) -> Void = { _ in }
    var onMoveDown: () -> Void = {}
    let onSeek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentTime = 0.0
    @State private var bufferedPosition = 0.0
    @State private var target: Double?
    @State private var thumbnail: CGImage?
    @State private var thumbnailTime: Double?

    private var range: ClosedRange<Double>? {
        if let live = engine.seekableLiveRange,
           live.lowerBound.isFinite, live.upperBound.isFinite, live.lowerBound < live.upperBound {
            return live
        }
        let duration = engine.duration
        return duration.isFinite && duration > 0 ? 0...duration : nil
    }

    private var playbackTime: Double { engine.seekTarget ?? currentTime }
    private var isEditing: Bool { target != nil }
    private var canScrub: Bool { range != nil && engine.canSeek }
    private var showsPlayhead: Bool { (isFocused && canScrub) || isEditing }

    var body: some View {
        scrubButton
            .onChange(of: isFocused) { _, focused in
                if !focused { cancel() }
            }
            .onChange(of: canScrub) { _, available in
                if !available { cancel() }
            }
            .onReceive(engine.clock.$currentTime) { time in
                if time.isFinite { currentTime = max(0, time) }
            }
            .onReceive(engine.clock.$bufferedPosition) { position in
                if position.isFinite { bufferedPosition = max(0, position) }
            }
            .task(id: target) { await loadPreview() }
            .onDisappear(perform: cancel)
    }

    private var scrubButton: some View {
        Button(action: activate) {
            timeline
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(TimelineButtonStyle())
        .focusEffectDisabled()
        .disabled(!canScrub)
        .accessibilityLabel("Playback position")
        .accessibilityValue(timestamp(target ?? playbackTime))
        .accessibilityHint(isEditing ? "Select to seek. Back to cancel." : "Use Left or Right to scrub.")
        .onMoveCommand(perform: move)
        .onExitCommand(perform: cancelCommand)
        .onPlayPauseCommand(perform: commitCommand)
    }

    private struct TimelineButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }

    private var cancelCommand: (() -> Void)? { isEditing ? { cancel() } : nil }
    private var commitCommand: (() -> Void)? { isEditing ? { activate() } : nil }

    private func loadPreview() async {
        guard let target, engine.supportsCacheBackedStills else { return }
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let image = await engine.scrubThumbnail(atSeconds: target)
        guard !Task.isCancelled, self.target == target else { return }
        thumbnail = image
        thumbnailTime = target
    }

    private var timeline: some View {
        VStack(spacing: 3) {
            if let range {
                progressTrack(in: range)
            }

            HStack(spacing: 12) {
                if engine.isLive {
                    if let range, range.upperBound - clamp(target ?? playbackTime, to: range) > 2 {
                        Text("−\(timestamp(range.upperBound - clamp(target ?? playbackTime, to: range)))")
                    }
                    Spacer()
                    Label("Live", systemImage: "circle.fill")
                        .foregroundStyle(.white)
                } else {
                    Text(timestamp(target ?? playbackTime))
                    Spacer()
                    if let range {
                        Text("−\(timestamp(range.upperBound - clamp(target ?? playbackTime, to: range)))")
                    }
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(showsPlayhead ? 0.92 : 0.72))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsPlayhead)
    }

    private func progressTrack(in range: ClosedRange<Double>) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let played = width * fraction(playbackTime, in: range)
            let buffered = width * fraction(bufferedPosition, in: range)
            let cursor = target.map { width * fraction($0, in: range) } ?? played
            let markerWidth = isEditing ? 6.0 : 14.0

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    if !engine.isLive && buffered > played {
                        Capsule().fill(.white.opacity(0.38)).frame(width: buffered)
                    }
                    Capsule().fill(.white.opacity(isEditing ? 0.72 : 1)).frame(width: played)
                }
                .frame(height: showsPlayhead ? 8 : 5)

                if showsPlayhead {
                    Capsule()
                        .fill(.white)
                        .frame(width: markerWidth, height: isEditing ? 22 : 14)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: min(max(0, cursor - markerWidth / 2), max(0, width - markerWidth)))
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if let target {
                    let previewWidth = min(250, width)
                    preview(width: previewWidth, time: target, liveEdge: engine.isLive ? range.upperBound : nil)
                        .offset(x: min(max(0, cursor - previewWidth / 2), width - previewWidth), y: -32)
                }
            }
        }
        .frame(height: 22)
    }

    private func preview(width: CGFloat, time: Double, liveEdge: Double?) -> some View {
        VStack(spacing: 0) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: width * 9 / 16)
                    .background(.black)
                    .blur(radius: thumbnailTime == time ? 0 : 5)
                    .opacity(thumbnailTime == time ? 1 : 0.65)
            }
            HStack {
                Spacer()
                Text(liveEdge.map { "−\(timestamp($0 - time))" } ?? timestamp(time))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .frame(width: width)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .allowsHitTesting(false)
    }

    private func activate() {
        guard canScrub, let range else { return }
        if let target {
            cancel()
            onSeek(clamp(target, to: range))
        } else {
            target = clamp(playbackTime, to: range)
            onEditingChange(true)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        guard isFocused, canScrub, let range else { return }
        switch direction {
        case .left, .right:
            let adjustment = direction == .left ? -step : step
            let starting = clamp(target ?? playbackTime, to: range)
            let next = clamp(starting + adjustment, to: range)
            guard target != next else { return }
            let beginsEditing = !isEditing
            target = next
            if beginsEditing { onEditingChange(true) }
        case .down:
            cancel()
            onMoveDown()
        case .up:
            cancel()
        @unknown default:
            break
        }
    }

    private func cancel() {
        guard isEditing else { return }
        target = nil
        thumbnail = nil
        thumbnailTime = nil
        onEditingChange(false)
    }

    private func clamp(_ time: Double, to range: ClosedRange<Double>) -> Double {
        guard time.isFinite else { return range.lowerBound }
        return min(max(time, range.lowerBound), range.upperBound)
    }

    private func fraction(_ time: Double, in range: ClosedRange<Double>) -> Double {
        (clamp(time, to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func timestamp(_ time: Double) -> String {
        let seconds = time.isFinite ? max(0, time) : 0
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }
}
