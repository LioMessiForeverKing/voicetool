/// What a fresh install has to get through before Murmur does anything at all.
///
/// Split out like the dictionary and the gesture: the decision of which step is current, and
/// whether to open the window in the first place, is the part worth testing, and the app
/// target cannot be unit tested. Nothing here touches AppKit, TCC or the filesystem — the
/// caller reads those and hands the answers in.
public enum OnboardingStep: String, CaseIterable, Sendable {
    /// The `CGEventTap` behind the hotkey and the AX insert. No programmatic request exists.
    case accessibility
    /// Audio capture. The only grant the app can ask for directly.
    case microphone
    /// Hold the key, say something, watch it land. A permission that is granted but never
    /// exercised is not the same as a working install.
    case practice
}

/// How a step reads on the panel.
public enum OnboardingStepState: Sendable, Equatable {
    case done
    case current
    case waiting
}

/// What the app has observed about the install, at one moment.
public struct OnboardingProgress: Equatable, Sendable {
    /// Accessibility is granted **and** this process actually holds its event tap.
    ///
    /// Deliberately not just the TCC answer. macOS will report the app trusted while this
    /// copy of it has no tap, and a step that called that done would light a lamp and then
    /// send the user on to hold a key that cannot fire.
    public var hasArmedHotkey: Bool
    public var hasMicrophone: Bool
    /// Murmur has produced at least one transcription. Deliberately "ever", not "since this
    /// window opened", so the same meaning drives the launch decision and the panel.
    public var hasDictated: Bool

    public init(hasArmedHotkey: Bool, hasMicrophone: Bool, hasDictated: Bool) {
        self.hasArmedHotkey = hasArmedHotkey
        self.hasMicrophone = hasMicrophone
        self.hasDictated = hasDictated
    }

    public func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .accessibility: hasArmedHotkey
        case .microphone: hasMicrophone
        case .practice: hasDictated
        }
    }

    public var isComplete: Bool {
        OnboardingStep.allCases.allSatisfy(isSatisfied)
    }

    /// The step the panel should be asking for. `nil` once there is nothing left to ask.
    public var current: OnboardingStep? {
        OnboardingStep.allCases.first { !isSatisfied($0) }
    }

    /// A step granted out of order still reads as done. macOS will have prompted for the
    /// microphone during any earlier dictation attempt, so that is the ordinary case rather
    /// than an edge one, and showing it as pending would be a lie about the machine.
    public func state(of step: OnboardingStep) -> OnboardingStepState {
        if isSatisfied(step) { return .done }
        return step == current ? .current : .waiting
    }
}
