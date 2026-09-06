import AppKit
import MurmurDictionary
import MurmurInput
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
                        ForEach(Hotkey.presets, id: \.self) { preset in
                            presetKey(preset)
                        }
                    }

                    HotkeyRecorder(hotkey: $settings.hotkey) {
                        controller.reloadHotkey()
                    }
                    note("Hold this anywhere to dictate — one key, or several held together. "
                        + "The window's Record button works regardless of what's focused.")

                    Toggle(isOn: $settings.latchEnabled) {
                        Silkscreen(text: "Double-tap to keep recording")
                    }
                    .toggleStyle(.switch)
                    note("Tap twice to carry on with the key released, then tap once to stop. "
                        + "Holding is unaffected — it still stops the moment you let go.")

                    if settings.hotkey.modifiers.contains(.fn) {
                        note(fnWarning)
                    }
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
        .frame(width: 520, height: 780)
    }

    /// fn is the one key here the app cannot take exclusive use of.
    ///
    /// `PushToTalkKey.shouldConsumeEvent` is false for fn on purpose — swallowing it would
    /// break fn+arrow, fn+delete and the emoji picker — so macOS still sees every press and
    /// runs whatever "Press 🌐 key to" is set to. Double-tapping therefore fires that action
    /// twice, which on a default Mac means the emoji picker opening over what you're
    /// dictating into. Worth saying here rather than leaving it to be discovered.
    private var fnWarning: String {
        "macOS also acts on fn. If the emoji picker or input-source switcher appears while "
            + "you dictate, set System Settings ▸ Keyboard ▸ “Press 🌐 key to” to “Do Nothing”."
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

    private func presetKey(_ preset: Hotkey) -> some View {
        TransportKey(
            title: preset.displayName,
            isEngaged: settings.hotkey == preset,
            engagedColor: DS.Color.ink
        ) {
            settings.hotkey = preset
            controller.reloadHotkey()
        }
        .background {
            if settings.hotkey == preset {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Color.selection)
            }
        }
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


/// Sets the push-to-talk chord by having the user press it.
///
/// A recorder rather than a longer list of presets: the useful combinations are the ones a
/// given person's keyboard and habits leave free, and that isn't enumerable in advance. Only
/// modifiers can be captured — see `ModifierKey` for why a letter key cannot work here.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    let onChange: () -> Void

    @State private var isRecording = false
    @State private var captured: [ModifierKey] = []
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            DeckWindow {
                Readout(text: readout)
                    .padding(.horizontal, DS.Space.base)
                    .padding(.vertical, DS.Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TransportKey(
                title: isRecording ? "Cancel" : "Set…",
                isEngaged: isRecording,
                engagedColor: DS.Color.ink
            ) {
                if isRecording { cancel() } else { begin() }
            }
        }
        .onDisappear(perform: cancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Push-to-talk key")
        .accessibilityValue(hotkey.displayName)
    }

    private var readout: String {
        guard isRecording else { return hotkey.displayName }
        return Hotkey(captured)?.displayName ?? "Press and hold…"
    }

    private func begin() {
        captured = []
        isRecording = true
        // Local, not global: this listens only while its own window is key, so arming the
        // recorder can never quietly capture keystrokes meant for another app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            // Swallowed while recording, so pressing ⌘ doesn't also drive the menu bar.
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let down = Hotkey.modifiers(in: UInt64(event.modifierFlags.rawValue))

        guard down.isEmpty else {
            for key in down where !captured.contains(key) {
                captured.append(key)
            }
            return
        }

        // Everything released, so the chord is whatever was held at its fullest. Committing
        // on release rather than on press is what lets a chord be built up at all — on press
        // the first key would be committed before the second one arrived.
        if let recorded = Hotkey(captured) {
            hotkey = recorded
            finish()
            onChange()
        }
    }

    private func cancel() {
        guard isRecording else { return }
        finish()
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        captured = []
    }
}
