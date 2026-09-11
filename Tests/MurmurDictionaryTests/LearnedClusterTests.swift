import Foundation
import Testing

@testable import MurmurDictionary

/// An engine that fumbles a name rarely fumbles it the same way twice, so the evidence for one
/// name arrives split across spellings and each fragment falls below the threshold on its own.
/// Grouping by sound is what puts it back together — and the same grouping is what turns a
/// mishearing into a correction instead of a second term priming the error.
struct LearnedClusterTests {
    private let day: TimeInterval = 86_400
    private var base: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func runs(_ texts: [String]) -> [(text: String, date: Date)] {
        texts.indices.map { (text: texts[$0], date: base.addingTimeInterval(Double($0) * day)) }
    }

    private func clusters(
        _ texts: [String],
        excluding entries: [DictionaryEntry] = [],
        limit: Int = 40
    ) -> [LearnedCluster] {
        VocabularyLearner.clusters(from: runs(texts), excluding: entries, limit: limit)
    }

    // MARK: - Putting split evidence back together

    @Test("Two spellings of one name are one cluster, not two terms")
    func groupsSpellingsOfOneName() {
        let found = clusters([
            "We moved it to Supabase.",
            "The Soopabase migration is done.",
        ])

        #expect(found.count == 1)
        #expect(found[0].isSplit)
        #expect(Set(found[0].phrases) == ["Supabase", "Soopabase"])
    }

    @Test("A name spelled two ways clears the threshold neither spelling clears alone")
    func clusterEvidenceIsPooled() {
        // One sighting each. Ungrouped, both fall below minimumRuns and the name is lost.
        let texts = [
            "We moved it to Supabase.",
            "The Soopabase migration is done.",
        ]
        #expect(VocabularyLearner.minimumRuns == 2)
        #expect(clusters(texts)[0].runCount == 2)
    }

    @Test("One run that fumbles a name twice is still one sighting")
    func oneRunCountsOnce() {
        #expect(clusters(["Supabase, or Soopabase, whichever it is."]).isEmpty)
    }

    @Test("The best-evidenced spelling leads the cluster")
    func primaryIsTheCommonestSpelling() {
        let found = clusters([
            "The Soopabase migration.",
            "More Soopabase work.",
            "Actually it is Supabase.",
        ])

        #expect(found.count == 1)
        #expect(found[0].primary.phrase == "Soopabase")
        #expect(found[0].primary.runCount == 2)
    }

    // MARK: - What must not be grouped

    @Test("Ordinary-sounding phrases are never grouped by sound")
    func doesNotGroupOrdinarySpeech() {
        // "Is", "As" and "Us" share a phonetic code. Collapsing them into one name with three
        // spellings would be worse than not grouping at all.
        let found = clusters([
            "The Is and the As and the Us.",
            "Again the Is and the As and the Us.",
        ])

        #expect(found.allSatisfy { !$0.isSplit })
    }

    @Test("Names that merely resemble each other stay apart")
    func keepsDistinctNamesApart() {
        let found = clusters([
            "We run Kubernetes and Postgres.",
            "More Kubernetes and Postgres.",
        ])

        #expect(found.count == 2)
        #expect(found.allSatisfy { !$0.isSplit })
    }

    // MARK: - The flat view is unchanged

    @Test("learn() still returns one phrase per name, the best-evidenced one")
    func flatViewTakesThePrimary() {
        let flat = VocabularyLearner.learn(
            from: runs([
                "The Soopabase migration.",
                "More Soopabase work.",
                "Actually it is Supabase.",
            ]),
            excluding: [],
            limit: 40
        )

        #expect(flat.map(\.phrase) == ["Soopabase"])
    }

    @Test("A cluster spends one bias slot however many ways it was heard")
    func oneSlotPerName() {
        let found = clusters([
            "Supabase and Kubernetes.",
            "Soopabase and Kubernetes.",
        ], limit: 1)

        #expect(found.count == 1)
    }

    // MARK: - Matching a spelling already on file

    @Test("A mishearing of a dictionary entry is recognised as one")
    func findsTheKnownSpelling() {
        let entries = [DictionaryEntry.term("Supabase")]
        // The dictionary excludes its own spelling from mining, so only the mishearing is left.
        let found = clusters([
            "The Soopabase migration.",
            "More Soopabase work.",
        ], excluding: entries)

        #expect(found.count == 1)
        #expect(VocabularyLearner.knownSpelling(for: found[0], in: entries) == "Supabase")
    }

    @Test("A name the dictionary has never seen has no suggestion")
    func noSuggestionWithoutAMatch() {
        let found = clusters([
            "We run Kubernetes here.",
            "More Kubernetes work.",
        ])

        #expect(VocabularyLearner.knownSpelling(for: found[0], in: [.term("Supabase")]) == nil)
    }

    @Test("A disabled entry is not offered as the known spelling")
    func ignoresDisabledEntries() {
        let entries = [DictionaryEntry(kind: .term, write: "Supabase", isEnabled: false)]
        let found = clusters([
            "The Soopabase migration.",
            "More Soopabase work.",
        ], excluding: entries)

        #expect(VocabularyLearner.knownSpelling(for: found[0], in: entries) == nil)
    }

    // MARK: - Settling on a spelling

    @Test("Resolving writes a term plus a correction from every other spelling")
    func buildsTermAndCorrections() {
        let cluster = clusters([
            "The Soopabase migration.",
            "More Soopabase work.",
            "Actually it is Supabase.",
        ])[0]

        let entries = cluster.corrections(to: "Supabase")

        // Compared as file lines: entry equality includes a fresh UUID per instance.
        #expect(entries.map(\.fileLine) == ["Supabase", "Soopabase -> Supabase"])
    }

    @Test("A spelling the engine never produced can still be the correct one")
    func acceptsASpellingNotHeard() {
        // "Superbase" does not sound like "Supabase" to NYSIIS — the R lands in the code — so
        // it is mined as its own name and never clusters with the right spelling. This is the
        // case the Fix action exists for: the only route to the truth is the user typing it.
        let cluster = clusters([
            "The Superbase migration.",
            "More Superbase work.",
        ])[0]

        #expect(!cluster.isSplit)
        #expect(PhoneticKey.encode("Superbase") != PhoneticKey.encode("Supabase"))

        let entries = cluster.corrections(to: "Supabase")

        #expect(entries.map(\.write) == ["Supabase", "Supabase"])
        #expect(entries.compactMap { $0.kind == .correction ? $0.hear : nil } == ["Superbase"])
    }

    @Test("Confirming the spelling that was heard writes no correction to itself")
    func noSelfCorrection() {
        let cluster = clusters([
            "We run Kubernetes here.",
            "More Kubernetes work.",
        ])[0]

        #expect(cluster.corrections(to: "Kubernetes").map(\.fileLine) == ["Kubernetes"])
    }

    @Test("Case alone is not a correction worth writing")
    func treatsCaseAsTheSameSpelling() {
        let cluster = clusters([
            "We run Kubernetes here.",
            "More Kubernetes work.",
        ])[0]

        #expect(cluster.corrections(to: "kubernetes").map(\.fileLine) == ["kubernetes"])
    }

    @Test("An empty spelling settles nothing")
    func refusesBlank() {
        let cluster = clusters([
            "We run Kubernetes here.",
            "More Kubernetes work.",
        ])[0]

        #expect(cluster.corrections(to: "   ").isEmpty)
    }
}
