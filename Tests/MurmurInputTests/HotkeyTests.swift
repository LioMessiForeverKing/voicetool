import Foundation
import Testing

@testable import MurmurInput

/// The hotkey is matched against raw modifier bits on every `flagsChanged` event, system
/// wide. Getting it wrong doesn't produce a visible bug — it produces a mic that opens when
/// it shouldn't, or never opens at all.
struct HotkeyTests {
    /// Left ⌥, as the OS reports it — deliberately not the key under test, so it stands in
    /// for "some other modifier the user happens to be holding".
    private let otherModifier = ModifierKey.leftOption.mask

    // MARK: - Matching

    @Test("A single modifier fires when its own bit is set")
    func singleModifierMatches() {
        let hotkey = Hotkey([.rightOption])!
        #expect(hotkey.isSatisfied(by: ModifierKey.rightOption.mask))
        #expect(!hotkey.isSatisfied(by: 0))
    }

    @Test("Left and right of the same key are not interchangeable")
    func sidesAreDistinct() {
        // The whole reason for device-dependent masks. With the union mask, holding Left ⌥
        // and tapping Right ⌥ hides the release: the mic stays open with the HUD up.
        let hotkey = Hotkey([.rightOption])!
        #expect(!hotkey.isSatisfied(by: ModifierKey.leftOption.mask))
    }

    @Test("A chord needs every key held")
    func chordRequiresAll() {
        let hotkey = Hotkey([.fn, .rightControl])!
        #expect(hotkey.isSatisfied(by: ModifierKey.fn.mask | ModifierKey.rightControl.mask))
        #expect(!hotkey.isSatisfied(by: ModifierKey.fn.mask))
        #expect(!hotkey.isSatisfied(by: ModifierKey.rightControl.mask))
    }

    @Test("Unrelated modifiers held at the same time don't block it")
    func extraModifiersAreAllowed() {
        // Requiring an exact match would make the hotkey die mid-sentence the moment Shift
        // was held for a capital letter.
        let hotkey = Hotkey([.rightOption])!
        #expect(hotkey.isSatisfied(by: ModifierKey.rightOption.mask | otherModifier))
    }

    @Test("Letting go of one key of a chord ends it")
    func releasingOneKeyEndsChord() {
        let hotkey = Hotkey([.fn, .rightControl])!
        let both = ModifierKey.fn.mask | ModifierKey.rightControl.mask
        #expect(hotkey.isSatisfied(by: both))
        #expect(!hotkey.isSatisfied(by: both & ~ModifierKey.fn.mask))
    }

    @Test("Every modifier has a distinct bit")
    func masksAreUnique() {
        // A collision would make two different keys indistinguishable to the event tap.
        let masks = ModifierKey.allCases.map(\.mask)
        #expect(Set(masks).count == masks.count)
        #expect(!masks.contains(0))
    }

    // MARK: - Construction

    @Test("An empty chord is not representable")
    func emptyChordIsNil() {
        // A zero mask would satisfy `flags & 0 == 0` on every event, firing constantly.
        #expect(Hotkey([]) == nil)
    }

    @Test("Order of pressing doesn't change the hotkey")
    func canonicalOrdering() {
        let a = Hotkey([.rightControl, .fn])!
        let b = Hotkey([.fn, .rightControl])!
        #expect(a == b)
        #expect(a.displayName == "fn + Right ⌃")
    }

    @Test("A repeated key is collapsed")
    func duplicatesAreRemoved() {
        let hotkey = Hotkey([.fn, .fn])!
        #expect(hotkey.modifiers == [.fn])
    }

    // MARK: - Consuming

    @Test("Only all-right-hand chords are swallowed")
    func consumesOnlyDedicatedKeys() {
        #expect(Hotkey([.rightOption])!.shouldConsumeEvent)
        #expect(Hotkey([.rightOption, .rightCommand])!.shouldConsumeEvent)
        // fn is load-bearing for fn+arrow, fn+delete and the emoji picker.
        #expect(!Hotkey([.fn])!.shouldConsumeEvent)
        // A left-hand modifier is live in shortcuts the user already has.
        #expect(!Hotkey([.leftControl])!.shouldConsumeEvent)
        // One unsafe key taints the whole chord.
        #expect(!Hotkey([.fn, .rightControl])!.shouldConsumeEvent)
    }

    // MARK: - Storage

    @Test("A chord round-trips through storage")
    func storageRoundTrips() {
        let hotkey = Hotkey([.fn, .rightControl])!
        #expect(hotkey.storageValue == "fn+rightControl")
        #expect(Hotkey(storageValue: hotkey.storageValue) == hotkey)
    }

    @Test("A preference written by the three-preset version still loads")
    func legacyValuesMigrate() {
        // These are the exact strings the old `PushToTalkKey` enum persisted. Failing to
        // parse them would silently reset the user's key on upgrade.
        #expect(Hotkey(storageValue: "fn") == Hotkey([.fn]))
        #expect(Hotkey(storageValue: "rightOption") == Hotkey([.rightOption]))
        #expect(Hotkey(storageValue: "rightCommand") == Hotkey([.rightCommand]))
    }

    @Test("Junk in storage is rejected rather than half-parsed")
    func invalidStorageIsNil() {
        // Partial parsing is the danger: "fn+banana" must not quietly become plain fn.
        #expect(Hotkey(storageValue: "fn+banana") == nil)
        #expect(Hotkey(storageValue: "") == nil)
        #expect(Hotkey(storageValue: "+") == nil)
    }

    // MARK: - Reading held keys

    @Test("Held modifiers are read back out of a flags value")
    func modifiersInFlags() {
        let flags = ModifierKey.fn.mask | ModifierKey.rightShift.mask
        #expect(Set(Hotkey.modifiers(in: flags)) == [.fn, .rightShift])
        #expect(Hotkey.modifiers(in: 0).isEmpty)
    }

    @Test("The default is fn")
    func defaultIsFn() {
        #expect(Hotkey.default == Hotkey([.fn]))
        #expect(Hotkey.presets.contains(Hotkey.default))
    }
}
