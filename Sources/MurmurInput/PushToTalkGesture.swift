import Foundation

/// Turns raw press/release of the push-to-talk key into dictation commands, so that one key
/// carries two gestures:
///
/// - **Hold** — record while held, stop on release. The original behaviour.
/// - **Double-tap** — latch, and keep recording with the key released. Tap once more to stop.
///
/// The hard requirement is that adding the second gesture must not slow down the first.
/// Release-to-text is the latency the user actually feels, and the obvious implementation —
/// wait a moment on every release to see whether a second tap is coming — would put the
/// double-tap window onto the end of every single dictation.
///
/// So the wait is only ever armed after a *tap*: a press shorter than `tapThreshold`. A real
/// hold is longer than that by definition, so it stops the instant the key comes up, exactly
/// as before. The only gesture that pays the wait is one that recorded a few hundred
/// milliseconds of audio and was never going to be worth transcribing anyway.
///
/// Pure and clock-injected: every decision is a function of the timestamps handed in, so the
/// behaviour can be reasoned about without a keyboard or a running event tap.
@MainActor
public final class PushToTalkGesture {
    /// A press shorter than this is a tap, not a hold.
    ///
    /// Generous rather than tight. Being wrong in the "that was a tap" direction costs a
    /// short wait on a recording that captured almost nothing; being wrong the other way
    /// makes a deliberate double-tap silently behave as two clipped recordings.
    public static let tapThreshold: TimeInterval = 0.25

    /// How long after a tap a second tap still counts as a double-tap.
    public static let doubleTapWindow: TimeInterval = 0.35

    /// What the caller should do about it.
    public enum Action: Equatable {
        /// Start recording.
        case begin
        /// Stop recording and transcribe.
        case end
        /// Keep recording with the key released. The caller cancels any armed tap timer.
        case latch
        /// Recording is running but undecided: call `tapTimerFired()` after
        /// `doubleTapWindow` unless something else happens first.
        case armTapTimer
        /// Nothing to do.
        case none
    }

    private enum State: Equatable {
        case idle
        /// Key is down; recording. Carries when it went down, to classify the release.
        case holding(since: Date)
        /// Key came up after a tap. Still recording, waiting to see if a second tap lands.
        case awaitingSecondTap
        /// Recording hands-free. The key is not held.
        case latched
    }

    private var state: State = .idle

    public init() {}

    /// Whether recording is currently hands-free. Drives the HUD's lock indicator — without
    /// it there is no way to tell a latched recording from a held one, and the user can't
    /// know whether letting go will stop it.
    public var isLatched: Bool { state == .latched }

    /// Set false to disable the double-tap gesture entirely; hold-to-talk is unaffected.
    public var isLatchEnabled = true

    public func press(at now: Date = .now) -> Action {
        switch state {
        case .idle:
            state = .holding(since: now)
            return .begin

        case .awaitingSecondTap:
            // Second tap of a double-tap. The recording started by the first tap simply
            // continues — this deliberately does not stop and restart, so a double-tap
            // yields one continuous take rather than a discarded stub plus a new recording.
            state = .latched
            return .latch

        case .latched:
            state = .idle
            return .end

        case .holding:
            // No matching release seen. Physically shouldn't happen; ignoring it is safer
            // than restarting a recording that is already running.
            return .none
        }
    }

    public func release(at now: Date = .now) -> Action {
        switch state {
        case .holding(let since):
            if !isLatchEnabled || now.timeIntervalSince(since) >= Self.tapThreshold {
                state = .idle
                return .end
            }
            state = .awaitingSecondTap
            return .armTapTimer

        case .latched:
            return .none

        case .idle, .awaitingSecondTap:
            return .none
        }
    }

    /// Called by the owner once `doubleTapWindow` has elapsed with no second tap.
    public func tapTimerFired() -> Action {
        guard state == .awaitingSecondTap else { return .none }
        state = .idle
        return .end
    }

    /// Drops all gesture state — for deactivation, or a recording cancelled from elsewhere.
    public func reset() {
        state = .idle
    }
}
