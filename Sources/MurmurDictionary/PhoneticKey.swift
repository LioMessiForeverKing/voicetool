import Foundation

/// A coarse code for how a word or phrase *sounds*, so the dictionary can catch mishearings
/// nobody typed out in advance.
///
/// The literal correction rules fix exactly the spelling you gave them. An engine that
/// fumbles a name rarely fumbles it the same way twice — "Anthropic" comes back as
/// "and thropic", "Anthropik", "Antropic" — so matching by sound is what turns one dictionary
/// entry into a rule that covers the whole family.
///
/// **The algorithm is NYSIIS**, picked because it was built for surnames and this dictionary
/// is mostly names. Two departures from the published version, both load-bearing:
///
/// - **No truncation.** Classic NYSIIS cuts the code to six characters, which collapses
///   "Kubernetes" and "Kubernetic" into one. Long product names are exactly what this has to
///   keep apart, so the code runs to full length.
/// - **A soft `C` codes as `S`.** NYSIIS keeps `C` verbatim, which puts "Vercel" and
///   "Versell" in different buckets — exactly the confusion an engine makes.
/// - **A leading vowel folds to `A`.** An engine that mishears a name almost never gets its
///   first vowel right — "Ayen" arrives as "I in", "eye in", "Ayan" — and NYSIIS otherwise
///   keys the first letter verbatim, which would put every one of those in a different bucket.
public enum PhoneticKey {
    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]

    private static let prefixes = [("MAC", "MCC"), ("KN", "NN"), ("K", "C"),
                                   ("PH", "FF"), ("PF", "FF"), ("SCH", "SSS")]

    private static let suffixes = [("EE", "Y"), ("IE", "Y"), ("DT", "D"),
                                   ("RT", "D"), ("RD", "D"), ("NT", "D"), ("ND", "D")]

    /// - Returns: the phonetic code for `text`, or an empty string if it holds no letters.
    ///   Spaces and punctuation are dropped, so a phrase codes as if it were run together —
    ///   which is the point, since "and thropic" and "Anthropic" are the same sound.
    public static func encode(_ text: String) -> String {
        let letters = text.precomposedStringWithCanonicalMapping.uppercased().filter(\.isLetter)
        guard !letters.isEmpty else { return "" }

        var body = letters
        for (prefix, replacement) in prefixes where body.hasPrefix(prefix) {
            body = replacement + body.dropFirst(prefix.count)
            break
        }
        for (suffix, replacement) in suffixes where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)) + replacement
            break
        }

        let chars = Array(body)
        var key = String(chars[0])
        var index = 1

        while index < chars.count {
            let (piece, consumed) = translate(chars, at: index, key: key)
            if let last = piece.last, last != key.last { key += piece }
            index += consumed
        }

        return finish(key)
    }

    /// Whether `text` is distinctive enough that matching it by sound is safe.
    ///
    /// The trap is a name that is also a sentence: "Ayen" sounds like "I am", "is on" and
    /// "a yen", so sound-matching it rewrites ordinary speech several times a paragraph. The
    /// only honest test is to look, so this checks the code against every one- and two-word
    /// span the common words can form.
    public static func isDistinctive(_ text: String) -> Bool {
        let key = encode(text)
        guard key.count > 1 else { return false }
        return !commonSpanKeys.contains(key)
    }

    /// Every code ordinary English can produce in one or two words.
    ///
    /// Computed once per process rather than per corrector: the word list is a constant, and
    /// the corrector is rebuilt on every dictation.
    private static let commonSpanKeys: Set<String> = {
        let words = Array(CommonWords.all)
        var keys = Set<String>(minimumCapacity: words.count * words.count)
        for first in words {
            keys.insert(encode(first))
            for second in words { keys.insert(encode(first + second)) }
        }
        return keys
    }()

    // MARK: - Encoding

    /// - Returns: the code fragment for the character at `index`, and how many source
    ///   characters it consumed.
    private static func translate(_ chars: [Character], at index: Int, key: String) -> (String, Int) {
        let char = chars[index]

        if matches(chars, index, "EV") { return ("AF", 2) }
        if vowels.contains(char) { return ("A", 1) }
        if char == "C", index + 1 < chars.count, "EIY".contains(chars[index + 1]) { return ("S", 1) }
        if char == "Q" { return ("G", 1) }
        if char == "Z" { return ("S", 1) }
        if char == "M" { return ("N", 1) }
        if matches(chars, index, "KN") { return ("N", 2) }
        if char == "K" { return ("C", 1) }
        if matches(chars, index, "SCH") { return ("SSS", 3) }
        if matches(chars, index, "PH") { return ("FF", 2) }

        let previous = chars[index - 1]
        let nextIsConsonant = index + 1 < chars.count && !vowels.contains(chars[index + 1])
        if char == "H", !vowels.contains(previous) || nextIsConsonant {
            return (String(key.last!), 1)
        }
        if char == "W", vowels.contains(previous) {
            return (String(key.last!), 1)
        }

        return (String(char), 1)
    }

    private static func matches(_ chars: [Character], _ index: Int, _ pattern: String) -> Bool {
        let wanted = Array(pattern)
        guard index + wanted.count <= chars.count else { return false }
        return Array(chars[index..<(index + wanted.count)]) == wanted
    }

    /// NYSIIS also strips a trailing `S`, folds a trailing `AY` and drops a trailing `A`,
    /// none of which survive here. They exist to make surname variants collide, and collide
    /// is precisely what they did: with them, "Ian is" coded the same as "Ian" and the pass
    /// ate the following word.
    private static func finish(_ code: String) -> String {
        guard let first = code.first, vowels.contains(first) else { return code }
        return "A" + code.dropFirst()
    }
}
