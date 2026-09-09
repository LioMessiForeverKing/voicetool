import Foundation

/// Ordinary English words, used wherever the dictionary needs to know that something is
/// unremarkable speech rather than a name.
///
/// Two callers, for the same reason in two shapes: `DictionaryWarning` refuses to let one of
/// these become a correction trigger, and `PhoneticKey` builds its safety net out of every
/// one- and two-word span they can form.
///
/// Deliberately short. It catches the obvious foot-guns, not every possible one.
public enum CommonWords {
    public static let all: Set<String> = [
        "a", "about", "all", "also", "am", "an", "and", "any", "are", "as", "at", "back", "be",
        "because", "been", "but", "by", "call", "can", "case", "check", "class", "close", "cloud",
        "code", "come", "could", "data", "day", "did", "do", "does", "down", "each", "even", "eye",
        "file", "find", "first", "for", "from", "get", "give", "go", "good", "great", "group",
        "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "just", "key", "know", "like", "line", "list", "look", "make", "man",
        "many", "may", "me", "more", "most", "my", "need", "new", "no", "not", "now", "number",
        "of", "off", "on", "one", "only", "open", "or", "other", "our", "out", "over", "page",
        "part", "people", "point", "put", "read", "right", "run", "said", "same", "say", "see",
        "set", "she", "should", "show", "side", "so", "some", "state", "still", "such", "take",
        "team", "test", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "thing", "think", "this", "time", "to", "two", "type", "up", "us", "use", "user", "very",
        "want", "was", "way", "we", "well", "were", "what", "when", "where", "which", "who",
        "will", "with", "word", "work", "would", "year", "you", "your",
    ]
}
