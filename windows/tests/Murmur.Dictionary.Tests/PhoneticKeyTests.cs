using Murmur.Dictionary;
using Shouldly;
using Xunit;

namespace Murmur.DictionaryTests;

/// <summary>
/// The phonetic code itself, separately from the correction pass that uses it.
/// </summary>
/// <remarks>
/// A direct counterpart to <c>PhoneticKeyTests.swift</c>. The Swift implementation must
/// produce identical codes for every string here; these values are as contractual as the
/// shared vectors, and are the first place to look when the platforms disagree.
/// </remarks>
public sealed class PhoneticKeyTests
{
    [Theory]
    [InlineData("Anthropic", "Anthropik")]
    [InlineData("Vercel", "Versell")]
    [InlineData("Vercel", "ver sell")]
    [InlineData("Kubernetes", "coobernetties")]
    [InlineData("Supabase", "Soopabase")]
    public void Names_an_engine_confuses_share_one_code(string name, string mishearing) =>
        PhoneticKey.Encode(name).ShouldBe(PhoneticKey.Encode(mishearing));

    [Theory]
    [InlineData("Anthropic", "Vercel")]
    [InlineData("Claude", "cloud")]
    [InlineData("Supabase", "Drizzle")]
    public void Unrelated_names_keep_different_codes(string one, string other) =>
        PhoneticKey.Encode(one).ShouldNotBe(PhoneticKey.Encode(other));

    [Theory]
    [InlineData("Claude Code", "claude-code")]
    [InlineData("O'Brien", "obrien")]
    [InlineData("caf\u00e9", "cafe\u0301")]
    public void The_code_is_stable_against_case_spacing_punctuation_and_accents(
        string one, string other) =>
        PhoneticKey.Encode(one).ShouldBe(PhoneticKey.Encode(other));

    [Theory]
    [InlineData("")]
    [InlineData("123 — !")]
    public void Text_with_no_letters_has_no_code(string text) =>
        PhoneticKey.Encode(text).ShouldBeEmpty();

    [Theory]
    [InlineData("Ayen")]
    [InlineData("Iin")]
    [InlineData("Eyen")]
    public void A_leading_vowel_is_folded_because_engines_guess_it_wrong(string name) =>
        PhoneticKey.Encode(name).ShouldStartWith("A");

    [Fact]
    public void The_code_is_not_truncated_so_long_names_stay_apart()
    {
        PhoneticKey.Encode("Kubernetes").Length.ShouldBeGreaterThan(6);
        PhoneticKey.Encode("Kubernetes").ShouldNotBe(PhoneticKey.Encode("Kubernetical"));
    }

    [Theory]
    [InlineData("Ian", "Ian is")]
    [InlineData("Vercel", "Vercel is")]
    public void A_trailing_word_is_not_swallowed_by_the_one_before_it(string name, string span) =>
        PhoneticKey.Encode(name).ShouldNotBe(PhoneticKey.Encode(span));

    [Theory]
    [InlineData("Ayen")]
    [InlineData("Ian")]
    [InlineData("Sonnet")]
    [InlineData("Notion")]
    [InlineData("")]
    public void Names_that_sound_like_ordinary_speech_are_refused(string name) =>
        PhoneticKey.IsDistinctive(name).ShouldBeFalse();

    [Theory]
    [InlineData("Anthropic")]
    [InlineData("Vercel")]
    [InlineData("Supabase")]
    [InlineData("Kubernetes")]
    [InlineData("Claude Code")]
    public void Distinctive_names_are_allowed_to_sound_match(string name) =>
        PhoneticKey.IsDistinctive(name).ShouldBeTrue();

    [Fact]
    public void A_term_that_sounds_ordinary_is_warned_about()
    {
        DictionaryWarning.CheckSoundMatching(DictionaryEntry.Term("Ayen")).ShouldNotBeEmpty();
        DictionaryWarning.CheckSoundMatching(DictionaryEntry.Term("Anthropic")).ShouldBeEmpty();
        DictionaryWarning.CheckSoundMatching(DictionaryEntry.Correction("I in", "Ayen"))
            .ShouldNotBeEmpty();
        DictionaryWarning.CheckSoundMatching(DictionaryEntry.Correction("anthropik", "Anthropic"))
            .ShouldBeEmpty();
    }
}
