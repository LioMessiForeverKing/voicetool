import Foundation

/// One thing the dictionary knows.
///
/// Two kinds, because the two jobs are genuinely different:
///
/// - `.term` — a word or phrase the engine should know exists: "Anthropic", "Vercel".
///   Feeds engine biasing only; it has no "wrong" spelling to correct.
/// - `.correction` — a mapping: when you hear X, write Y. "cloud code" → "Claude Code".
///   Feeds both biasing (on Y, the correct form) and the correction pass (X → Y).
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case term
        case correction
    }

    public var id: UUID
    public var kind: Kind

    /// The correct text. For `.term` this is the word itself; for `.correction` it's Y —
    /// what gets written. Either way this is what the engine gets biased toward.
    public var write: String

    /// For `.correction` only: the X in "when you hear X". Empty for `.term`.
    public var hear: String

    /// Disabled entries stay in the file but stop affecting anything, so you can test
    /// whether a rule is helping without deleting it.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    /// How this entry reads in the plain-text file.
    public var fileLine: String {
        let body = kind == .correction ? "\(hear) -> \(write)" : write
        return isEnabled ? body : "# off: \(body)"
    }
}

/// A reason an entry looks likely to fire on text you didn't mean it to.
///
/// Surfaced in the UI when an entry is added — the spec's "warn me if an entry looks like
/// it would match something common". Never blocks; you may genuinely want to rewrite a
/// common word, and it's your dictionary.
public struct DictionaryWarning: Identifiable, Sendable {
    public var id: String { message }
    public let message: String

    /// - Returns: warnings for `entry`, or empty if it looks safe.
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        // Only the trigger side can misfire. A `.term` is never matched against text.
        guard entry.kind == .correction else { return [] }

        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return [] }

        var warnings: [DictionaryWarning] = []
        let words = trigger.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" })

        if words.count == 1, let only = words.first {
            if CommonWords.all.contains(String(only)) {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is an ordinary word. This will rewrite every use of it, "
                        + "not just the ones you mean. Consider a longer phrase."
                ))
            } else if only.count <= 3 {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is very short and will match often. Consider a longer phrase."
                ))
            }
        }

        if entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(trigger) == .orderedSame {
            warnings.append(DictionaryWarning(
                message: "This rewrites “\(trigger)” to itself, so it will never change anything."
            ))
        }

        return warnings
    }

    /// - Returns: a warning when `entry` can only ever be matched literally, or empty.
    ///
    /// Sound-matching is what lets one entry cover every way an engine can fumble a name. A
    /// phrase that sounds like ordinary speech can't have it — rewriting everything that
    /// sounds like "Ayen" also rewrites "I am" and "is on" — and the entry would otherwise sit
    /// there looking like it worked. Telling you costs a line; letting you find out costs trust.
    public static func checkSoundMatching(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        let phrase = (entry.kind == .term ? entry.write : entry.hear)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !PhoneticKey.isDistinctive(phrase) else { return [] }

        let advice = entry.kind == .term
            ? "Add a correction — when you hear X, write “\(phrase)” — for each way it comes out wrong."
            : "It will still be corrected exactly as written."

        return [DictionaryWarning(
            message: "“\(phrase)” sounds like ordinary speech, so it can only be matched "
                + "letter for letter, not by sound. " + advice
        )]
    }
}
