import Foundation

/// Phrases the user has told the learner to stop suggesting.
///
/// A rejection has to outlive the evidence that produced it. The learner re-mines the whole
/// history window on every recording, so a term waved away once would otherwise reappear the
/// moment it was said again — and the same rejection would be asked for forever.
///
/// Keyed the way `VocabularyLearner` keys its own candidates: NFC first, then lower-cased.
/// macOS hands back decomposed strings, so without the normalisation a name dismissed as
/// "José" comes back as a fresh suggestion spelled identically.
public struct DismissedTerms: Sendable, Equatable {
    private var keys: Set<String>

    public static let none = DismissedTerms()

    public init() {
        keys = []
    }

    public init(_ phrases: some Sequence<String>) {
        keys = Set(phrases.map(Self.key)).subtracting([""])
    }

    public var isEmpty: Bool { keys.isEmpty }

    public var count: Int { keys.count }

    /// Sorted, so a rewrite of the stored list doesn't churn between launches.
    public var storageValues: [String] { keys.sorted() }

    public func contains(_ phrase: String) -> Bool {
        keys.contains(Self.key(phrase))
    }

    public mutating func insert(_ phrase: String) {
        let key = Self.key(phrase)
        guard !key.isEmpty else { return }
        keys.insert(key)
    }

    public mutating func remove(_ phrase: String) {
        keys.remove(Self.key(phrase))
    }

    public mutating func removeAll() {
        keys.removeAll()
    }

    static func key(_ phrase: String) -> String {
        phrase.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
