import Foundation

/// One correction that actually fired, kept so history can show whether the dictionary is
/// earning its place.
public struct AppliedCorrection: Codable, Hashable, Sendable {
    /// The text as the engine produced it.
    public let from: String
    /// What it was rewritten to.
    public let to: String
    /// How many times it fired in this transcript.
    public let count: Int
}

/// Rewrites transcribed text using the dictionary's correction pairs.
///
/// This is the guaranteed half of the dictionary. Engine biasing is a nudge — it raises the
/// odds of the right word and promises nothing — so anything that must be correct has to be
/// fixed here, after the fact, deterministically.
///
/// Two passes, in order. **The literal pass** applies the correction pairs you typed out.
/// **The phonetic pass** then catches spans that merely *sound* like something the dictionary
/// knows, which is what stops a name needing one rule per mishearing.
///
/// Three rules govern the literal pass, all load-bearing:
///
/// **Longest match first.** "Claude Code" is applied before "Claude", so the longer rule
/// isn't pre-empted by a shorter one that overlaps it.
///
/// **Whole matches only.** Every pattern is fenced by word boundaries, so a rule for
/// "cloud code" can never touch "Cloudflare" or the ordinary word "cloud".
///
/// **Glued words still match.** Engines run words together — "CloudCode", "cloud-code" — so
/// the gap between the parts of a phrase is matched as *optional* whitespace or hyphens
/// rather than a literal space.
public struct DictionaryCorrector: Sendable {
    private let rules: [Rule]
    private let phonetics: [String: String]

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let trigger: String
    }

    /// Longest span the phonetic pass will consider collapsing into one entry.
    ///
    /// Three, because a mishearing splits a name into more words than it started with —
    /// "Anthropic" arrives as "and thropic" — but past three the window starts swallowing
    /// ordinary sentences whole.
    public static let maxSpanWords = 3

    public init(entries: [DictionaryEntry]) {
        // Longest trigger first, so "Claude Code" wins over "Claude" and rewrites the span.
        let corrections = entries
            .filter { $0.isEnabled && $0.kind == .correction }
            .filter { !$0.hear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.hear.count > $1.hear.count }

        rules = corrections.compactMap { entry in
            guard let regex = Self.makeRegex(for: entry.hear) else { return nil }
            return Rule(
                regex: regex,
                replacement: NSRegularExpression.escapedTemplate(for: entry.write),
                trigger: entry.hear
            )
        }

        phonetics = Self.makePhonetics(from: entries)
    }

    public var isEmpty: Bool { rules.isEmpty && phonetics.isEmpty }

    /// Applies every rule in order, then the phonetic pass.
    ///
    /// - Returns: the rewritten text, plus one `AppliedCorrection` per distinct replacement
    ///   that fired.
    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection]) {
        guard !isEmpty, !text.isEmpty else { return (text, []) }

        // NFC on both sides, or an accented trigger silently never matches. See AGENTS.md.
        var result = text.precomposedStringWithCanonicalMapping
        var applied: [AppliedCorrection] = []

        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.numberOfMatches(in: result, range: range)
            guard matches > 0 else { continue }

            // Record what the engine produced, not the trigger: the real mishearing is the point.
            let firstMatch = rule.regex.firstMatch(in: result, range: range)
            let heard = firstMatch
                .flatMap { Range($0.range, in: result) }
                .map { String(result[$0]) } ?? rule.trigger

            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.replacement
            )

            Self.record(
                &applied,
                from: heard,
                to: rule.replacement.replacingOccurrences(of: "\\", with: ""),
                count: matches
            )
        }

        result = applyPhonetics(to: result, applied: &applied)

        return (result, applied)
    }

    // MARK: - Phonetic pass

    /// The sound-alike index: phonetic code to the text that should be written instead.
    ///
    /// An entry earns a place only if `PhoneticKey.isDistinctive` clears the phrase it would
    /// match on — the word itself for a term, the trigger for a correction. Naming a trigger
    /// yourself is not enough to make it safe: a rule reading "I in" to "Ayen" also rewrites
    /// "I am", because those are the same sound. A rejected entry keeps its literal rule and
    /// loses only the sound-alike family.
    ///
    /// First entry in file order wins a contested code, so the result is stable.
    private static func makePhonetics(from entries: [DictionaryEntry]) -> [String: String] {
        var index: [String: String] = [:]

        for entry in entries where entry.isEnabled {
            let write = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !write.isEmpty else { continue }

            let source = entry.kind == .term
                ? write
                : entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, PhoneticKey.isDistinctive(source) else { continue }

            let key = PhoneticKey.encode(source)
            guard index[key] == nil else { continue }
            index[key] = write
        }

        return index
    }

    /// Rewrites every span that sounds like something in the index.
    ///
    /// Longest span wins and spans never overlap, so a three-word match consumes its words and
    /// the scan resumes after them rather than re-matching a sub-span.
    private func applyPhonetics(to text: String, applied: inout [AppliedCorrection]) -> String {
        guard !phonetics.isEmpty else { return text }

        let words = Self.words(in: text)
        guard !words.isEmpty else { return text }

        var edits: [(range: Range<String.Index>, heard: String, replacement: String)] = []
        var start = 0

        while start < words.count {
            var span = min(Self.maxSpanWords, words.count - start)
            var matched = false

            while span >= 1 {
                if Self.isJoinable(words, from: start, count: span, in: text) {
                    let range = words[start].lowerBound..<words[start + span - 1].upperBound
                    let heard = String(text[range])
                    let key = PhoneticKey.encode(heard)

                    if key.count > 1, let replacement = phonetics[key],
                       heard.compare(replacement, options: .caseInsensitive) != .orderedSame {
                        edits.append((range, heard, replacement))
                        start += span
                        matched = true
                        break
                    }
                }
                span -= 1
            }

            if !matched { start += 1 }
        }

        guard !edits.isEmpty else { return text }

        var result = text
        for edit in edits.reversed() {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        for edit in edits {
            Self.record(&applied, from: edit.heard, to: edit.replacement, count: 1)
        }

        return result
    }

    /// The ranges of every word in `text`, in order.
    private static func words(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text) }
    }

    /// Whether the words `start..<start + count` are separated only by spaces or hyphens.
    ///
    /// Punctuation between two words means they belong to different thoughts, and a span that
    /// reaches across a full stop would let the pass rewrite the seam between two sentences.
    private static func isJoinable(
        _ words: [Range<String.Index>],
        from start: Int,
        count: Int,
        in text: String
    ) -> Bool {
        for offset in 1..<max(count, 1) {
            let gap = text[words[start + offset - 1].upperBound..<words[start + offset].lowerBound]
            if gap.contains(where: { !$0.isWhitespace && $0 != "-" }) { return false }
        }
        return true
    }

    /// Adds a correction, folding it into an existing record for the same replacement.
    ///
    /// One record per replacement, because that is what the shared vectors contract promises
    /// and what history renders as a single badge.
    private static func record(
        _ applied: inout [AppliedCorrection],
        from: String,
        to: String,
        count: Int
    ) {
        guard let existing = applied.firstIndex(where: { $0.to == to }) else {
            applied.append(AppliedCorrection(from: from, to: to, count: count))
            return
        }
        let previous = applied[existing]
        applied[existing] = AppliedCorrection(
            from: previous.from,
            to: to,
            count: previous.count + count
        )
    }

    // MARK: - Literal rules

    /// Builds the pattern for one trigger phrase.
    ///
    /// The parts are joined with `[\s\-]*` — zero or more spaces or hyphens — which is what
    /// catches "CloudCode" and "Cloud-Code" alongside the spaced form.
    ///
    /// The fences are lookarounds on letters and digits rather than `\b`. `\b` would treat a
    /// trailing hyphen or apostrophe as a boundary and let a rule bite into a longer word;
    /// requiring that no letter or digit sits on either side is the stricter guarantee, and
    /// it's what keeps "cloud code" off "Cloudflare".
    private static func makeRegex(for trigger: String) -> NSRegularExpression? {
        // NFC here too: a trigger typed in the UI and one read from disk differ in normal form.
        let parts = trigger
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }

        guard !parts.isEmpty else { return nil }

        let body = parts.joined(separator: "[\\s\\-]*")
        let pattern = "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])"

        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

// MARK: - Engine biasing

public extension DictionaryCorrector {
    /// The phrases to hand the speech engine as context before it transcribes.
    ///
    /// Kept deliberately short. These models drift when given a long context list — on quiet
    /// or ambiguous audio they start inventing text from the vocabulary they were primed
    /// with, which is a far worse failure than the misspelling it was meant to fix.
    static let biasLimit = 40

    /// - Returns: the correct spellings — `.term` words and the *write* side of corrections —
    ///   most recently useful first, capped at `biasLimit`.
    static func biasPhrases(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []

        for entry in entries where entry.isEnabled {
            let phrase = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            phrases.append(phrase)
            if phrases.count == biasLimit { break }
        }

        return phrases
    }
}
