import Foundation

/// A modifier key, identified by the *device-dependent* bit for that specific physical key.
///
/// Device-dependent because the public union masks can't tell left from right: hold Left ⌥,
/// tap Right ⌥, and with the union bit the release is invisible — the mic stays open and the
/// HUD never comes down. These raw values are IOKit's `NX_DEVICE*` masks, which carry the
/// distinction the public constants discard. `fn` is the exception: it has no left/right
/// variant, and its bit is the device-independent one.
///
/// Only modifiers, and that is a hard limit rather than an omission. Push-to-talk needs the
/// key going *down* and coming back *up*; a letter key can't be held for three seconds
/// without typing `ddddddd` into whatever has focus.
public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case fn
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    /// The device-dependent modifier bit for this key.
    ///
    /// Each value is the `NX_DEVICE<KEY>KEYMASK` constant of the same name from IOKit's
    /// `IOLLEvent.h`, which Swift does not import, so they are written out here. `fn` is the
    /// exception: it uses `kCGEventFlagMaskSecondaryFn`.
    public var mask: UInt64 {
        switch self {
        case .leftControl: 0x0000_0001
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        case .fn: 0x0080_0000
        }
    }

    public var displayName: String {
        switch self {
        case .fn: "fn"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        case .leftCommand: "Left ⌘"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Right-hand modifiers are the ones safe to take exclusive use of: nothing else is
    /// reaching for them, so swallowing the event costs the user nothing. A left-hand
    /// modifier is live in shortcuts they already use, and `fn` is load-bearing for
    /// fn+arrow, fn+delete and the emoji picker.
    public var isSafeToConsume: Bool {
        switch self {
        case .rightControl, .rightOption, .rightShift, .rightCommand: true
        case .fn, .leftControl, .leftOption, .leftShift, .leftCommand: false
        }
    }

    /// Display order, so a chord reads the same however it was pressed. Follows the order
    /// macOS prints shortcuts in.
    var rank: Int {
        switch self {
        case .fn: 0
        case .leftControl, .rightControl: 1
        case .leftOption, .rightOption: 2
        case .leftShift, .rightShift: 3
        case .leftCommand, .rightCommand: 4
        }
    }
}

/// The key or chord that starts dictation.
///
/// A set rather than a single key, so `fn+⌃` is expressible. Every modifier in the chord has
/// to be down for it to fire, and letting go of any one of them ends it.
public struct Hotkey: Equatable, Hashable, Sendable, Codable {
    /// Non-empty, de-duplicated, in canonical display order.
    public let modifiers: [ModifierKey]

    /// - Returns: nil for an empty chord. A hotkey that matches nothing would fire on every
    ///   `flagsChanged` event, so it is made unrepresentable rather than guarded against.
    public init?(_ modifiers: [ModifierKey]) {
        var seen = Set<ModifierKey>()
        let unique = modifiers.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        self.modifiers = unique.sorted { ($0.rank, $0.rawValue) < ($1.rank, $1.rawValue) }
    }

    public var mask: UInt64 {
        modifiers.reduce(0) { $0 | $1.mask }
    }

    /// "fn", "Right ⌥", "fn + Right ⌃".
    public var displayName: String {
        modifiers.map(\.displayName).joined(separator: " + ")
    }

    /// Whether the event should be swallowed rather than passed to the rest of the system.
    ///
    /// Only when *every* key in the chord is safe to take. One `fn` or left-hand modifier in
    /// the chord and the whole thing passes through — the cost of not consuming is that the
    /// modifier also does its normal job, which is nothing for a bare press; the cost of
    /// wrongly consuming is a modifier that silently stops working everywhere else.
    public var shouldConsumeEvent: Bool {
        modifiers.allSatisfy(\.isSafeToConsume)
    }

    /// Whether the chord is fully held, given a raw `CGEventFlags`/`NSEvent` modifier value.
    ///
    /// Deliberately permissive about *extra* modifiers: holding Right ⌥ while Shift happens
    /// to be down still counts. Requiring an exact match would make the hotkey fail in the
    /// middle of ordinary typing for no benefit.
    public func isSatisfied(by flags: UInt64) -> Bool {
        let required = mask
        return required != 0 && flags & required == required
    }

    /// The modifiers currently held in `flags`.
    public static func modifiers(in flags: UInt64) -> [ModifierKey] {
        ModifierKey.allCases.filter { flags & $0.mask == $0.mask }
    }

    // MARK: - Storage

    /// Round-trips through `UserDefaults` as a plain string: "fn", "fn+rightControl".
    public var storageValue: String {
        modifiers.map(\.rawValue).joined(separator: "+")
    }

    /// Also accepts a bare single key, which is what the three-preset version of this
    /// setting wrote. An existing preference therefore survives the upgrade rather than
    /// silently reverting to the default.
    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "+").map(String.init)
        let keys = parts.compactMap(ModifierKey.init(rawValue:))
        guard keys.count == parts.count else { return nil }
        self.init(keys)
    }

    // MARK: - Defaults

    /// fn. The one candidate not already spoken for: Right ⌥ is AltGr on German, Polish, UK
    /// and most Latin-American layouts, and Right ⌘ is live in shortcuts people already have
    /// muscle memory for.
    public static let `default` = Hotkey([.fn])!

    /// Offered as one-click choices; anything else is set by recording it.
    public static let presets: [Hotkey] = [
        Hotkey([.fn])!,
        Hotkey([.rightOption])!,
        Hotkey([.rightCommand])!,
        Hotkey([.rightControl])!,
    ]
}
