import Foundation
import Testing

@testable import MurmurDictionary

/// The phonetic code itself, separately from the correction pass that uses it.
///
/// The Windows implementation must produce identical codes for every string here; these
/// values are as contractual as the shared vectors, and are the first place to look when the
/// two platforms disagree about a correction.
struct PhoneticKeyTests {
    @Test("names an engine confuses share one code")
    func mishearingsCollapse() {
        #expect(PhoneticKey.encode("Anthropic") == PhoneticKey.encode("Anthropik"))
        #expect(PhoneticKey.encode("Vercel") == PhoneticKey.encode("Versell"))
        #expect(PhoneticKey.encode("Vercel") == PhoneticKey.encode("ver sell"))
        #expect(PhoneticKey.encode("Kubernetes") == PhoneticKey.encode("coobernetties"))
        #expect(PhoneticKey.encode("Supabase") == PhoneticKey.encode("Soopabase"))
    }

    @Test("unrelated names keep different codes")
    func distinctNamesStayApart() {
        #expect(PhoneticKey.encode("Anthropic") != PhoneticKey.encode("Vercel"))
        #expect(PhoneticKey.encode("Claude") != PhoneticKey.encode("cloud"))
        #expect(PhoneticKey.encode("Supabase") != PhoneticKey.encode("Drizzle"))
    }

    @Test("the code is stable against case, spacing, punctuation and accents")
    func normalisation() {
        #expect(PhoneticKey.encode("Claude Code") == PhoneticKey.encode("claude-code"))
        #expect(PhoneticKey.encode("O'Brien") == PhoneticKey.encode("obrien"))
        #expect(PhoneticKey.encode("café") == PhoneticKey.encode("cafe\u{0301}"))
    }

    @Test("text with no letters has no code")
    func emptyInput() {
        #expect(PhoneticKey.encode("") == "")
        #expect(PhoneticKey.encode("123 — !") == "")
    }

    @Test("a leading vowel is folded, because engines guess it wrong")
    func leadingVowelFolds() {
        #expect(PhoneticKey.encode("Ayen").hasPrefix("A"))
        #expect(PhoneticKey.encode("Iin").hasPrefix("A"))
        #expect(PhoneticKey.encode("Eyen").hasPrefix("A"))
    }

    @Test("the code is not truncated, so long names stay apart")
    func noTruncation() {
        #expect(PhoneticKey.encode("Kubernetes").count > 6)
        #expect(PhoneticKey.encode("Kubernetes") != PhoneticKey.encode("Kubernetical"))
    }

    @Test("a trailing word is not swallowed by the one before it")
    func adjacentWordsDoNotCollapse() {
        #expect(PhoneticKey.encode("Ian") != PhoneticKey.encode("Ian is"))
        #expect(PhoneticKey.encode("Vercel") != PhoneticKey.encode("Vercel is"))
    }

    @Test("names that sound like ordinary speech are refused")
    func ordinarySpeechIsRefused() {
        #expect(PhoneticKey.isDistinctive("Ayen") == false)
        #expect(PhoneticKey.isDistinctive("Ian") == false)
        #expect(PhoneticKey.isDistinctive("Sonnet") == false)
        #expect(PhoneticKey.isDistinctive("Notion") == false)
        #expect(PhoneticKey.isDistinctive("") == false)
    }

    @Test("distinctive names are allowed to sound-match")
    func distinctiveNamesAreAllowed() {
        #expect(PhoneticKey.isDistinctive("Anthropic"))
        #expect(PhoneticKey.isDistinctive("Vercel"))
        #expect(PhoneticKey.isDistinctive("Supabase"))
        #expect(PhoneticKey.isDistinctive("Kubernetes"))
        #expect(PhoneticKey.isDistinctive("Claude Code"))
    }

    @Test("a term that sounds ordinary is warned about, a distinctive one is not")
    func warnsWhenSoundMatchingIsRefused() {
        #expect(DictionaryWarning.checkSoundMatching(.term("Ayen")).isEmpty == false)
        #expect(DictionaryWarning.checkSoundMatching(.term("Anthropic")).isEmpty)
        #expect(
            DictionaryWarning.checkSoundMatching(.correction(hear: "I in", write: "Ayen")).isEmpty
                == false
        )
        #expect(
            DictionaryWarning.checkSoundMatching(
                .correction(hear: "anthropik", write: "Anthropic")
            ).isEmpty
        )
    }
}
