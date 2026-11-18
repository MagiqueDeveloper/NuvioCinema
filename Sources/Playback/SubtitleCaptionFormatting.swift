import Foundation

enum SubtitleCaptionFormatting {
    private static let annotationPattern = #"\[[^\[\]\v]*\]"#
    private static let annotation = try! NSRegularExpression(pattern: annotationPattern)
    private static let doubleDash = try! NSRegularExpression(pattern: #"(?<!-)--(?!-)"#)
    /// A speaker dash with no space after it: at the start of a line (after any leading
    /// annotations), or after a sentence ends mid-line ("-Yeah? -No."). A dash before a
    /// digit is left alone, as it is more likely a minus sign.
    private static let unspacedDialogueDash = try! NSRegularExpression(
        pattern: #"(?:^(\h*(?:\#(annotationPattern)\h*)*)|(?<=[.!?…])(\h+))([-–—])(?=[^\s\-–—\d])"#,
        options: [.anchorsMatchLines]
    )
    /// A lone lowercase "i" used as the English pronoun, including "i'm" and "i'll".
    private static let lowercasePronoun = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}'’\-])i(?![\p{L}\p{M}\p{N}\-])(?!\.\p{L})"#
    )
    private static let pronounContraction = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}'’\-])i['’](?:m|ll|ve|d)\b"#
    )
    /// Common English words. A plain lowercase "i" is an article in Italian, so it is only
    /// read as the pronoun when the cue is evidently English.
    private static let englishMarker = try! NSRegularExpression(
        pattern: #"\b(?:the|you|your|and|what|that|this|have|was|is|am|it's|don't|can't|know|just|my)\b"#,
        options: [.caseInsensitive]
    )
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "mt", "prof"]

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
        if displayText.contains("-") || displayText.contains("–") || displayText.contains("—") {
            displayText = replacingMatches(of: unspacedDialogueDash, in: displayText) { source, match in
                let leading = [1, 2].compactMap { index -> String? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : source.substring(with: range)
                }.joined()
                return leading + source.substring(with: match.range(at: 3)) + " "
            }
        }
        displayText = capitalizingSentences(displayText)
        return capitalizingPronoun(displayText)
    }

    /// Capitalizes the first letter of each sentence: at the start of the cue, after a
    /// speaker dash at the start of a line, and after ".", "!" or "?". Bracketed and
    /// parenthesized annotations are skipped over, so "[GROANS] what" becomes
    /// "[GROANS] What". A line that continues the previous one ("I have such\na game") and
    /// text after an ellipsis are left as they are.
    private static func capitalizingSentences(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var capitalizeNext = true
        var atLineStart = true
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "[" || character == "(",
               let close = characters[(index + 1)...].firstIndex(of: character == "[" ? "]" : ")"),
               !characters[index..<close].contains(where: \.isNewline) {
                result.append(contentsOf: characters[index...close])
                index = close + 1
                continue
            }

            if character.isLetter {
                result.append(capitalizeNext ? String(character).uppercased() : String(character))
                capitalizeNext = false
                atLineStart = false
            } else {
                result.append(character)
                if character.isNewline {
                    atLineStart = true
                } else if character.isWhitespace {
                    // Keeps whatever the previous sentence left.
                } else if "-–—".contains(character), atLineStart {
                    capitalizeNext = true
                    atLineStart = false
                } else if character == "…" {
                    capitalizeNext = false
                    atLineStart = false
                } else if ".!?".contains(character) {
                    capitalizeNext = endsSentence(characters, at: index)
                    atLineStart = false
                } else if character.isNumber || ",;:".contains(character) {
                    capitalizeNext = false
                    atLineStart = false
                } else if !"\"'“”‘’«»♪♫¿¡".contains(character) {
                    atLineStart = false
                }
            }
            index += 1
        }
        return result
    }

    private static func endsSentence(_ characters: [Character], at index: Int) -> Bool {
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        guard characters[index] == "." else {
            return next.map { $0.isWhitespace || "\"'”’)]".contains($0) } ?? true
        }
        // An ellipsis written as dots continues the sentence.
        if next == "." || (index > 0 && characters[index - 1] == ".") { return false }
        guard next.map({ $0.isWhitespace || "\"'”’)]".contains($0) }) ?? true else { return false }

        var start = index
        while start > 0, characters[start - 1].isLetter { start -= 1 }
        let word = String(characters[start..<index]).lowercased()
        if abbreviations.contains(word) { return false }
        // The last letter of a dotted abbreviation such as "a.m." or "U.S.".
        if word.count == 1, start > 0, characters[start - 1] == "." { return false }
        return true
    }

    private static func capitalizingPronoun(_ text: String) -> String {
        guard text.contains("i") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let isEnglish = pronounContraction.firstMatch(in: text, range: range) != nil
            || englishMarker.firstMatch(in: text, range: range) != nil
        guard isEnglish else { return text }
        return lowercasePronoun.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
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

/// Repairs the mistakes text recognition makes on bitmap subtitles. Vision has no music
/// note glyph and reads it as the nearest Latin character, and it often drops a bracket
/// at the edge of a tightly cropped cue.
enum SubtitleOCRCleanup {
    /// Read as a note at either edge of a line.
    private static let strongNotes: Set<String> = ["♪", "♪♪", "♫", "♬", "&", "&&", "J", "JJ", "#", "##", "¢"]
    /// Real words or initials too, so read as a note only next to other lyric context.
    private static let weakNotes: Set<String> = ["s", "S", "ss", "d", "f", "j"]
    private static let dashes: Set<String> = ["-", "—", "–"]
    private static let bracketOpenStandIns: Set<Character> = ["l", "|", "I", "1"]
    private static let pipeAsI = try! NSRegularExpression(pattern: #"\|(?=[\p{Ll}'’\s]|$)"#)

    static func cleaned(_ text: String) -> String {
        var inLyric = false
        return text.split(whereSeparator: \.isNewline)
            .map { cleanedLine(String($0), inLyric: &inLyric) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func cleanedLine(_ line: String, inLyric: inout Bool) -> String {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        let start = dashes.contains(tokens[0]) ? 1 : 0
        repairNotes(&tokens, from: start, inLyric: &inLyric)

        var result = tokens.joined(separator: " ")
        result = repairBrackets(result, open: "[", close: "]", openStandIns: bracketOpenStandIns, closeStandIns: ["|"])
        result = repairBrackets(result, open: "(", close: ")", openStandIns: [], closeStandIns: [])
        return pipeAsI.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "I"
        )
    }

    private static func repairNotes(_ tokens: inout [String], from start: Int, inLyric: inout Bool) {
        guard start < tokens.count else { return }
        var leading = false
        if strongNotes.contains(tokens[start]) || weakNotes.contains(tokens[start]) {
            tokens[start] = "♪"
            leading = true
        }
        let last = tokens.count - 1
        var trailing = false
        if last > start, strongNotes.contains(tokens[last])
            || ((leading || inLyric) && weakNotes.contains(tokens[last])) {
            tokens[last] = "♪"
            trailing = true
        }
        if trailing || (leading && last == start) {
            inLyric = false
        } else if leading {
            inLyric = true
        }
    }

    private static func repairBrackets(
        _ line: String,
        open: Character,
        close: Character,
        openStandIns: Set<Character>,
        closeStandIns: Set<Character>
    ) -> String {
        var chars = Array(line)
        var prefix = 0
        if let first = chars.first, dashes.contains(String(first)) {
            prefix = 1
            while prefix < chars.count, chars[prefix] == " " { prefix += 1 }
        }

        // "crunching]" or "- lcrunching]" → "[crunching]" / "- [crunching]"
        if let firstClose = chars.firstIndex(of: close), firstClose > prefix, !chars[..<firstClose].contains(open) {
            if openStandIns.contains(chars[prefix]), prefix + 1 < firstClose, chars[prefix + 1].isLowercase {
                chars[prefix] = open
            } else {
                chars.insert(open, at: prefix)
            }
        }

        // "[sighs" or "[sighs|" → "[sighs]"
        if let lastOpen = chars.lastIndex(of: open), chars.count - lastOpen > 1, !chars[lastOpen...].contains(close) {
            if let last = chars.last, closeStandIns.contains(last), chars.count - lastOpen > 2 {
                chars[chars.count - 1] = close
            } else {
                chars.append(close)
            }
        }
        return String(chars)
    }
}
