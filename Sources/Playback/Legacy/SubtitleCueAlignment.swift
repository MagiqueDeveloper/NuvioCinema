import Foundation

enum SubtitleCueAlignment {
    private static let minimumOffsetMatches = 4
    private static let minimumDriftMatches = 6
    private static let driftSpan = 90.0
    private static let residualTolerance = 0.55
    private static let maximumDelay = 30.0
    private static let rateRange = 0.94...1.06

    /// Fits `externalTime = (referenceTime - delay) * rate`.
    static func fit(
        external: [(start: Double, text: String)],
        reference: [(start: Double, text: String)]
    ) -> (delay: Double, rate: Double)? {
        let externalTimes = uniqueTimes(in: external)
        let pairs = uniqueTimes(in: reference).compactMap { text, referenceTime in
            externalTimes[text].map { Pair(reference: referenceTime, external: $0) }
        }.sorted { $0.reference < $1.reference }

        let offset = candidate(at: 1, pairs: pairs, minimumMatches: minimumOffsetMatches, minimumSpan: 12)
        if let rate = driftRate(for: pairs),
           let drift = candidate(at: rate, pairs: pairs, minimumMatches: minimumDriftMatches, minimumSpan: driftSpan),
           offset.map({ drift.matches > $0.matches || drift.error + 0.12 < $0.error }) ?? true {
            return (drift.delay, rate)
        }
        return offset.map { ($0.delay, 1) }
    }

    private struct Pair {
        let reference: Double
        let external: Double
    }

    private struct Candidate {
        let delay: Double
        let error: Double
        let matches: Int
    }

    private static func uniqueTimes(in cues: [(start: Double, text: String)]) -> [String: Double] {
        var times: [String: Double] = [:]
        var repeated = Set<String>()
        for (start, text) in cues where start.isFinite && start >= 0 {
            let words = text
                .replacingOccurrences(of: #"<[^>]+>|\{[^}]+\}"#, with: " ", options: .regularExpression)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let line = words.joined(separator: " ")
            guard words.count >= 3, line.count >= 12, !repeated.contains(line) else { continue }
            if let previous = times[line] {
                // Duplicate packets at the same time can occur when a decoder rebuilds around a seek.
                if abs(previous - start) > 0.2 {
                    times[line] = nil
                    repeated.insert(line)
                }
            } else {
                times[line] = start
            }
        }
        return times
    }

    private static func driftRate(for pairs: [Pair]) -> Double? {
        guard pairs.count >= minimumDriftMatches,
              let first = pairs.first, let last = pairs.last, last.reference - first.reference >= driftSpan else {
            return nil
        }

        // Evenly sample long baselines. Short baselines amplify normal caption-authoring differences.
        let stride = max(1, pairs.count / 36)
        var slopes: [Double] = []
        for left in Swift.stride(from: 0, to: pairs.count, by: stride) {
            for right in Swift.stride(from: left + stride, to: pairs.count, by: stride) {
                let elapsed = pairs[right].reference - pairs[left].reference
                guard elapsed >= driftSpan else { continue }
                slopes.append((pairs[right].external - pairs[left].external) / elapsed)
            }
        }
        guard let rate = median(slopes), rateRange.contains(rate), abs(rate - 1) >= 0.002 else { return nil }
        return rate
    }

    private static func candidate(at rate: Double, pairs: [Pair], minimumMatches: Int, minimumSpan: Double) -> Candidate? {
        guard pairs.count >= minimumMatches,
              let delay = median(pairs.map { $0.reference - $0.external / rate }),
              abs(delay) <= maximumDelay else { return nil }
        let inliers = pairs.filter { abs($0.reference - $0.external / rate - delay) <= residualTolerance }
        guard inliers.count >= minimumMatches,
              inliers.count * 3 >= pairs.count * 2,
              let first = inliers.first, let last = inliers.last, last.reference - first.reference >= minimumSpan,
              let error = median(inliers.map({ abs($0.reference - $0.external / rate - delay) })) else { return nil }
        return Candidate(delay: delay, error: error, matches: inliers.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
