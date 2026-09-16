import MurmurOnboarding
import AppKit
import SwiftUI

/// First-run setup — the card that ships in the box with the unit.
///
/// Three rows, one per thing that has to be true before dictation works, each lit when it
/// is. The microphone can be asked for from here, exactly once — after that the OS returns
/// the stored answer in silence. Accessibility can never be asked for at all. So for both,
/// the panel leans on the two things it can always do: put the user in front of the right
/// pane, and then *notice*, so nobody has to guess whether a toggle just took effect.
///
/// The lamps are ink, not green. Green and amber are instrumentation here, and red means
/// recording; state also reads in words beside every lamp, so nothing depends on colour.
struct OnboardingWindow: View {
    @Bindable var controller: DictationController

    @State private var settings = Settings.shared
    @State private var store = RunStore.shared
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasMicrophone = Permissions.hasMicrophone
    @State private var micRequests = 0

    @Environment(\.dismiss) private var dismiss

    private var progress: OnboardingProgress {
        OnboardingProgress(
            hasArmedHotkey: hasAccessibility && controller.isArmed,
            hasMicrophone: hasMicrophone,
            hasDictated: lastTypedRun != nil
        )
    }

    /// The newest run that was actually typed somewhere.
    ///
    /// Compare mode files one run per engine and injects none of them, so counting every
    /// row would light this step for someone Murmur has never typed a word for — which is
    /// the exact confusion the step exists to catch. A comparison carries a `group`; an
    /// ordinary dictation does not.
    private var lastTypedRun: DictationRun? {
        store.runs.last { $0.group == nil }
    }

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: DS.Space.base) {
                header

                Well {
                    VStack(spacing: DS.Space.snug) {
                        ForEach(OnboardingStep.allCases, id: \.self) { step in
                            row(for: step)
                        }
                    }
                    .padding(DS.Space.base)
                }

                footer
            }
            .padding(DS.Space.roomy)
        }
        .frame(minWidth: DS.Material.setupCardWidth, minHeight: DS.Material.setupCardHeight)
        .task { await pollPermissions() }
        .task(id: micRequests) { await requestMicrophone() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Silkscreen(text: "Set up", large: true)
                Text("Murmur types what you say into whatever has focus. macOS will not let it do that until you say so, twice.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.silkscreen)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DS.Space.snug) {
                Screw()
                Vents(count: 5)
            }
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
    }

    private func row(for step: OnboardingStep) -> some View {
        StepRow(
            step: step,
            state: progress.state(of: step),
            detail: detail(for: step),
            action: action(for: step)
        )
    }

    /// Never disabled. The card is opened on purpose and closing it is always allowed —
    /// the title is the only thing that changes with how far through it you are.
    private var footer: some View {
        HStack {
            Spacer()
            TransportKey(
                title: progress.isComplete ? "Done" : "Close",
                systemImage: progress.isComplete ? "checkmark" : nil
            ) {
                dismiss()
            }
        }
    }

    // MARK: - Copy

    private func detail(for step: OnboardingStep) -> String {
        switch step {
        case .accessibility:
            if !hasAccessibility {
                return "Lets Murmur see the push-to-talk key and insert text. Turn Murmur on in the list, then come back here."
            }
            return controller.isArmed
                ? "Granted, and the hotkey is armed."
                : "Granted, but this copy has no event tap yet. Quit Murmur and open it again."
        case .microphone:
            if hasMicrophone { return "Granted. Audio never leaves the machine." }
            if Permissions.microphoneIsRestricted {
                return "Withheld by a policy on this Mac. Murmur cannot ask for it, and System Settings cannot grant it."
            }
            return "Audio capture. macOS asks once; if it has already been answered, this opens the pane instead."
        case .practice:
            guard progress.hasArmedHotkey, hasMicrophone else {
                return "Unlocks once the hotkey is armed and the microphone is granted."
            }
            if let latest = lastTypedRun {
                return "Last dictation: \(latest.text)"
            }
            return "Click into any text field, hold \(settings.hotkey.displayName), and say something."
        }
    }

    private func action(for step: OnboardingStep) -> StepRow.Action? {
        switch step {
        case .accessibility:
            guard !hasAccessibility else { return nil }
            return .init(title: "Open Accessibility") { Permissions.openAccessibilitySettings() }
        case .microphone:
            guard !Permissions.microphoneIsRestricted else { return nil }
            return .init(title: "Allow Microphone") { micRequests += 1 }
        case .practice:
            return nil
        }
    }

    // MARK: - Behaviour

    /// No notification exists for either grant, so the panel asks. A second's latency is
    /// invisible next to the walk back from System Settings.
    private func pollPermissions() async {
        while !Task.isCancelled {
            hasAccessibility = Permissions.hasAccessibility
            hasMicrophone = Permissions.hasMicrophone
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The system prompt appears once per install. Once it has been answered, asking again
    /// returns the old answer silently — so a second press has to land in System Settings
    /// instead. Declining the prompt we just raised is not that case, and does not get
    /// a pane thrown at it.
    ///
    /// Structured, rather than a loose `Task`: the prompt outlives a closed window, and a
    /// System Settings pane opening after the card is gone has no visible cause.
    private func requestMicrophone() async {
        guard micRequests > 0 else { return }
        let wasDenied = Permissions.microphoneWasDenied
        let granted = await Permissions.requestMicrophone()
        guard !Task.isCancelled else { return }
        hasMicrophone = granted
        if !granted, wasDenied { Permissions.openMicrophoneSettings() }
    }
}

// MARK: - Step row

/// One step, in a readout window: lamp, name, status, what it is for, and the one control
/// that moves it along.
private struct StepRow: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let step: OnboardingStep
    let state: OnboardingStepState
    let detail: String
    let action: Action?

    private var title: String {
        switch step {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .practice: "Try it"
        }
    }

    /// A step with a control of its own is never "waiting" — it can be answered whenever
    /// the user reaches for it, whatever else is unfinished above it.
    private var status: String {
        switch state {
        case .done: step == .practice ? "Working" : "Granted"
        case .current: step == .practice ? "Your turn" : "Needed"
        case .waiting: action == nil ? "Waiting" : "Needed"
        }
    }

    /// Dimmed only when there is genuinely nothing to do here yet.
    private var isLocked: Bool { state == .waiting && action == nil }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Lamp(color: DS.Color.inkOnDeck, isLit: state == .done)
                .padding(.top, DS.Space.tight)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    Silkscreen(text: title, large: true, color: DS.Color.inkOnDeck)
                    Spacer()
                    Silkscreen(text: status, color: DS.Color.inkOnDeck.opacity(0.6))
                }

                Text(detail)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.75))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let action, state != .done {
                    TransportKey(title: action.title, action: action.perform)
                        .padding(.top, DS.Space.hair)
                }
            }
        }
        .padding(DS.Space.base)
        .background { DeckWindow { Color.clear } }
        .opacity(isLocked ? 0.55 : 1)
        .animation(DS.Motion.panel, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(status)
    }
}

// MARK: - Reopening

extension OnboardingWindow {
    static let windowID = "onboarding"
}

/// Opens the card. A view rather than a bare `Button` because `openWindow` is an environment
/// value, and a `Commands` builder has no environment of its own to read it from.
struct OpenOnboardingButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up Murmur…") {
            openWindow(id: OnboardingWindow.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
