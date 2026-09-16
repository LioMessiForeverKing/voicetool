import Testing

@testable import MurmurOnboarding

/// Which step the card is asking for, and how every other row reads while it asks.
///
/// The awkward case is a step granted out of order: macOS raises the microphone prompt on
/// any dictation attempt, so arriving with the microphone already granted and Accessibility
/// still missing is the ordinary path through a fresh install, not an edge of it.
struct OnboardingFlowTests {

    private func progress(
        armed: Bool = false,
        microphone: Bool = false,
        dictated: Bool = false
    ) -> OnboardingProgress {
        OnboardingProgress(
            hasArmedHotkey: armed,
            hasMicrophone: microphone,
            hasDictated: dictated
        )
    }

    @Test("A fresh install is asked for Accessibility first")
    func freshInstallStartsAtAccessibility() {
        #expect(progress().current == .accessibility)
    }

    @Test("Each grant advances to the next unmet step")
    func grantsAdvanceInOrder() {
        #expect(progress(armed: true).current == .microphone)
        #expect(progress(armed: true, microphone: true).current == .practice)
    }

    @Test("Nothing is current once every step is satisfied")
    func completeHasNoCurrentStep() {
        let done = progress(armed: true, microphone: true, dictated: true)
        #expect(done.current == nil)
        #expect(done.isComplete)
    }

    @Test("A step granted out of order reads as done, not pending")
    func laterGrantDoesNotBecomePending() {
        let mic = progress(microphone: true)
        #expect(mic.current == .accessibility)
        #expect(mic.state(of: .accessibility) == .current)
        #expect(mic.state(of: .microphone) == .done)
        #expect(mic.state(of: .practice) == .waiting)
    }

    @Test("An earlier grant missing does not let a later step become current")
    func currentIsTheFirstGap() {
        let dictatedOnly = progress(dictated: true)
        #expect(dictatedOnly.current == .accessibility)
        #expect(dictatedOnly.state(of: .practice) == .done)
        #expect(!dictatedOnly.isComplete)
    }

    @Test("Two of three is never complete")
    func partialIsNeverComplete() {
        #expect(!progress(armed: true, microphone: true).isComplete)
        #expect(!progress(armed: true, dictated: true).isComplete)
        #expect(!progress(microphone: true, dictated: true).isComplete)
    }
}
