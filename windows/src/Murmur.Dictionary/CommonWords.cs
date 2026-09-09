namespace Murmur.Dictionary;

/// <summary>
/// Ordinary English words, used wherever the dictionary needs to know that something is
/// unremarkable speech rather than a name.
/// </summary>
/// <remarks>
/// Two callers, for the same reason in two shapes: <see cref="DictionaryWarning"/> refuses to
/// let one of these become a correction trigger, and <see cref="PhoneticKey"/> builds its
/// safety net out of every one- and two-word span they can form.
/// <para>
/// Kept byte-identical to <c>CommonWords.swift</c>, so both platforms refuse the same entries.
/// </para>
/// </remarks>
public static class CommonWords
{
    /// <summary>The list. Deliberately short — obvious foot-guns, not every possible one.</summary>
    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
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
    };
}
