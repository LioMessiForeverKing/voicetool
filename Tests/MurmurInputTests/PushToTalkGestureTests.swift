import Foundation
import Testing

@testable import MurmurInput

/// The gesture carries two behaviours on one key, and the two must not interfere.
///
/// These exist because the timing is genuinely unverifiable by hand: nobody can reliably tap
/// twice inside 350ms, or hold for exactly 249ms, on demand and repeatedly. Every case here
/// hands in explicit timestamps instead.
@MainActor
struct PushToTalkGestureTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    /// A hold longer than `tapThreshold`.
    private let held = PushToTalkGesture.tapThreshold + 0.2
    /// A press short enough to read as a tap.
    private let tapped = PushToTalkGesture.tapThreshold - 0.05

    // MARK: - Hold, unchanged

    @Test("Holding starts on press and stops the instant the key is released")
    func holdStopsImmediately() {
        let gesture = PushToTalkGesture()
        #expect(gesture.press(at: at(0)) == .begin)
        // A real hold never waits for a second tap, so release latency is unchanged.
        #expect(gesture.release(at: at(held)) == .end)
        #expect(!gesture.isLatched)
    }

    @Test("A hold leaves no state behind")
    func holdIsRepeatable() {
        let gesture = PushToTalkGesture()
        for round in 0..<3 {
            let base = Double(round) * 10
            #expect(gesture.press(at: at(base)) == .begin)
            #expect(gesture.release(at: at(base + held)) == .end)
        }
    }

    // MARK: - Double-tap to latch

    @Test("Two quick taps latch, and the recording is never stopped in between")
    func doubleTapLatches() {
        let gesture = PushToTalkGesture()
        #expect(gesture.press(at: at(0)) == .begin)
        // Not `.end`: stopping here would discard the first tap's audio and split the take.
        #expect(gesture.release(at: at(tapped)) == .armTapTimer)
        #expect(gesture.press(at: at(tapped + 0.1)) == .latch)
        #expect(gesture.isLatched)
    }

    @Test("Releasing the key while latched keeps recording")
    func latchSurvivesRelease() {
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        _ = gesture.release(at: at(tapped))
        _ = gesture.press(at: at(tapped + 0.1))
        #expect(gesture.release(at: at(tapped + 0.2)) == .none)
        #expect(gesture.isLatched)
    }

    @Test("A single tap while latched stops it")
    func tapWhileLatchedStops() {
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        _ = gesture.release(at: at(tapped))
        _ = gesture.press(at: at(tapped + 0.1))
        _ = gesture.release(at: at(tapped + 0.2))

        #expect(gesture.press(at: at(30)) == .end)
        #expect(!gesture.isLatched)
        #expect(gesture.release(at: at(30.05)) == .none)
        #expect(gesture.press(at: at(31)) == .begin)
    }

    @Test("A lone tap just stops when the window closes")
    func singleTapEndsOnTimer() {
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        #expect(gesture.release(at: at(tapped)) == .armTapTimer)
        #expect(gesture.tapTimerFired() == .end)
        #expect(!gesture.isLatched)
    }

    @Test("The timer is inert once a second tap has latched")
    func timerAfterLatchDoesNothing() {
        // The armed stop must not fire underneath a latched recording, even late.
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        _ = gesture.release(at: at(tapped))
        _ = gesture.press(at: at(tapped + 0.1))
        #expect(gesture.tapTimerFired() == .none)
        #expect(gesture.isLatched)
    }

    // MARK: - Boundaries

    @Test("A press exactly at the threshold is a hold, not a tap")
    func thresholdIsAHold() {
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        #expect(gesture.release(at: at(PushToTalkGesture.tapThreshold)) == .end)
    }

    @Test("With latching off, a tap stops immediately like any other release")
    func latchingCanBeDisabled() {
        let gesture = PushToTalkGesture()
        gesture.isLatchEnabled = false
        #expect(gesture.press(at: at(0)) == .begin)
        #expect(gesture.release(at: at(tapped)) == .end)
        #expect(!gesture.isLatched)
    }

    // MARK: - Robustness

    @Test("A repeated press without a release is ignored")
    func duplicatePressIsIgnored() {
        let gesture = PushToTalkGesture()
        #expect(gesture.press(at: at(0)) == .begin)
        #expect(gesture.press(at: at(0.1)) == .none)
    }

    @Test("A release with no press does nothing")
    func strayReleaseIsIgnored() {
        // Happens for real: hold the key, then activate the tap — the press was never seen.
        let gesture = PushToTalkGesture()
        #expect(gesture.release(at: at(0)) == .none)
        #expect(gesture.tapTimerFired() == .none)
    }

    @Test("Reset clears a latch")
    func resetClearsLatch() {
        // Stopping from the button while latched must not leave the gesture believing it records.
        let gesture = PushToTalkGesture()
        _ = gesture.press(at: at(0))
        _ = gesture.release(at: at(tapped))
        _ = gesture.press(at: at(tapped + 0.1))
        #expect(gesture.isLatched)

        gesture.reset()
        #expect(!gesture.isLatched)
        #expect(gesture.press(at: at(10)) == .begin)
    }
}
