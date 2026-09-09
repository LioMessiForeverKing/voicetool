namespace Murmur.Dictionary;

/// <summary>
/// One thing the dictionary knows.
/// </summary>
/// <remarks>
/// Mirrors <c>DictionaryEntry.swift</c> in the macOS app. The two implementations are
/// independent; <c>shared/dictionary-test-vectors.json</c> is what keeps them honest.
/// </remarks>
public enum EntryKind
{
    /// <summary>A word or phrase the engine should know exists. Biasing only.</summary>
    Term,

    /// <summary>A mapping: when you hear X, write Y. Biasing *and* the correction pass.</summary>
    Correction,
}

/// <inheritdoc cref="EntryKind"/>
public sealed record DictionaryEntry
{
    /// <summary>Stable identity, so an entry can be edited or deleted unambiguously.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>Which of the two kinds this entry is.</summary>
    public EntryKind Kind { get; init; }

    /// <summary>
    /// The correct text. For <see cref="EntryKind.Term"/> this is the word itself; for
    /// <see cref="EntryKind.Correction"/> it is Y — what gets written. Either way this is
    /// what the engine is biased toward.
    /// </summary>
    public string Write { get; init; } = string.Empty;

    /// <summary>
    /// For <see cref="EntryKind.Correction"/> only: the X in "when you hear X".
    /// </summary>
    public string Hear { get; init; } = string.Empty;

    /// <summary>
    /// Disabled entries stay in the file but stop affecting anything, so a rule can be
    /// tested without being deleted.
    /// </summary>
    public bool IsEnabled { get; init; } = true;

    /// <summary>A word or phrase the engine should know exists.</summary>
    /// <param name="word">The correct spelling.</param>
    public static DictionaryEntry Term(string word) =>
        new() { Kind = EntryKind.Term, Write = word };

    /// <summary>A mapping from a mishearing to the correct text.</summary>
    /// <param name="hear">What the engine produces — the X in "when you hear X".</param>
    /// <param name="write">What should be written instead.</param>
    public static DictionaryEntry Correction(string hear, string write) =>
        new() { Kind = EntryKind.Correction, Hear = hear, Write = write };

    /// <summary>How this entry reads in the plain-text file.</summary>
    public string ToFileLine()
    {
        var body = Kind == EntryKind.Correction ? $"{Hear} -> {Write}" : Write;
        return IsEnabled ? body : $"# off: {body}";
    }
}

/// <summary>
/// A reason an entry looks likely to fire on text it wasn't meant to.
/// </summary>
/// <remarks>
/// Never blocks. It is the user's dictionary, and rewriting a common word is occasionally
/// exactly what they want.
/// </remarks>
public sealed record DictionaryWarning(string Message)
{
    private static readonly char[] PhraseSeparators = [' ', '-', '\t'];

    /// <summary>Checks an entry for patterns likely to fire on unintended text.</summary>
    /// <param name="entry">The entry to inspect.</param>
    /// <returns>Warnings to show the user, or empty if the entry looks safe.</returns>
    public static IReadOnlyList<DictionaryWarning> Check(DictionaryEntry entry)
    {
        // Only the trigger side can misfire. A Term is never matched against text.
        if (entry.Kind != EntryKind.Correction) return [];

        var trigger = entry.Hear.Trim();
        if (trigger.Length == 0) return [];

        var warnings = new List<DictionaryWarning>();
        var words = trigger.Split(PhraseSeparators, StringSplitOptions.RemoveEmptyEntries);

        if (words.Length == 1)
        {
            var only = words[0];
            if (CommonWords.All.Contains(only))
            {
                warnings.Add(new DictionaryWarning(
                    $"“{trigger}” is an ordinary word. This will rewrite every use of it, "
                    + "not just the ones you mean. Consider a longer phrase."));
            }
            else if (only.Length <= 3)
            {
                warnings.Add(new DictionaryWarning(
                    $"“{trigger}” is very short and will match often. Consider a longer phrase."));
            }
        }

        if (string.Equals(entry.Write.Trim(), trigger, StringComparison.OrdinalIgnoreCase))
        {
            warnings.Add(new DictionaryWarning(
                $"This rewrites “{trigger}” to itself, so it will never change anything."));
        }

        return warnings;
    }

    /// <summary>Warns when an entry can only ever be matched literally.</summary>
    /// <param name="entry">The entry to inspect.</param>
    /// <returns>One warning, or empty when the entry can be sound-matched.</returns>
    /// <remarks>
    /// Sound-matching is what lets one entry cover every way an engine can fumble a name. A
    /// phrase that sounds like ordinary speech can't have it — rewriting everything that sounds
    /// like "Ayen" also rewrites "I am" and "is on" — and the entry would otherwise sit there
    /// looking like it worked. Telling the user costs a line; letting them find out costs trust.
    /// </remarks>
    public static IReadOnlyList<DictionaryWarning> CheckSoundMatching(DictionaryEntry entry)
    {
        var phrase = (entry.Kind == EntryKind.Term ? entry.Write : entry.Hear).Trim();
        if (phrase.Length == 0 || PhoneticKey.IsDistinctive(phrase)) return [];

        var advice = entry.Kind == EntryKind.Term
            ? $"Add a correction — when you hear X, write “{phrase}” — for each way it comes out wrong."
            : "It will still be corrected exactly as written.";

        return
        [
            new DictionaryWarning(
                $"“{phrase}” sounds like ordinary speech, so it can only be matched "
                + "letter for letter, not by sound. " + advice),
        ];
    }
}
