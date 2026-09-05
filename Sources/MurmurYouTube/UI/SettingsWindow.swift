import MurmurDictionary
import SwiftUI

/// Settings — hotkey and model, per the brief. Opens on ⌘, via the standard `Settings` scene,
/// so the system wires up the menu item and the shortcut.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DS.Space.wide) {
                panel(label: "Push to talk") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            TransportKey(
                                title: key.displayName,
                                isEngaged: settings.pushToTalkKey == key,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                            .background {
                                if settings.pushToTalkKey == key {
                                    RoundedRectangle(cornerRadius: DS.Radius.control)
                                        .fill(DS.Color.selection)
                                }
                            }
                        }
                    }
                    note("Hold this key anywhere to dictate. The window's Record button works "
                        + "regardless of what's focused.")
                }

                panel(label: "Model") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            TransportKey(
                                title: choice == .apple ? "Apple" : "Parakeet",
                                isEngaged: settings.engine == choice,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.engine = choice
                            }
                            .background {
                                if settings.engine == choice {
                                    RoundedRectangle(cornerRadius: DS.Radius.control)
                                        .fill(DS.Color.selection)
                                }
                            }
                        }
                    }
                    note(settings.engine == .apple
                        ? "Apple's on-device transcriber. Streams text while you speak; no download."
                        : "Parakeet on the Neural Engine. Resolves on release; ~470 MB model.")
                }

                panel(label: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Silkscreen(text: "Clean up transcripts")
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers, fixes spacing and punctuation. The dictionary's "
                        + "corrections run either way.")
                }

                panel(label: "Vocabulary") {
                    Toggle(isOn: $settings.learnVocabulary) {
                        Silkscreen(text: "Learn from history")
                    }
                    .toggleStyle(.switch)
                    note(vocabularyNote)
                }

                panel(label: "Startup") {
                    Toggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )) {
                        Silkscreen(text: "Open at login")
                    }
                    .toggleStyle(.switch)
                    // `problem` wins when set: an unexplained switch that won't stay on is
                    // the failure this panel exists to make visible.
                    note(launchAtLogin.problem
                        ?? "Starts Murmur YouTube when you log in, so push to talk is armed "
                        + "without opening the app first.")
                }

                Spacer()
            }
            .padding(DS.Space.panel)
        }
        .frame(width: 520, height: 660)
    }

    /// Reports the *live* selection rather than restating the setting. Whether learning is
    /// doing anything depends on how much history has accumulated, and a panel that claimed
    /// otherwise would be the same act of faith the dictionary's correction log exists to
    /// avoid.
    private var vocabularyNote: String {
        guard settings.learnVocabulary else {
            return "Only the dictionary primes the engine. Turn this on to also pick up the "
                + "names and jargon that recur in what you've already dictated."
        }

        let learned = BiasVocabulary.shared.current().learned
        guard !learned.isEmpty else {
            return "Nothing learned yet — a name has to recur across "
                + "\(VocabularyLearner.minimumRuns) separate dictations before it counts."
        }

        let examples = learned.prefix(3).map(\.phrase).joined(separator: ", ")
        return "Priming the engine with \(learned.count) learned "
            + (learned.count == 1 ? "term" : "terms")
            + " alongside the dictionary: \(examples)"
            + (learned.count > 3 ? "…" : "")
    }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
