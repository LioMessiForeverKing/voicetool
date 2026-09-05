import Foundation

/// One phrase mined out of the user's own transcripts.
public struct LearnedTerm: Sendable, Hashable {
    /// The phrase as it was actually written, casing preserved — the engine is biased
    /// toward this exact form.
    public let phrase: String

    /// How many *distinct* runs it appeared in. Not raw occurrences: one rambling
    /// dictation that says "Kubernetes" nine times is one piece of evidence, not nine.
    public let runCount: Int

    /// Most recent run it appeared in. Breaks ties so a vocabulary that has moved on
    /// decays out of the list rather than holding a slot forever.
    public let lastSeen: Date

    public init(phrase: String, runCount: Int, lastSeen: Date) {
        self.phrase = phrase
        self.runCount = runCount
        self.lastSeen = lastSeen
    }
}

/// Mines recurring proper nouns out of past transcripts so the engine can be biased toward
/// the words this speaker actually uses — the names, products and jargon that a general
/// model reliably fumbles.
///
/// **What it keys on.** Capitalisation, in two forms: a capitalised word that isn't starting
/// a sentence, and a word with capitals inside it (`GitHub`, `macOS`, `SwiftUI`). Together
/// these pick out almost exactly the category `prompt-design.txt` asks the dictionary to
/// cover — "names, jargon, product names, the people I work with" — without needing an
/// English lexicon to subtract.
///
/// **What it deliberately doesn't do.** It does not learn frequent *lower-case* words. With
/// only `DictionaryCorrector.biasLimit` slots to spend and a documented failure mode where a
/// long context list makes the model invent text on quiet audio, precision is worth far more
/// here than recall, and "words you say a lot" without a lexicon is mostly stop-words.
///
/// **Known limitation.** The signal is capitalisation, which is supplied by the cleanup pass.
/// With cleanup switched off, raw engine output is thinner on capitals and this learns
/// correspondingly less. It degrades to learning nothing, which is the safe direction.
public enum VocabularyLearner {
    /// Evidence threshold. One appearance is indistinguishable from a one-off mis-hearing,
    /// and biasing toward a mis-hearing actively teaches the engine to repeat it.
    public static let minimumRuns = 2

    /// Longest phrase assembled from adjacent capitalised words. Past three the run is
    /// almost always a title or a sentence fragment rather than a name.
    public static let maximumPhraseWords = 3

    /// - Parameters:
    ///   - transcripts: past runs, in any order.
    ///   - entries: the dictionary, used as an exclusion list — see below.
    ///   - limit: how many terms to return. Callers pass whatever the dictionary left over.
    /// - Returns: terms ranked by distinct-run count, then recency, then alphabetically so
    ///   the result is stable for a given history.
    public static func learn(
        from transcripts: [(text: String, date: Date)],
        excluding entries: [DictionaryEntry],
        limit: Int
    ) -> [LearnedTerm] {
        guard limit > 0 else { return [] }

        let excluded = exclusions(from: entries)

        var runCounts: [String: Int] = [:]      // key: lowercased phrase
        var lastSeen: [String: Date] = [:]
        var display: [String: String] = [:]     // key -> the casing to actually emit

        for transcript in transcripts {
            // A set, so repetition inside one run counts once.
            for phrase in Set(candidates(in: transcript.text)) {
                let key = phrase.lowercased()
                guard !excluded.contains(key) else { continue }

                runCounts[key, default: 0] += 1
                if let seen = lastSeen[key], seen >= transcript.date {
                    continue
                }
                lastSeen[key] = transcript.date
                // Newest spelling wins, so a rename shows up as the user now writes it.
                display[key] = phrase
            }
        }

        return runCounts
            .filter { $0.value >= minimumRuns }
            .map { key, count in
                LearnedTerm(
                    phrase: display[key] ?? key,
                    runCount: count,
                    lastSeen: lastSeen[key] ?? .distantPast
                )
            }
            .sorted { a, b in
                if a.runCount != b.runCount { return a.runCount > b.runCount }
                if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
                return a.phrase.lowercased() < b.phrase.lowercased()
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Exclusions

    /// Phrases the learner must never emit.
    ///
    /// Both sides of the dictionary, for different reasons:
    /// - The **write** side is already biased by `DictionaryCorrector.biasPhrases`, so
    ///   learning it again would burn a slot on a duplicate.
    /// - The **hear** side is the trigger of a correction — text the user has explicitly
    ///   told us is *wrong*. It appears in old transcripts precisely because the engine used
    ///   to produce it, and biasing toward it would teach the engine to keep making the
    ///   error the dictionary exists to fix. This one is load-bearing.
    private static func exclusions(from entries: [DictionaryEntry]) -> Set<String> {
        var excluded = Set<String>()
        for entry in entries {
            let write = entry.write.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !write.isEmpty { excluded.insert(write) }

            let hear = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !hear.isEmpty { excluded.insert(hear) }
        }
        return excluded
    }

    /// Capitalised in ordinary English without being worth a bias slot. Weekdays and months
    /// are the big one — they recur constantly in dictated text and every engine already
    /// spells them correctly.
    ///
    /// Applied per **word**, during extraction, so these break a phrase instead of joining
    /// one. Filtering the finished phrase instead is not equivalent and was wrong: "On
    /// Tuesday I met the team" merges two stoplisted words into "Tuesday I", which is in
    /// neither the stoplist nor the dictionary and survives every later check.
    ///
    /// The cost is a name that legitimately contains one of these — "March Networks", or a
    /// person called May — which won't be learned. Consistent with the rest of this type:
    /// with `DictionaryCorrector.biasLimit` slots to spend, precision beats recall, and the
    /// dictionary is there for anything the learner declines to pick up.
    private static let neverLearn: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "ok", "okay", "tv", "am", "pm",
    ]

    // MARK: - Extraction

    /// Every candidate phrase in one transcript, with duplicates — the caller de-duplicates.
    static func candidates(in text: String) -> [String] {
        var found: [String] = []

        for sentence in sentences(in: text) {
            let words = sentence.split(separator: " ").map(String.init)
            var run: [String] = []

            for (index, raw) in words.enumerated() {
                let word = clean(raw)

                // Index 0 is capitalised by grammar, not by meaning, so it carries no signal
                // on its own. It can still *continue* a phrase — but a phrase can't start there.
                let isSignal = !word.isEmpty
                    && !neverLearn.contains(word.lowercased())
                    && (isInternallyCapitalised(word) || (index > 0 && startsCapitalised(word)))

                if isSignal {
                    run.append(word)
                    if run.count == maximumPhraseWords {
                        found.append(run.joined(separator: " "))
                        run.removeAll()
                    }
                } else {
                    if !run.isEmpty { found.append(run.joined(separator: " ")) }
                    run.removeAll()
                }
            }

            if !run.isEmpty { found.append(run.joined(separator: " ")) }
        }

        return found
    }

    /// Split on sentence-ending punctuation and newlines. Crude on purpose: the only thing
    /// riding on it is knowing which word is first, and an abbreviation splitting a sentence
    /// early costs one missed candidate, never a wrong one.
    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Strips surrounding punctuation and a possessive tail, and normalises to NFC.
    ///
    /// NFC because macOS hands back decomposed strings: without it "José" from a transcript
    /// and "José" from the dictionary are different keys and the exclusion check misses.
    private static func clean(_ word: String) -> String {
        var trimmed = Substring(word.precomposedStringWithCanonicalMapping)

        while let first = trimmed.first, !first.isLetter, !first.isNumber {
            trimmed = trimmed.dropFirst()
        }
        while let last = trimmed.last, !last.isLetter, !last.isNumber {
            trimmed = trimmed.dropLast()
        }

        var result = String(trimmed)
        // "Anthropic's roadmap" is evidence for "Anthropic", not for "Anthropic's".
        for suffix in ["'s", "\u{2019}s"] where result.lowercased().hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
            break
        }
        return result
    }

    private static func startsCapitalised(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase
    }

    /// `GitHub`, `macOS`, `iPhone` — a capital anywhere but the front. Strong enough on its
    /// own that it counts even at the start of a sentence.
    private static func isInternallyCapitalised(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        return word.dropFirst().contains(where: { $0.isUppercase })
    }
}
