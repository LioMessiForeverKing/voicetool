import SwiftUI

/// The floating readout that appears while you hold the key.
///
/// This is the surface the app is seen through: the main window is opened occasionally, but
/// the HUD is in front of you on every single dictation. It is therefore held to the design
/// system exactly like the front panel — a lit deck window with the record lamp on the left,
/// a calibrated level bargraph beside it, and the transcript on the readout.
///
/// It replaced a translucent pill with a blue-to-purple gradient, which contradicted the
/// brief on three separate counts: gradients are ruled out entirely, purple/pink gradients
/// are named as the thing to avoid, and the rounded system face is the opposite of the
/// silkscreen grotesque the rest of the app is set in.
///
/// Display-only by construction — `HUDPanel` sets `ignoresMouseEvents` and can never become
/// key, because the moment it took focus the user's text field would lose it and
/// `TextInjector` would have nothing to insert into. So there are no controls here.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.base) {
            VStack(spacing: DS.Space.tight) {
                Lamp(color: DS.Color.record, isLit: isRecording)
                Silkscreen(text: status, color: DS.Color.inkOnDeck.opacity(0.55))
            }

            LevelBargraph(level: controller.level, isActive: isMetering)
                .frame(
                    width: bargraphWidth,
                    height: DS.Material.bargraphSegmentHeight
                )

            Text(label)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck.opacity(isError ? 0.7 : 1))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(DS.Motion.panel, value: controller.transcript)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .frame(width: DS.Material.hudWidth, height: DS.Material.hudHeight)
        .background {
            // A deck window set into a brushed panel — the same construction as the main
            // window's readout, so the HUD reads as a piece of the same unit.
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(DS.Color.deck)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.panel)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                }
                .shadow(
                    color: DS.Shadow.window.color,
                    radius: DS.Shadow.window.radius,
                    x: DS.Shadow.window.x,
                    y: DS.Shadow.window.y
                )
        }
    }

    private var bargraphWidth: CGFloat {
        let count = CGFloat(DS.Material.bargraphSegments)
        return count * DS.Material.bargraphSegmentWidth
            + (count - 1) * DS.Material.bargraphSegmentGap
    }

    /// Lit from `.starting`, not from `.listening`. The lamp's job is to say the key is
    /// down and audio is being taken; waiting for the engine to be ready would leave it
    /// dark for the first moments of a recording that is already happening.
    private var isRecording: Bool {
        controller.state == .starting || controller.state == .listening
    }

    /// The bargraph, by contrast, follows `.listening` only — there is no signal to show
    /// before capture starts, and a meter that moves without input is a lie.
    private var isMetering: Bool { controller.state == .listening }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    /// The lamp's own caption. Kept to one silkscreened word: this sits under a lamp on a
    /// 76pt panel, and anything longer stops reading as equipment labelling.
    ///
    /// A fault says "Fault" rather than turning the text red. Red means recording here and
    /// nowhere else — an error that borrowed it would make the one signal that has to be
    /// unambiguous at a glance ambiguous.
    private var status: String {
        switch controller.state {
        // "Lock" is the difference between a recording that stops when you let go and one
        // that doesn't. Without it a latched session is indistinguishable from a held one,
        // and the mic stays open with no indication that it will.
        case .starting, .listening: controller.isLatched ? "Lock" : "Rec"
        case .finishing: "Proc"
        case .error: "Fault"
        case .idle: "Rec"
        }
    }

    private var label: String {
        switch controller.state {
        case .starting: "Listening…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .idle: ""
        }
    }
}

/// A segmented level bargraph with peak hold.
///
/// Replaces a row of bars whose heights rode a sine wave: that rippled prettily and told you
/// nothing, since the animation was there whether or not the signal was. Segments here are
/// calibrated against `Material.meterZeroPoint`, so the colour change *is* the information —
/// green is nominal, amber is approaching peak, red is over.
///
/// Peak hold exists because the failure it catches is invisible otherwise. Clipping is a
/// transient; by the time you look down, an instantaneous meter has already fallen back and
/// the recording is quietly ruined. The held segment stays lit long enough to be seen.
private struct LevelBargraph: View {
    let level: Float
    let isActive: Bool

    /// Peak state lives in a plain reference type, deliberately *not* in `@State` — the
    /// same reason `VUMeter` keeps its needle physics in one. It has to advance once per
    /// drawn frame, and driving that from `@State` means a mutation per tick during view
    /// update, which SwiftUI treats as undefined behaviour and logs at frame rate. A
    /// reference the view merely holds is invisible to the state graph.
    @State private var hold = PeakHold()

    private final class PeakHold {
        var value: Double = 0
        var setAt: Date = .distantPast
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let peak = advance(to: timeline.date)
            HStack(spacing: DS.Material.bargraphSegmentGap) {
                ForEach(0..<DS.Material.bargraphSegments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .fill(color(for: index, peak: peak))
                        .frame(
                            width: DS.Material.bargraphSegmentWidth,
                            height: DS.Material.bargraphSegmentHeight
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Where this segment sits on the scale, 0...1 at its top edge.
    private func threshold(for index: Int) -> Double {
        Double(index + 1) / Double(DS.Material.bargraphSegments)
    }

    private func color(for index: Int, peak: Double) -> Color {
        let point = threshold(for: index)
        let isLit = isActive && Double(level) >= point
        let isPeak = isActive && peak >= point && peak < point + segmentSpan

        guard isLit || isPeak else {
            // Unlit segments stay faintly visible — a dark lens, not an absence.
            return zoneColor(at: point).opacity(DS.Material.lampUnlitOpacity)
        }
        return zoneColor(at: point)
    }

    private var segmentSpan: Double { 1 / Double(DS.Material.bargraphSegments) }

    /// Green below 0 VU, amber approaching it, red over — the same calibration the needle
    /// on the front panel uses, so the two instruments agree.
    private func zoneColor(at point: Double) -> Color {
        if point > DS.Material.meterZeroPoint + 0.14 { return DS.Color.meterRed }
        if point > DS.Material.meterZeroPoint { return DS.Color.meterAmber }
        return DS.Color.meterGreen
    }

    /// Steps the hold and returns the peak to draw this frame.
    @discardableResult
    private func advance(to now: Date) -> Double {
        let current = Double(level)
        if current >= hold.value {
            hold.value = current
            hold.setAt = now
        } else if now.timeIntervalSince(hold.setAt) > DS.Material.bargraphPeakHold {
            // Falls back to the signal rather than snapping to zero, so the marker slides
            // down with the level instead of vanishing.
            hold.value = current
            hold.setAt = now
        }
        return hold.value
    }
}
