import MurmurDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a silkscreen tag on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var fixing: LearnedCluster?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    /// What the engine is primed with right now, rather than everything ever mined.
    ///
    /// The dictionary is laid down first and learning only fills the slots it left, so a term
    /// crowded out of the bias list is not in effect — listing it would offer a decision about
    /// something that is not currently happening.
    private var learned: [LearnedCluster] {
        let clusters = BiasVocabulary.shared.current().clusters
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clusters }
        return clusters.filter { cluster in
            cluster.phrases.contains { $0.localizedStandardContains(trimmed) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SearchField(text: $query, placeholder: "Search dictionary")
                addButton
                    .padding(.trailing, DS.Space.base)
                    .background(DS.Color.deck)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }

            if entries.isEmpty, learned.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Dictionary empty" : "No matches",
                    detail: store.entries.isEmpty
                        ? "Add words it keeps getting wrong."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(entries) { entry in
                            DictionaryRow(
                                entry: entry,
                                onEdit: { editing = entry },
                                onToggle: {
                                    var updated = entry
                                    updated.isEnabled.toggle()
                                    store.update(updated)
                                },
                                onDelete: { store.delete(entry) }
                            )
                        }

                        if !learned.isEmpty {
                            LearnedSection(
                                clusters: learned,
                                onKeep: { store.add(.term($0.primary.phrase)) },
                                onFix: { fixing = $0 },
                                onIgnore: { cluster in
                                    cluster.phrases.forEach {
                                        settings.dismissedLearnedTerms.insert($0)
                                    }
                                }
                            )
                        }
                    }
                    .padding(DS.Space.base)
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
        .sheet(item: $fixing) { cluster in
            ClusterResolver(
                cluster: cluster,
                suggestion: VocabularyLearner.knownSpelling(for: cluster, in: store.entries)
            ) { correct in
                store.add(contentsOf: cluster.corrections(to: correct))
            }
        }
    }

    private var addButton: some View {
        Button { isAdding = true } label: {
            HStack(spacing: DS.Space.tight) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Silkscreen(text: "Add", color: DS.Color.inkOnDeck)
            }
            .foregroundStyle(DS.Color.inkOnDeck)
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.inkOnDeck.opacity(0.35), lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    /// The file path is shown because the spec asks for the dictionary to be editable outside
    /// the UI — which is only true if you can find it.
    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            Silkscreen(text: "\(store.entries.count) entries", color: DS.Color.inkOnDeck.opacity(0.5))
            if !settings.dismissedLearnedTerms.isEmpty {
                Button { settings.dismissedLearnedTerms.removeAll() } label: {
                    Silkscreen(
                        text: "Restore \(settings.dismissedLearnedTerms.count) ignored",
                        color: DS.Color.inkOnDeck.opacity(0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Let the learner suggest these terms again")
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            } label: {
                Silkscreen(text: "Reveal dictionary.txt", color: DS.Color.inkOnDeck.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(DictionaryStore.fileURL.path)
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.deck)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Lamp(color: DS.Color.meterGreen, isLit: entry.isEnabled, size: 6)

            Silkscreen(
                text: entry.kind == .correction ? "Fix" : "Term",
                color: DS.Color.inkOnDeck.opacity(0.5)
            )
            .frame(width: 34, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.6))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.inkOnDeck)

            Spacer()

            if isHovering {
                rowButton("Edit", action: onEdit)
                rowButton(entry.isEnabled ? "Off" : "On", action: onToggle)
                rowButton("Delete", action: onDelete)
            }
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(isHovering ? DS.Color.hover : DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Silkscreen(text: title, color: DS.Color.inkOnDeck.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Learned

/// What the app mined out of past transcripts, and the decisions available about it.
///
/// Below the dictionary rather than above it: these are guesses, and the entries the user
/// wrote by hand outrank them. Shown at all because the learner is otherwise invisible — it
/// primes the engine on every recording with words nobody ever confirmed.
private struct LearnedSection: View {
    let clusters: [LearnedCluster]
    let onKeep: (LearnedCluster) -> Void
    let onFix: (LearnedCluster) -> Void
    let onIgnore: (LearnedCluster) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Rectangle()
                .fill(DS.Color.seam)
                .frame(height: DS.Border.seam)
                .padding(.top, DS.Space.roomy)

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    Silkscreen(text: "Learned from your speech", color: DS.Color.inkOnDeck.opacity(0.55))
                    Silkscreen(text: "\(clusters.count)", color: DS.Color.inkOnDeck.opacity(0.3))
                }
                Text("Names picked out of what you've dictated, priming the engine already. "
                    + "Keep writes one into the dictionary, Fix corrects a mishearing, "
                    + "Ignore stops it coming back.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.bottom, DS.Space.tight)

            ForEach(clusters) { cluster in
                LearnedRow(
                    cluster: cluster,
                    onKeep: { onKeep(cluster) },
                    onFix: { onFix(cluster) },
                    onIgnore: { onIgnore(cluster) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One name, with every answer on the row.
///
/// The dictionary rows reveal their controls on hover, which suits a list you mostly read.
/// This list exists to be answered, and a decision hidden until the pointer lands on it is
/// one most people never discover they were being asked for.
///
/// The lamp is amber where the dictionary's is green: lit, because these are priming the
/// engine right now, but not the settled green of something the user confirmed.
private struct LearnedRow: View {
    let cluster: LearnedCluster
    let onKeep: () -> Void
    let onFix: () -> Void
    let onIgnore: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            HStack(spacing: DS.Space.snug) {
                Lamp(color: DS.Color.meterAmber, isLit: true, size: 6)
                    .padding(.trailing, DS.Space.tight)

                Text(cluster.primary.phrase)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.inkOnDeck)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Silkscreen(
                    text: cluster.runCount == 1 ? "1 run" : "\(cluster.runCount) runs",
                    color: DS.Color.inkOnDeck.opacity(0.35)
                )
                .fixedSize()

                Spacer(minLength: DS.Space.base)

                action("Keep", isPrimary: !cluster.isSplit, action: onKeep)
                action("Fix…", isPrimary: cluster.isSplit, action: onFix)
                action("Ignore", isPrimary: false, action: onIgnore)
            }

            if cluster.isSplit {
                Text("heard \(cluster.variants.count) ways — " + spellings)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.meterAmber.opacity(0.75))
                    .padding(.leading, 26)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(isHovering ? DS.Color.hover : DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
        .onHover { isHovering = $0 }
    }

    private var spellings: String {
        cluster.variants
            .map { "\($0.phrase) ×\($0.runCount)" }
            .joined(separator: "  ·  ")
    }

    private func action(_ title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Silkscreen(text: title, color: DS.Color.inkOnDeck.opacity(isPrimary ? 0.85 : 0.5))
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(
                            DS.Color.inkOnDeck.opacity(isPrimary ? 0.3 : 0.15),
                            lineWidth: DS.Border.hairline
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resolver

/// Settles a learned name on one spelling.
///
/// The spelling the engine produced most often is offered first, but it is only a default:
/// an engine can fumble a name every single time it hears it, and then the right answer is
/// in none of the variants and has to be typed.
private struct ClusterResolver: View {
    let cluster: LearnedCluster
    let suggestion: String?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var write: String

    init(cluster: LearnedCluster, suggestion: String?, onSave: @escaping (String) -> Void) {
        self.cluster = cluster
        self.suggestion = suggestion
        self.onSave = onSave
        _write = State(initialValue: suggestion ?? cluster.primary.phrase)
    }

    private var trimmed: String { write.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var corrected: [String] {
        cluster.phrases.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: "Write it correctly", large: true)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Silkscreen(text: cluster.isSplit
                    ? "Heard \(cluster.variants.count) ways across \(cluster.runCount) dictations"
                    : "Heard \(cluster.runCount) times")

                HStack(spacing: DS.Space.tight) {
                    ForEach(cluster.variants, id: \.phrase) { variant in
                        Button { write = variant.phrase } label: {
                            HStack(spacing: DS.Space.tight) {
                                Text(variant.phrase).font(DS.Font.body)
                                Silkscreen(text: "×\(variant.runCount)",
                                           color: DS.Color.inkOnDeck.opacity(0.45))
                            }
                            .foregroundStyle(DS.Color.inkOnDeck)
                            .padding(.horizontal, DS.Space.snug)
                            .padding(.vertical, DS.Space.tight)
                            .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.chip)
                                    .strokeBorder(
                                        variant.phrase.caseInsensitiveCompare(trimmed) == .orderedSame
                                            ? DS.Color.meterGreen.opacity(0.7)
                                            : DS.Color.seam,
                                        lineWidth: DS.Border.hairline
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let suggestion {
                note("Your dictionary already has “\(suggestion)”, and this sounds like it.")
            }

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Write")
                TextField(cluster.primary.phrase, text: $write)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck)
                    .padding(DS.Space.snug)
                    .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    )
            }

            Text(outcome)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { dismiss() }
                TransportKey(title: "Save", isEngaged: !trimmed.isEmpty, engagedColor: DS.Color.ink) {
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                    dismiss()
                }
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 460)
        .background(BrushedPanel(radius: DS.Radius.window))
    }

    private var outcome: String {
        guard !trimmed.isEmpty else { return "Type the spelling you actually want written." }
        guard !corrected.isEmpty else {
            return "Adds “\(trimmed)” to the dictionary as a term."
        }
        let list = corrected.map { "“\($0)”" }.joined(separator: ", ")
        return "Adds “\(trimmed)” as a term, and corrects \(list) to it from now on."
    }

    private func note(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.snug) {
            Lamp(color: DS.Color.meterGreen, isLit: true, size: 6).padding(.top, 3)
            Text(message)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip)
                .strokeBorder(DS.Color.meterGreen.opacity(0.4), lineWidth: DS.Border.hairline)
        )
    }
}

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] {
        DictionaryWarning.check(draft) + DictionaryWarning.checkSoundMatching(draft)
    }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: entry == nil ? "New entry" : "Edit entry", large: true)

            kindPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    field("When you hear", text: $hear, prompt: "cloud code")
                }
                field(
                    kind == .correction ? "Write" : "Word or phrase",
                    text: $write,
                    prompt: kind == .correction ? "Claude Code" : "Anthropic"
                )
            }

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    Lamp(color: DS.Color.meterAmber, isLit: true, size: 6)
                        .padding(.top, 3)
                    Text(warning.message)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.meterAmber.opacity(0.4), lineWidth: DS.Border.hairline)
                )
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { dismiss() }
                TransportKey(title: "Save", isEngaged: isValid, engagedColor: DS.Color.ink) {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 460)
        .background(BrushedPanel(radius: DS.Radius.window))
    }

    private var kindPicker: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach([DictionaryEntry.Kind.term, .correction], id: \.self) { candidate in
                TransportKey(
                    title: candidate == .term ? "Term" : "Correction",
                    isEngaged: kind == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { kind = candidate }
                }
                .background {
                    if kind == candidate {
                        RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.selection)
                    }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Silkscreen(text: label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.snug)
                .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
        }
    }
}
