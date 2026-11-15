import Foundation

enum SubtitleCaptionFormatting {
    private static let annotationPattern = #"\[[^\[\]\v]*\]"#
    private static let annotation = try! NSRegularExpression(pattern: annotationPattern)
    private static let doubleDash = try! NSRegularExpression(pattern: #"(?<!-)--(?!-)"#)
    private static let dialogueStart = try! NSRegularExpression(
        pattern: #"^(\h*(?:\#(annotationPattern)\h*)*[-—])\h*((?:\#(annotationPattern)\h*)*["'“‘«]*)(\p{L}\p{M}*)"#,
        options: [.anchorsMatchLines]
    )

    static func formatted(_ text: String) -> String {
        var displayText = text
        if displayText.contains("--") {
            displayText = doubleDash.stringByReplacingMatches(
                in: displayText,
                range: NSRange(displayText.startIndex..., in: displayText),
                withTemplate: "—"
            )
        }
        if displayText.contains("[") {
            displayText = replacingMatches(of: annotation, in: displayText) { source, match in
                source.substring(with: match.range).uppercased()
            }
        }
        if displayText.contains("-") || displayText.contains("—") {
            displayText = replacingMatches(of: dialogueStart, in: displayText) { source, match in
                let marker = source.substring(with: match.range(at: 1))
                let opening = source.substring(with: match.range(at: 2))
                let initial = source.substring(with: match.range(at: 3))
                return marker + " " + opening + initial.uppercased()
            }
        }
        return displayText
    }

    private static func replacingMatches(
        of expression: NSRegularExpression,
        in text: String,
        with replacement: (NSString, NSTextCheckingResult) -> String
    ) -> String {
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: replacement(source, match))
        }
        return result as String
    }
}
