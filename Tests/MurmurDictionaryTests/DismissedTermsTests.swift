import Foundation
import Testing

@testable import MurmurDictionary

/// Rejecting a learned term is the only way to say "stop offering me this", and it has to
/// hold against evidence: the learner re-mines the whole history window before every
/// recording, so a term waved away once is still sitting there, still recurring, still
/// clearing the threshold. Anything less than a durable, normalised rejection means the same
/// suggestion comes back forever.
struct DismissedTermsTests {
    private let day: TimeInterval = 86_400
    private var base: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func runs(_ texts: [String]) -> [(text: String, date: Date)] {
        texts.indices.map { (text: texts[$0], date: base.addingTimeInterval(Double($0) * day)) }
    }

    private func learn(
        _ texts: [String],
        dismissing dismissed: DismissedTerms = .none,
        limit: Int = 40
    ) -> [String] {
        VocabularyLearner.learn(
            from: runs(texts),
            excluding: [],
            dismissing: dismissed,
            limit: limit
        ).map(\.phrase)
    }

    private var recurring: [String] {
        [
            "We run Kubernetes and Postgres here.",
            "More about Kubernetes and Postgres.",
        ]
    }

    // MARK: - The rejection holds

    @Test("A dismissed term is not learned, however often it recurs")
    func dismissedTermStaysGone() {
        #expect(learn(recurring, dismissing: DismissedTerms(["Kubernetes"])) == ["Postgres"])
    }

    @Test("Dismissing every candidate leaves nothing")
    func dismissingEverythingLearnsNothing() {
        #expect(learn(recurring, dismissing: DismissedTerms(["Kubernetes", "Postgres"])).isEmpty)
    }

    @Test("Nothing dismissed changes nothing")
    func emptyDismissalIsInert() {
        #expect(learn(recurring) == learn(recurring, dismissing: .none))
    }

    // MARK: - Matching the way the learner keys its own candidates

    @Test("Casing does not matter to a rejection")
    func matchesRegardlessOfCase() {
        #expect(learn(recurring, dismissing: DismissedTerms(["kUbErNeTeS"])) == ["Postgres"])
    }

    @Test("A decomposed name matches the composed one it was dismissed as")
    func matchesAcrossUnicodeNormalisation() {
        // macOS hands back decomposed strings; the stored rejection is composed.
        let decomposed = "Jose\u{0301}"
        let composed = "Jos\u{00E9}"

        #expect(DismissedTerms([composed]).contains(decomposed))
        #expect(DismissedTerms([decomposed]).contains(composed))

        let transcripts = [
            "I spoke to \(decomposed) about it.",
            "Then \(decomposed) replied.",
        ]
        #expect(learn(transcripts) == [composed])
        #expect(learn(transcripts, dismissing: DismissedTerms([composed])).isEmpty)
    }

    @Test("Surrounding whitespace is not part of a rejection")
    func trimsWhitespace() {
        #expect(DismissedTerms(["  Kubernetes  "]).contains("Kubernetes"))
    }

    @Test("Blank phrases are not rejections and never dismiss anything")
    func ignoresBlankPhrases() {
        var terms = DismissedTerms(["", "   "])
        #expect(terms.isEmpty)

        terms.insert("  ")
        #expect(terms.isEmpty)
        #expect(learn(recurring, dismissing: terms) == learn(recurring))
    }

    // MARK: - The slot it frees

    @Test("A rejection frees its bias slot for the next candidate")
    func dismissingFreesASlot() {
        // Filtering after the fact instead of before would leave this slot spent on a term
        // the user rejected, and the list one shorter than the budget allows.
        #expect(learn(recurring, limit: 1) == ["Kubernetes"])
        #expect(learn(recurring, dismissing: DismissedTerms(["Kubernetes"]), limit: 1) == ["Postgres"])
    }

    // MARK: - Restoring

    @Test("Removing a rejection lets the term be learned again")
    func removingRestoresTheTerm() {
        var terms = DismissedTerms(["Kubernetes"])
        #expect(learn(recurring, dismissing: terms) == ["Postgres"])

        terms.remove("kubernetes")
        #expect(learn(recurring, dismissing: terms) == ["Kubernetes", "Postgres"])
    }

    @Test("Restoring everything brings every term back")
    func removeAllRestoresEveryTerm() {
        var terms = DismissedTerms(["Kubernetes", "Postgres"])
        terms.removeAll()

        #expect(terms.isEmpty)
        #expect(learn(recurring, dismissing: terms) == ["Kubernetes", "Postgres"])
    }

    // MARK: - Persistence

    @Test("Rejections survive a round trip through storage")
    func survivesStorageRoundTrip() {
        var terms = DismissedTerms()
        terms.insert("Kubernetes")
        terms.insert("Postgres")

        #expect(DismissedTerms(terms.storageValues) == terms)
        #expect(learn(recurring, dismissing: DismissedTerms(terms.storageValues)).isEmpty)
    }

    @Test("Stored rejections are ordered, so rewriting the list does not churn")
    func storageIsStable() {
        #expect(DismissedTerms(["Postgres", "Kubernetes"]).storageValues == ["kubernetes", "postgres"])
    }

    @Test("Dismissing the same term twice counts once")
    func rejectionsAreASet() {
        var terms = DismissedTerms(["Kubernetes"])
        terms.insert("kubernetes")
        terms.insert("  KUBERNETES ")

        #expect(terms.count == 1)
    }
}
