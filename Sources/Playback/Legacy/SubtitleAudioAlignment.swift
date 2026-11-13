import AetherEngine
import AVFoundation
import Foundation

/// Estimates a single subtitle offset against dialogue energy, entirely on the playback device.
enum SubtitleAudioAlignment {
    enum AlignmentError: LocalizedError {
        case unavailable, insufficientDialogue, unreliable

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Audio sync is unavailable for this source.")
            case .insufficientDialogue: String(localized: "Play a scene with more dialogue and try audio sync again.")
            case .unreliable: String(localized: "Audio sync couldn’t find a reliable match. The existing timing was kept.")
            }
        }
    }

    private static let framesPerSecond = 20.0
    private static let windowSeconds = 36.0
    private static let delayLimit = 30.0

    @MainActor
    static func estimate(engine: AetherEngine, cues: [SubtitleCue], startingDelay: Double = 0, rate: Double = 1) async throws -> Double {
        guard engine.state == .playing, rate.isFinite, (0.94...1.06).contains(rate) else {
            throw AlignmentError.unavailable
        }
        try Task.checkCancellation()
        let sourceTime = engine.clock.sourceTime
        guard sourceTime.isFinite, (0..<1_000_000_000).contains(sourceTime) else { throw AlignmentError.unavailable }
        let start = max(0, sourceTime - 1)
        let subtitleWindow = max(0, start - delayLimit)...(start + windowSeconds + delayLimit)
        let lines = cues.compactMap { cue -> ClosedRange<Double>? in
            guard cue.startTime.isFinite, cue.endTime.isFinite, cue.startTime >= 0,
                  (0.35...8).contains(cue.endTime - cue.startTime),
                  cue.endTime / rate >= subtitleWindow.lowerBound, cue.startTime / rate <= subtitleWindow.upperBound,
                  let text = cue.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.hasPrefix("["), !text.hasPrefix("("), !text.contains("♪"),
                  text.filter(\.isLetter).count >= 3 else { return nil }
            return (cue.startTime / rate)...(cue.endTime / rate)
        }
        guard lines.count >= 9 else { throw AlignmentError.insufficientDialogue }

        let audio = engine.installAudioTap(channels: .dialogue)
        defer { engine.removeAudioTap() }
        guard engine.audioTapHasDeliverySource else { throw AlignmentError.unavailable }

        let frames = try await withThrowingTaskGroup(of: [Double].self) { group in
            group.addTask { try await capture(audio, start: start) }
            group.addTask {
                try await Task.sleep(for: .seconds(50))
                throw AlignmentError.insufficientDialogue
            }
            defer { group.cancelAll() }
            guard let frames = try await group.next() else { throw AlignmentError.insufficientDialogue }
            return frames
        }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            findDelay(levels: frames, start: start, lines: lines, startingDelay: startingDelay)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard let result else { throw AlignmentError.unreliable }
        return result
    }

    private static func capture(_ audio: AsyncStream<AudioTapBuffer>, start: Double) async throws -> [Double] {
        let count = Int(windowSeconds * framesPerSecond)
        var power = Array(repeating: 0.0, count: count)
        var samples = Array(repeating: 0, count: count)
        var expectedEnd: Double?
        var low = 0.0
        var high = 0.0

        for await block in audio {
            try Task.checkCancellation()
            guard block.sourceTime.isFinite, let pcm = block.buffer.floatChannelData?[0], block.buffer.frameLength > 0 else { continue }
            let sampleRate = block.buffer.format.sampleRate
            guard sampleRate.isFinite, sampleRate >= 8_000 else { continue }
            if let expectedEnd, block.discontinuity, abs(expectedEnd - block.sourceTime) > 1 {
                throw AlignmentError.insufficientDialogue
            }
            expectedEnd = block.sourceTime + Double(block.buffer.frameLength) / sampleRate
            if block.sourceTime >= start + windowSeconds { break }
            let step = max(1, Int(sampleRate / 8_000))
            let secondsPerSample = Double(step) / sampleRate
            let bandRate = sampleRate / Double(step)
            let lowWeight = 1 - exp(-2 * .pi * 180 / bandRate)
            let highWeight = 1 - exp(-2 * .pi * 3_300 / bandRate)
            var sampleTime = block.sourceTime
            for index in stride(from: 0, to: Int(block.buffer.frameLength), by: step) {
                let value = Double(pcm[index])
                if value.isFinite {
                    low += lowWeight * (value - low)
                    high += highWeight * (value - high)
                    let relative = (sampleTime - start) * framesPerSecond
                    if relative >= 0, relative < Double(count) {
                        let bin = Int(relative)
                        let filtered = high - low
                        power[bin] += filtered * filtered
                        samples[bin] += 1
                    }
                }
                sampleTime += secondsPerSample
            }
        }
        try Task.checkCancellation()
        guard samples.filter({ $0 >= 100 }).count >= Int(0.8 * Double(count)) else {
            throw AlignmentError.insufficientDialogue
        }
        return zip(power, samples).map { power, count in
            count >= 100 ? 10 * log10(max(1e-12, power / Double(count))) : .nan
        }
    }

    /// Correlate speech-band loudness and caption occupancy across the same audio samples.
    /// A second-window check keeps isolated effects or repeated dialogue from selecting a shift.
    static func findDelay(levels: [Double], start: Double, lines: [ClosedRange<Double>], startingDelay: Double) -> Double? {
        guard levels.count >= 360, lines.count >= 9, start.isFinite, (0..<1_000_000_000).contains(start) else { return nil }
        let heard = levels.filter(\.isFinite).sorted()
        guard heard.count >= Int(0.8 * Double(levels.count)) else { return nil }
        let floor = heard[heard.count / 5]
        let ceiling = heard[heard.count * 4 / 5]
        guard ceiling - floor > 5, ceiling > -80 else { return nil }
        let activity = levels.map { $0.isFinite ? min(1, max(0, ($0 - floor) / (ceiling - floor))) : .nan }
        let margin = Int(delayLimit * framesPerSecond)
        let count = activity.count
        let origin = start - delayLimit
        var subtitles = Array(repeating: false, count: count + 2 * margin)
        var starts: [Int] = []
        for line in lines where line.lowerBound.isFinite && line.upperBound.isFinite {
            let first = ((line.lowerBound - origin) * framesPerSecond).rounded()
            let last = ((line.upperBound - origin) * framesPerSecond).rounded()
            guard last > 0, first < Double(subtitles.count) else { continue }
            let lower = Int(max(0, first))
            let upper = Int(min(Double(subtitles.count), last))
            guard lower < upper else { continue }
            if first >= 0 { starts.append(lower) }
            for index in lower..<upper { subtitles[index] = true }
        }

        var candidates: [Candidate] = []
        let halfway = count / 2
        for shift in -margin...margin {
            if Task.isCancelled { return nil }
            let offset = margin - shift
            let inside = starts.filter { $0 >= offset && $0 < offset + count }
            guard inside.count >= 9,
                  inside.filter({ $0 < offset + halfway }).count >= 4,
                  inside.filter({ $0 >= offset + halfway }).count >= 4 else { continue }
            let first = score(activity, mask: subtitles, offset: offset, range: 0..<halfway)
            let second = score(activity, mask: subtitles, offset: offset, range: halfway..<count)
            guard let first, let second else { continue }
            candidates.append(Candidate(shift: shift, first: first, second: second))
        }
        guard let peak = candidates.max(by: { $0.score < $1.score }), peak.score >= 0.14,
              min(peak.first, peak.second) >= 0.09 else { return nil }
        let near = Int(framesPerSecond * 0.75)
        let rivals = candidates.filter { abs($0.shift - peak.shift) > near }
        guard let rival = rivals.max(by: { $0.score < $1.score }), peak.score - rival.score >= 0.05,
              peak.first - (rivals.map(\.first).max() ?? 0) >= 0.025,
              peak.second - (rivals.map(\.second).max() ?? 0) >= 0.025 else { return nil }

        let prior = startingDelay.isFinite ? startingDelay : 0
        let plateau = candidates.filter { abs($0.shift - peak.shift) <= Int(framesPerSecond * 0.25) && peak.score - $0.score <= 0.008 }
        let selected = plateau.min(by: { abs(Double($0.shift) / framesPerSecond - prior) < abs(Double($1.shift) / framesPerSecond - prior) }) ?? peak
        return Double(selected.shift) / framesPerSecond
    }

    private struct Candidate {
        let shift: Int
        let first: Double
        let second: Double
        var score: Double { (first + second) / 2 }
    }

    private static func score(_ activity: [Double], mask: [Bool], offset: Int, range: Range<Int>) -> Double? {
        var speech = 0.0
        var silence = 0.0
        var speechCount = 0
        var silenceCount = 0
        for index in range where activity[index].isFinite {
            if mask[offset + index] {
                speech += activity[index]
                speechCount += 1
            } else {
                silence += activity[index]
                silenceCount += 1
            }
        }
        guard min(speechCount, silenceCount) >= max(25, range.count / 10) else { return nil }
        return speech / Double(speechCount) - silence / Double(silenceCount)
    }
}
