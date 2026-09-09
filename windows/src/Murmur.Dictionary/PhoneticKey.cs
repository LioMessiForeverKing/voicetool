using System.Globalization;
using System.Text;

namespace Murmur.Dictionary;

/// <summary>
/// A coarse code for how a word or phrase <i>sounds</i>, so the dictionary can catch
/// mishearings nobody typed out in advance.
/// </summary>
/// <remarks>
/// <para>
/// A direct counterpart to <c>PhoneticKey.swift</c>. The two are independent implementations
/// of one contract, and <c>shared/dictionary-test-vectors.json</c> is what stops them
/// drifting. <b>Change the semantics there first.</b>
/// </para>
/// <para>
/// The algorithm is NYSIIS, picked because it was built for surnames and this dictionary is
/// mostly names. Three departures from the published version, all load-bearing:
/// </para>
/// <list type="bullet">
/// <item><b>No truncation.</b> Classic NYSIIS cuts the code to six characters, collapsing
/// "Kubernetes" and "Kubernetic". Long product names are what this has to keep apart.</item>
/// <item><b>A soft C codes as S.</b> NYSIIS keeps C verbatim, which puts "Vercel" and
/// "Versell" in different buckets — exactly the confusion an engine makes.</item>
/// <item><b>A leading vowel folds to A.</b> An engine that mishears a name almost never gets
/// its first vowel right, and NYSIIS otherwise keys the first letter verbatim.</item>
/// </list>
/// <para>
/// The trailing-S, trailing-AY and trailing-A rules are dropped. They exist to make surname
/// variants collide, and collide is what they did: with them, "Ian is" coded the same as
/// "Ian" and the correction pass ate the following word.
/// </para>
/// </remarks>
public static class PhoneticKey
{
    private const string Vowels = "AEIOU";

    private static readonly (string Prefix, string Replacement)[] Prefixes =
        [("MAC", "MCC"), ("KN", "NN"), ("K", "C"), ("PH", "FF"), ("PF", "FF"), ("SCH", "SSS")];

    private static readonly (string Suffix, string Replacement)[] Suffixes =
        [("EE", "Y"), ("IE", "Y"), ("DT", "D"), ("RT", "D"), ("RD", "D"), ("NT", "D"), ("ND", "D")];

    private static readonly Lazy<HashSet<string>> CommonSpanKeys = new(BuildCommonSpanKeys);

    /// <summary>Codes one word or phrase.</summary>
    /// <param name="text">Any text. Spaces and punctuation are dropped, so a phrase codes as
    /// if it were run together — the point, since "and thropic" and "Anthropic" are one sound.</param>
    /// <returns>The phonetic code, or an empty string if <paramref name="text"/> has no letters.</returns>
    public static string Encode(string text)
    {
        var normalized = text.Normalize(NormalizationForm.FormC).ToUpperInvariant();
        var letters = new string(normalized.Where(char.IsLetter).ToArray());
        if (letters.Length == 0) return string.Empty;

        var body = letters;
        foreach (var (prefix, replacement) in Prefixes)
        {
            if (!body.StartsWith(prefix, StringComparison.Ordinal)) continue;
            body = replacement + body[prefix.Length..];
            break;
        }

        foreach (var (suffix, replacement) in Suffixes)
        {
            if (!body.EndsWith(suffix, StringComparison.Ordinal)) continue;
            body = body[..^suffix.Length] + replacement;
            break;
        }

        var key = new StringBuilder();
        key.Append(body[0]);

        var index = 1;
        while (index < body.Length)
        {
            var (piece, consumed) = Translate(body, index, key);
            if (piece.Length > 0 && piece[^1] != key[^1]) key.Append(piece);
            index += consumed;
        }

        return Finish(key.ToString());
    }

    /// <summary>
    /// Whether <paramref name="text"/> is distinctive enough that matching it by sound is safe.
    /// </summary>
    /// <remarks>
    /// The trap is a name that is also a sentence: "Ayen" sounds like "I am", "is on" and
    /// "a yen", so sound-matching it rewrites ordinary speech several times a paragraph. The
    /// only honest test is to look, so this checks the code against every one- and two-word
    /// span the common words can form.
    /// </remarks>
    public static bool IsDistinctive(string text)
    {
        var key = Encode(text);
        return key.Length > 1 && !CommonSpanKeys.Value.Contains(key);
    }

    /// <summary>
    /// Every code ordinary English can produce in one or two words. Built once per process:
    /// the word list is a constant, and the corrector is rebuilt on every dictation.
    /// </summary>
    private static HashSet<string> BuildCommonSpanKeys()
    {
        var words = CommonWords.All.ToArray();
        var keys = new HashSet<string>(StringComparer.Ordinal);

        foreach (var first in words)
        {
            keys.Add(Encode(first));
            foreach (var second in words) keys.Add(Encode(first + second));
        }

        return keys;
    }

    /// <summary>Codes the character at <paramref name="index"/>, and says how many it used.</summary>
    private static (string Piece, int Consumed) Translate(string body, int index, StringBuilder key)
    {
        var c = body[index];

        if (Matches(body, index, "EV")) return ("AF", 2);
        if (IsVowel(c)) return ("A", 1);
        if (c == 'C' && index + 1 < body.Length && "EIY".IndexOf(body[index + 1]) >= 0) return ("S", 1);
        if (c == 'Q') return ("G", 1);
        if (c == 'Z') return ("S", 1);
        if (c == 'M') return ("N", 1);
        if (Matches(body, index, "KN")) return ("N", 2);
        if (c == 'K') return ("C", 1);
        if (Matches(body, index, "SCH")) return ("SSS", 3);
        if (Matches(body, index, "PH")) return ("FF", 2);

        var previousIsVowel = IsVowel(body[index - 1]);
        var nextIsConsonant = index + 1 < body.Length && !IsVowel(body[index + 1]);

        if (c == 'H' && (!previousIsVowel || nextIsConsonant))
        {
            return (key[^1].ToString(CultureInfo.InvariantCulture), 1);
        }

        if (c == 'W' && previousIsVowel) return (key[^1].ToString(CultureInfo.InvariantCulture), 1);

        return (c.ToString(CultureInfo.InvariantCulture), 1);
    }

    private static bool IsVowel(char c) => Vowels.IndexOf(c) >= 0;

    private static bool Matches(string body, int index, string pattern) =>
        index + pattern.Length <= body.Length
        && string.CompareOrdinal(body, index, pattern, 0, pattern.Length) == 0;

    private static string Finish(string code) => IsVowel(code[0]) ? "A" + code[1..] : code;
}
