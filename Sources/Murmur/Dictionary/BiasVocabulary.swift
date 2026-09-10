import Foundation
import MurmurDictionary

/// What the speech engine is primed with, and where it came from.
struct BiasSelection: Sendable {
    /// The full list handed to the engine: dictionary phrases first, then learned ones.
    let phrases: [String]

    /// Just the mined subset, so the UI can show what the app taught itself rather than
    /// leaving the user to take it on faith.
    let learned: [LearnedTerm]

    static let empty = BiasSelection(phrases: [], learned: [])
}

/// Assembles the engine's bias list from two sources: the dictionary the user wrote, and
/// terms mined from what they've actually dictated.
///
/// **The dictionary always wins.** `DictionaryCorrector.biasLimit` is a hard ceiling — a long
/// context list makes these models drift and start emitting primed terms on quiet audio — so
/// the hand-written entries are laid down first and learning only fills what's left. A user
/// with 40 dictionary entries gets exactly the behaviour they had before this existed.
@MainActor
final class BiasVocabulary {
    static let shared = BiasVocabulary()

    /// How far back the learner looks.
    ///
    /// Bounds the string work done on the path that starts a recording, and doubles as decay:
    /// vocabulary you've stopped using falls out of the window instead of holding a slot for
    /// the life of the log.
    static let historyWindow = 500

    private var cacheKey: CacheKey?
    private var cached = BiasSelection.empty

    /// Everything the selection depends on. Recomputing costs a scan of `historyWindow`
    /// transcripts, and `current()` is called on the way into every recording, so it is
    /// recomputed only when one of these actually moves.
    private struct CacheKey: Equatable {
        let dictionaryRevision: Int
        let learningEnabled: Bool
        let runCount: Int
        let newestRun: Date?
        let dismissed: DismissedTerms
    }

    private init() {}

    func current() -> BiasSelection {
        let store = DictionaryStore.shared
        let learningEnabled = Settings.shared.learnVocabulary
        let dismissed = Settings.shared.dismissedLearnedTerms
        let runs = RunStore.shared.runs

        let key = CacheKey(
            dictionaryRevision: store.revision,
            learningEnabled: learningEnabled,
            runCount: runs.count,
            newestRun: runs.last?.date,
            dismissed: dismissed
        )
        if key == cacheKey { return cached }

        var phrases = DictionaryCorrector.biasPhrases(from: store.entries)
        var learned: [LearnedTerm] = []

        let room = DictionaryCorrector.biasLimit - phrases.count
        if learningEnabled, room > 0 {
            learned = VocabularyLearner.learn(
                from: Self.transcripts(from: runs),
                excluding: store.entries,
                dismissing: dismissed,
                limit: room
            )
            phrases.append(contentsOf: learned.map(\.phrase))
        }

        let selection = BiasSelection(phrases: phrases, learned: learned)
        cacheKey = key
        cached = selection
        return selection
    }

    /// Collapses the run log into one transcript per *utterance*.
    ///
    /// Compare mode records a separate run per engine for a single recording, all sharing a
    /// `group`. Left as-is those look like independent evidence, and one utterance in compare
    /// mode would clear `VocabularyLearner.minimumRuns` on its own — exactly the single-
    /// sighting case the threshold exists to reject. Grouped runs are therefore joined into
    /// one entry: a term any engine heard counts once for that utterance.
    private static func transcripts(from runs: [DictationRun]) -> [(text: String, date: Date)] {
        let recent = runs.suffix(historyWindow)

        var singles: [(text: String, date: Date)] = []
        var groups: [String: (texts: [String], date: Date)] = [:]
        var groupOrder: [String] = []

        for run in recent {
            guard let group = run.group else {
                singles.append((text: run.text, date: run.date))
                continue
            }
            if groups[group] == nil {
                groups[group] = (texts: [], date: run.date)
                groupOrder.append(group)
            }
            groups[group]?.texts.append(run.text)
            // Latest timestamp in the group, so recency ranking isn't decided by whichever
            // engine happened to finish first.
            if let existing = groups[group]?.date, run.date > existing {
                groups[group]?.date = run.date
            }
        }

        let merged = groupOrder.compactMap { key -> (text: String, date: Date)? in
            guard let entry = groups[key] else { return nil }
            return (text: entry.texts.joined(separator: "\n"), date: entry.date)
        }

        return singles + merged
    }
}
