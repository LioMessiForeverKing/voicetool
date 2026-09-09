using System.Text;
using System.Text.RegularExpressions;

namespace Murmur.Dictionary;

/// <summary>One correction that actually fired.</summary>
public sealed record AppliedCorrection(string From, string To, int Count);

/// <summary>
/// Rewrites transcribed text using the dictionary's correction pairs.
/// </summary>
/// <remarks>
/// <para>
/// This is the guaranteed half of the dictionary. Engine biasing is a nudge — it raises the
/// odds of the right word and promises nothing — so anything that must be correct is fixed
/// here, after the fact, deterministically.
/// </para>
/// <para>
/// A direct counterpart to <c>DictionaryCorrector.swift</c>. The two are independent
/// implementations of one contract, and <c>shared/dictionary-test-vectors.json</c> is what
/// stops them drifting. <b>Change the semantics there first.</b>
/// </para>
/// <para>Three rules, all load-bearing:</para>
/// <list type="number">
/// <item><b>Longest match first.</b> "Claude Code" is applied before "Claude", so the longer
/// rule isn't pre-empted by a shorter one that overlaps it.</item>
/// <item><b>Whole matches only.</b> Every pattern is fenced by word boundaries, so a rule for
/// "cloud code" can never touch "Cloudflare" or the ordinary word "cloud".</item>
/// <item><b>Glued words still match.</b> Engines run words together — "CloudCode",
/// "cloud-code" — so the gap between parts is matched as optional whitespace or hyphens.</item>
/// </list>
/// <para>
/// A second, phonetic pass then rewrites spans that merely <i>sound</i> like something the
/// dictionary knows, so one entry covers every way an engine can fumble a name.
/// </para>
/// </remarks>
public sealed class DictionaryCorrector
{
    /// <summary>
    /// Guards against a pathological dictionary hanging a dictation. Matching is linear here,
    /// so this should never trigger; it exists so that a bug can't wedge the app.
    /// </summary>
    private static readonly TimeSpan MatchTimeout = TimeSpan.FromSeconds(1);

    private static readonly char[] PhraseSeparators = [' ', '-', '\t'];

    private static readonly Regex WordPattern =
        new(@"[\p{L}\p{N}']+", RegexOptions.CultureInvariant, MatchTimeout);

    /// <summary>
    /// Longest span the phonetic pass will consider collapsing into one entry.
    /// </summary>
    /// <remarks>
    /// Three, because a mishearing splits a name into more words than it started with —
    /// "Anthropic" arrives as "and thropic" — but past three the window starts swallowing
    /// ordinary sentences whole.
    /// </remarks>
    public const int MaxSpanWords = 3;

    private readonly List<Rule> _rules;
    private readonly Dictionary<string, string> _phonetics;

    private sealed record Rule(Regex Regex, string Replacement, string Trigger);

    /// <summary>Compiles the enabled correction entries into an ordered rule set.</summary>
    /// <param name="entries">The dictionary. Terms and disabled entries are ignored here.</param>
    public DictionaryCorrector(IEnumerable<DictionaryEntry> entries)
    {
        // Longest trigger first; the stable sort keeps parity with Swift. See AGENTS.md.
        _rules = entries
            .Where(e => e.IsEnabled && e.Kind == EntryKind.Correction)
            .Where(e => !string.IsNullOrWhiteSpace(e.Hear))
            .OrderByDescending(e => e.Hear.Length)
            .Select(e => MakeRule(e.Hear, e.Write))
            .OfType<Rule>()
            .ToList();

        _phonetics = MakePhonetics(entries);
    }

    /// <summary>True when no enabled entry produced a literal rule or a sound-alike code.</summary>
    public bool IsEmpty => _rules.Count == 0 && _phonetics.Count == 0;

    /// <summary>Applies every rule in order.</summary>
    /// <param name="text">Raw transcribed text.</param>
    /// <returns>The rewritten text, plus one entry per rule that fired.</returns>
    public (string Text, IReadOnlyList<AppliedCorrection> Applied) Apply(string text)
    {
        if (IsEmpty || string.IsNullOrEmpty(text)) return (text, []);

        // NFC before matching, exactly as the Swift side does. See AGENTS.md.
        var result = text.Normalize(NormalizationForm.FormC);
        var applied = new List<AppliedCorrection>();

        foreach (var rule in _rules)
        {
            var matches = rule.Regex.Matches(result);
            if (matches.Count == 0) continue;

            var heard = matches[0].Value;

            // MatchEvaluator keeps the replacement literal. See AGENTS.md.
            result = rule.Regex.Replace(result, _ => rule.Replacement);

            Record(applied, heard, rule.Replacement, matches.Count);
        }

        result = ApplyPhonetics(result, applied);

        return (result, applied);
    }

    /// <summary>
    /// The sound-alike index: phonetic code to the text that should be written instead.
    /// </summary>
    /// <remarks>
    /// An entry earns a place only if <see cref="PhoneticKey.IsDistinctive"/> clears the phrase
    /// it would match on — the word itself for a term, the trigger for a correction. Naming a
    /// trigger yourself is not enough to make it safe: a rule reading "I in" to "Ayen" also
    /// rewrites "I am", because those are the same sound. A rejected entry keeps its literal
    /// rule and loses only the sound-alike family.
    /// <para>First entry in file order wins a contested code, so the result is stable.</para>
    /// </remarks>
    private static Dictionary<string, string> MakePhonetics(IEnumerable<DictionaryEntry> entries)
    {
        var index = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (var entry in entries.Where(e => e.IsEnabled))
        {
            var write = entry.Write.Trim();
            if (write.Length == 0) continue;

            var source = entry.Kind == EntryKind.Term ? write : entry.Hear.Trim();
            if (source.Length == 0 || !PhoneticKey.IsDistinctive(source)) continue;

            var key = PhoneticKey.Encode(source);
            if (!index.ContainsKey(key)) index[key] = write;
        }

        return index;
    }

    /// <summary>Rewrites every span that sounds like something in the index.</summary>
    /// <remarks>
    /// Longest span wins and spans never overlap, so a three-word match consumes its words and
    /// the scan resumes after them rather than re-matching a sub-span.
    /// </remarks>
    private string ApplyPhonetics(string text, List<AppliedCorrection> applied)
    {
        if (_phonetics.Count == 0) return text;

        var words = WordPattern.Matches(text);
        if (words.Count == 0) return text;

        var edits = new List<(int Start, int Length, string Heard, string Replacement)>();
        var start = 0;

        while (start < words.Count)
        {
            var span = Math.Min(MaxSpanWords, words.Count - start);
            var matched = false;

            while (span >= 1)
            {
                if (IsJoinable(words, start, span, text))
                {
                    var begin = words[start].Index;
                    var length = words[start + span - 1].Index + words[start + span - 1].Length - begin;
                    var heard = text[begin..(begin + length)];
                    var key = PhoneticKey.Encode(heard);

                    if (key.Length > 1
                        && _phonetics.TryGetValue(key, out var replacement)
                        && !string.Equals(heard, replacement, StringComparison.OrdinalIgnoreCase))
                    {
                        edits.Add((begin, length, heard, replacement));
                        start += span;
                        matched = true;
                        break;
                    }
                }

                span--;
            }

            if (!matched) start++;
        }

        if (edits.Count == 0) return text;

        var builder = new StringBuilder(text);
        for (var i = edits.Count - 1; i >= 0; i--)
        {
            builder.Remove(edits[i].Start, edits[i].Length).Insert(edits[i].Start, edits[i].Replacement);
        }

        foreach (var edit in edits) Record(applied, edit.Heard, edit.Replacement, 1);

        return builder.ToString();
    }

    /// <summary>
    /// Whether the words <c>start</c> to <c>start + count</c> are separated only by spaces or
    /// hyphens.
    /// </summary>
    /// <remarks>
    /// Punctuation between two words means they belong to different thoughts, and a span that
    /// reaches across a full stop would let the pass rewrite the seam between two sentences.
    /// </remarks>
    private static bool IsJoinable(MatchCollection words, int start, int count, string text)
    {
        for (var offset = 1; offset < count; offset++)
        {
            var previous = words[start + offset - 1];
            var gapStart = previous.Index + previous.Length;
            var gap = text.AsSpan(gapStart, words[start + offset].Index - gapStart);

            foreach (var c in gap)
            {
                if (!char.IsWhiteSpace(c) && c != '-') return false;
            }
        }

        return true;
    }

    /// <summary>Adds a correction, folding it into an existing record for the same replacement.</summary>
    /// <remarks>
    /// One record per replacement, because that is what the shared vectors contract promises
    /// and what history renders as a single badge.
    /// </remarks>
    private static void Record(List<AppliedCorrection> applied, string from, string to, int count)
    {
        var existing = applied.FindIndex(a => string.Equals(a.To, to, StringComparison.Ordinal));
        if (existing < 0)
        {
            applied.Add(new AppliedCorrection(from, to, count));
            return;
        }

        applied[existing] = applied[existing] with { Count = applied[existing].Count + count };
    }

    /// <summary>Builds the pattern for one trigger phrase.</summary>
    /// <remarks>
    /// <para>
    /// Parts are joined with <c>[\s\-]*</c> — zero or more spaces or hyphens — which catches
    /// "CloudCode" and "Cloud-Code" alongside the spaced form.
    /// </para>
    /// <para>
    /// The fences are lookarounds on letters and digits rather than <c>\b</c>. <c>\b</c>
    /// treats a trailing hyphen or apostrophe as a boundary and would let a rule bite into a
    /// longer word; requiring that no letter or digit sits on either side is the stricter
    /// guarantee, and it's what keeps "cloud code" off "Cloudflare".
    /// </para>
    /// </remarks>
    private static Rule? MakeRule(string trigger, string replacement)
    {
        var parts = trigger
            .Normalize(NormalizationForm.FormC)
            .Trim()
            .Split(PhraseSeparators, StringSplitOptions.RemoveEmptyEntries)
            .Select(Regex.Escape)
            .ToArray();

        if (parts.Length == 0) return null;

        var body = string.Join(@"[\s\-]*", parts);
        var pattern = $@"(?<![\p{{L}}\p{{N}}]){body}(?![\p{{L}}\p{{N}}])";

        try
        {
            var regex = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, MatchTimeout);
            return new Rule(regex, replacement, trigger);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }


    /// <summary>
    /// How many phrases to hand the speech engine as context.
    /// </summary>
    /// <remarks>
    /// Deliberately small. These models drift when given a long context list — on quiet or
    /// ambiguous audio they start inventing text from the vocabulary they were primed with,
    /// which is a far worse failure than the misspelling it was meant to fix.
    /// </remarks>
    public const int BiasLimit = 40;

    /// <summary>
    /// The correct spellings — Term words and the <i>write</i> side of corrections — capped
    /// at <see cref="BiasLimit"/>, de-duplicated case-insensitively, in file order.
    /// </summary>
    public static IReadOnlyList<string> BiasPhrases(IEnumerable<DictionaryEntry> entries)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var phrases = new List<string>();

        foreach (var entry in entries.Where(e => e.IsEnabled))
        {
            var phrase = entry.Write.Trim();
            if (phrase.Length == 0 || !seen.Add(phrase)) continue;
            phrases.Add(phrase);
            if (phrases.Count == BiasLimit) break;
        }

        return phrases;
    }
}
