import Foundation
import Testing

@testable import MurmurDictionary

/// `VocabularyLearner` decides what gets fed to the speech engine as bias, out of a budget
/// of `DictionaryCorrector.biasLimit` slots shared with the user's hand-written dictionary.
/// Two properties matter more than coverage: it must never spend a slot on a word the
/// dictionary exists to *correct away from*, and it must not fire on single sightings.
struct VocabularyLearnerTests {
    private let day: TimeInterval = 86_400
    private var base: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func runs(_ texts: [String]) -> [(text: String, date: Date)] {
        texts.indices.map { (text: texts[$0], date: base.addingTimeInterval(Double($0) * day)) }
    }

    private func learn(
        _ texts: [String],
        excluding entries: [DictionaryEntry] = [],
        limit: Int = 40
    ) -> [String] {
        VocabularyLearner.learn(from: runs(texts), excluding: entries, limit: limit)
            .map(\.phrase)
    }

    // MARK: - The evidence threshold

    @Test("A word seen in two separate runs is learned")
    func learnsRecurringTerm() {
        #expect(learn([
            "We shipped the Kubernetes migration.",
            "The Kubernetes cluster is stable now.",
        ]) == ["Kubernetes"])
    }

    @Test("A single sighting is not enough")
    func ignoresOneOff() {
        // Indistinguishable from a mis-hearing, and biasing toward a mis-hearing teaches
        // the engine to repeat it.
        #expect(learn(["We shipped the Kubernetes migration."]).isEmpty)
    }

    @Test("Repetition inside one run is one piece of evidence, not many")
    func countsDistinctRunsNotOccurrences() {
        #expect(learn([
            "The Kubernetes cluster, the Kubernetes nodes, the Kubernetes operator.",
        ]).isEmpty)
    }

    // MARK: - What counts as a signal

    @Test("Sentence-initial capitalisation alone carries no signal")
    func ignoresSentenceInitialCapitals() {
        // "Tomorrow" is capitalised by grammar, not because it's a name.
        #expect(learn([
            "Tomorrow we ship.",
            "Tomorrow we rest.",
        ]).isEmpty)
    }

    @Test("Internal capitals count even at the start of a sentence")
    func learnsInternalCapitals() {
        #expect(learn([
            "macOS handles this differently.",
            "macOS ships it by default.",
        ]) == ["macOS"])
    }

    @Test("Adjacent capitalised words become one phrase")
    func mergesAdjacentCapitals() {
        #expect(learn([
            "I use Claude Code every day.",
            "She prefers Claude Code as well.",
        ]) == ["Claude Code"])
    }

    @Test("A phrase stops at three words")
    func capsPhraseLength() {
        let learned = learn([
            "It was Anna Maria Rodriguez Fernandez again.",
            "Ask Anna Maria Rodriguez Fernandez about it.",
        ])
        #expect(learned.contains("Anna Maria Rodriguez"))
        #expect(learned.allSatisfy { $0.split(separator: " ").count <= 3 })
    }

    @Test("A possessive is evidence for the root word")
    func stripsPossessive() {
        #expect(learn([
            "That was Anthropic's decision.",
            "I read Anthropic's post.",
        ]) == ["Anthropic"])
    }

    // MARK: - Exclusions

    @Test("Terms already in the dictionary don't burn a second slot")
    func excludesDictionaryWriteSide() {
        #expect(learn(
            ["We use Kubernetes here.", "The Kubernetes rollout finished."],
            excluding: [.term("Kubernetes")]
        ).isEmpty)
    }

    @Test("The trigger side of a correction is never learned")
    func excludesCorrectionTriggers() {
        // The load-bearing case. "Cloud Code" is in the history precisely because the engine
        // kept producing it; the dictionary exists to rewrite it. Learning it would bias the
        // engine toward the very error being corrected.
        let entries = [DictionaryEntry.correction(hear: "Cloud Code", write: "Claude Code")]
        #expect(learn(
            ["I opened Cloud Code again.", "Cloud Code keeps crashing in Cloud Code."],
            excluding: entries
        ).isEmpty)
    }

    @Test("Weekdays, months and I are not worth a slot")
    func excludesCommonCapitalisedWords() {
        #expect(learn([
            "On Tuesday I met the team in March.",
            "By Tuesday I had finished, back in March.",
        ]).isEmpty)
    }

    @Test("A stoplisted word breaks a phrase instead of joining it")
    func stoplistBreaksPhrases() {
        // The bug this pins: checking the stoplist against the finished phrase lets two
        // stoplisted words merge into a novel one ("Tuesday I") that passes every later check.
        #expect(learn([
            "We shipped Kubernetes Tuesday and Postgres Tuesday.",
            "Again, Kubernetes Tuesday and Postgres Tuesday.",
        ]) == ["Kubernetes", "Postgres"])
    }

    @Test("Exclusion matches across Unicode normalisation forms")
    func excludesAcrossNormalisation() {
        // macOS hands back decomposed strings; the dictionary file is typically precomposed.
        // Without NFC on both sides these are different keys and the exclusion silently misses.
        let decomposed = "Jose\u{301}"
        let precomposed = "José"
        #expect(learn(
            ["I asked \(decomposed) about it.", "Then \(decomposed) replied."],
            excluding: [.term(precomposed)]
        ).isEmpty)
    }

    // MARK: - Ranking and budget

    @Test("Ranked by how many runs it appeared in")
    func ranksByRunCount() {
        #expect(learn([
            "We discussed Kubernetes and Postgres.",
            "More on Kubernetes today.",
            "Still more on Kubernetes.",
            "A note about Postgres.",
        ]) == ["Kubernetes", "Postgres"])
    }

    @Test("Never returns more than the caller's budget")
    func respectsLimit() {
        let learned = learn([
            "We run Kubernetes and Postgres and Redis here.",
            "More on Kubernetes and Postgres and Redis.",
        ], limit: 2)
        #expect(learned.count == 2)
    }

    @Test("A zero budget returns nothing")
    func respectsZeroLimit() {
        // The dictionary can legitimately fill every slot on its own.
        #expect(learn(
            ["We run Kubernetes here.", "More Kubernetes."],
            limit: 0
        ).isEmpty)
    }

    @Test("The same history always produces the same list")
    func isDeterministic() {
        // Counts are built in a Dictionary, whose order is not stable between runs. Without
        // the alphabetical tie-break the bias list would shuffle for equally-ranked terms.
        let texts = [
            "We use Kubernetes and Postgres and Redis.",
            "Again: Kubernetes and Postgres and Redis.",
        ]
        let first = learn(texts)
        for _ in 0..<20 { #expect(learn(texts) == first) }
    }

    @Test("Empty history learns nothing")
    func handlesEmptyHistory() {
        #expect(learn([]).isEmpty)
        #expect(learn(["", "   "]).isEmpty)
    }
}
