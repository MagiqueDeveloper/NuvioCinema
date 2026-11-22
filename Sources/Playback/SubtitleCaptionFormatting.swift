import Foundation

/// Puts a space after a speaker dash that has none ("-Uh" → "- Uh"). Safe for text
/// subtitles as well as recognized bitmap ones, and a no-op on text already spaced.
enum SubtitleDialogueSpacing {
    /// Hyphen-minus, en and em dashes, plus the Unicode hyphen, non-breaking hyphen and
    /// minus sign some subtitle files use for the speaker dash.
    private static let dashes = "\\-–—‐‑−"
    /// A speaker dash with no space after it: at the start of a line (after any leading
    /// annotations), or after a sentence ends mid-line ("-Yeah? -No."). A dash before a
    /// digit is left alone, as it is more likely a minus sign.
    private static let unspacedDialogueDash = try! NSRegularExpression(
        pattern: #"(?:^(\h*(?:\#(SubtitleCaptionFormatting.annotationPattern)\h*)*)|(?<=[.!?…])(\h+))([\#(dashes)])(?=[^\s\#(dashes)\d])"#,
        options: [.anchorsMatchLines]
    )

    static func spaced(_ text: String) -> String {
        guard text.contains(where: { "-–—‐‑−".contains($0) }) else { return text }
        return SubtitleCaptionFormatting.replacingMatches(of: unspacedDialogueDash, in: text) { source, match in
            let leading = [1, 2].compactMap { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }.joined()
            return leading + source.substring(with: match.range(at: 3)) + " "
        }
    }
}

enum SubtitleCaptionFormatting {
    static let annotationPattern = #"\[[^\[\]\v]*\]"#
    private static let annotation = try! NSRegularExpression(pattern: annotationPattern)
    private static let doubleDash = try! NSRegularExpression(pattern: #"(?<!-)--(?!-)"#)
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
        displayText = SubtitleDialogueSpacing.spaced(displayText)
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
                // Mixed-case words can be intentional, even at the start of a cue.
                let shouldCapitalize = capitalizeNext && !characters[(index + 1)...]
                    .prefix(while: \.isLetter).contains(where: \.isUppercase)
                result.append(shouldCapitalize ? String(character).uppercased() : String(character))
                capitalizeNext = false
                atLineStart = false
            } else {
                result.append(character)
                if character.isNewline {
                    atLineStart = true
                } else if character.isWhitespace {
                    // Keeps whatever the previous sentence left.
                } else if "-–—‐‑−".contains(character), atLineStart {
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

    static func replacingMatches(
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
    private static let musicGlyphs: Set<Character> = ["♪", "♫", "♬"]
    private static let possibleNotes: Set<String> = ["&", "&&", "J", "JJ", "#", "##", "¢", "s", "S", "ss", "d", "f", "j"]
    private static let dashes: Set<String> = ["-", "—", "–"]
    private static let pipeAsI = try! NSRegularExpression(pattern: #"(?<!\S)\|(?=['’]|\s|$)"#)

    static func cleaned(_ text: String) -> String {
        var inLyric = false
        let repaired = text.split(whereSeparator: \.isNewline)
            .map { cleanedLine(String($0), inLyric: &inLyric) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return SubtitleCaptionFormatting.formatted(repaired)
    }

    private static func cleanedLine(_ line: String, inLyric: inout Bool) -> String {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        let start = dashes.contains(tokens[0]) ? 1 : 0
        repairNotes(&tokens, from: start, inLyric: &inLyric)

        let result = repairBrackets(tokens.joined(separator: " "))
        return pipeAsI.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "I"
        )
    }

    private static func repairNotes(_ tokens: inout [String], from start: Int, inLyric: inout Bool) {
        guard start < tokens.count else { return }
        let last = tokens.count - 1
        let startsWithNote = tokens[start].allSatisfy { musicGlyphs.contains($0) }
        let endsWithNote = last > start && tokens[last].allSatisfy { musicGlyphs.contains($0) }
        if (inLyric || endsWithNote), possibleNotes.contains(tokens[start]) {
            tokens[start] = "♪"
        }
        let repairsEnd = last > start && (startsWithNote || inLyric) && possibleNotes.contains(tokens[last])
        if repairsEnd {
            tokens[last] = "♪"
        }
        inLyric = (startsWithNote || inLyric) && !endsWithNote && !repairsEnd
    }

    /// A pipe touching the annotation can be a misread bracket. When the boundary
    /// is missing entirely, keep the reading so dialogue is never pulled into an annotation.
    private static func repairBrackets(_ line: String) -> String {
        var chars = Array(line)
        var prefix = 0
        if let first = chars.first, dashes.contains(String(first)) {
            prefix = 1
            while prefix < chars.count, chars[prefix] == " " { prefix += 1 }
        }

        if let firstClose = chars.firstIndex(of: "]"), prefix + 1 < firstClose,
           chars[prefix] == "|", chars[prefix + 1].isLetter,
           !chars[prefix..<firstClose].contains("[") {
            chars[prefix] = "["
        }

        if let lastOpen = chars.lastIndex(of: "["), chars.count - lastOpen > 2,
           chars.last == "|", chars[chars.count - 2].isLetter,
           !chars[lastOpen...].contains("]") {
            chars[chars.count - 1] = "]"
        }
        return String(chars)
    }
}
