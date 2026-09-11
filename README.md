# Murmur

Push-to-talk dictation for macOS. Hold a key, talk, release — cleaned-up text lands in
whatever text field has focus. A Wispr Flow-shaped app, built native and fully on-device.

**Status:** in daily use on macOS. Builds, launches, arms the hotkey, transcribes, injects,
and learns the names you actually say. The LLM cleanup tier is optional and on-device.

---

## Install

**Requires macOS 26.** Grab the newest `.zip` from
[Releases](https://github.com/LioMessiForeverKing/voicetool/releases), unzip it, and drag
**Murmur.app** into Applications. Releases are signed with a Developer ID and notarized by
Apple, so it opens without a Gatekeeper warning — no `xattr` incantation, no right-click
Open. Then grant the two permissions below and hold **Right ⌥**.

To build it yourself instead, see [Quick start](#quick-start).

### Updating

From **0.3.0** onward Murmur updates itself: it checks GitHub for a newer release, and
**Check for Updates…** in the app menu asks immediately. Transcription stays entirely
on-device — this is the only network request the app makes, and Sparkle asks before it makes
the first one, so declining leaves the app exactly as offline as it was.

0.1.0 and 0.2.0 shipped without an updater and cannot learn about this. If you are holding
one of those, download 0.3.0 by hand once; every release after it arrives on its own.

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.murmur`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `Murmur`** — `pkill -x` is case-sensitive and matches the whole name, so it
  cannot hit a lowercase `murmur` binary from another vendor. The `Makefile` only ever
  targets `$(EXEC)`.
- **The hotkey is yours to choose** — any modifier, or a chord of them, recorded in
  Settings — precisely because another tool may already own the key you'd reach for first.
  The event tap matches only its own chord and passes everything else through untouched,
  and it declines to swallow the event at all unless every key in the chord is a right-hand
  modifier.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant two permissions — neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |

Restart Murmur after granting Accessibility. Then hold **Right ⌥** and talk.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore signs with a stable Developer ID (auto-detected via
`security find-identity`, falling back to ad-hoc). Verified: rebuild + reinstall keeps both
grants with no re-prompt.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
tccutil reset Microphone   ai.pivotstudio.murmur
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► AppleSpeechEngine
                                            │
                                       (transcript)
                                            ▼
                                      TextFormatter
                                            ▼
                                      TextInjector ─► focused app
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
discrimination don't surface through `NSEvent.addGlobalMonitorForEvents` or the Carbon
hotkey API. A session event tap is the only way to see them — which is why Accessibility
permission is a hard requirement rather than a nicety.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols so the
two components most likely to change can change without touching anything else.

### Layout

```
Sources/Murmur/
├── MurmurApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         CGEventTap on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap + format conversion + RMS
│   └── TextInjector.swift          AX insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   └── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber
├── Formatting/
│   └── TextFormatter.swift         protocol + RuleBasedFormatter
├── UI/
│   ├── HUDPanel.swift              non-activating floating panel
│   └── HUDView.swift               waveform + live transcript, Brand palette
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift
```

---

## Speech engine

Default is Apple's **`SpeechAnalyzer` / `SpeechTranscriber`**, new in macOS 26: no
dependency, no bundled model, no cloud path, real streaming with `.volatileResults` so
text appears while you're still talking. The OS downloads and manages model assets, so the
first run for a locale may pause on `AssetInstallationRequest`.

The intended upgrade is **Parakeet v3** via FluidAudio (CoreML on the Neural Engine) —
measurably better English WER, ~110× realtime, ~66 MB resident. Implementing
`TranscriptionEngine` is the entire cost of switching; `DictationController` doesn't
change.

| | Apple SpeechTranscriber | Parakeet v3 (FluidAudio) | Whisper large-v3 (WhisperKit) |
|---|---|---|---|
| Dependency | none | SwiftPM | SwiftPM |
| Model download | OS-managed | ~600 MB | ~1.5 GB |
| English accuracy | good | best | good |
| Languages | many | 25 | 99 |
| Latency | low | ~80 ms | 200–500 ms |

---

## Dictionary

Names and jargon the engine keeps fumbling, in two shapes: a **term** is a word it should
know exists (`Anthropic`), a **correction** is a mapping (`cloud code -> Claude Code`).
Corrections match by sound as well as spelling, so one entry covers every way a name can come
out wrong. It is a plain text file — `~/Library/Application Support/Murmur/dictionary.txt` —
watched while the app runs, so editing it in any editor updates the UI live.

Murmur also **learns**, mining recurring names out of what you have already dictated and
priming the engine with them. Spellings that sound alike are grouped, so `Supabase`,
`Soopabase` and `SupaBase` arrive as one row rather than three, with the most frequent
spelling leading and the rest listed beneath it. Only that leading spelling is primed —
priming the variants would teach the engine its own mishearings.

Each row offers three answers. **Keep** promotes the leading spelling to a permanent entry.
**Fix…** is for when the group is led by the wrong spelling, or a mishearing is too far off
to have been grouped at all: type what the word really is and every variant becomes a
correction pointing at it. **Ignore** stops it being suggested, and the footer restores
everything ignored.

The dictionary is laid down first and learning only fills the
`DictionaryCorrector.biasLimit` slots left over, so a hand-written entry always outranks a
guess. Turn learning off in Settings and only the dictionary primes the engine.

---

## Not built yet

1. **A hosted cleanup tier.** `RuleBasedFormatter` strips fillers, fixes spacing, capitalizes
   sentences and adds terminal punctuation, entirely deterministically; `FoundationModelFormatter`
   is the on-device LLM pass behind the **smart cleanup** setting. Neither honors spoken
   corrections yet, and Claude as an optional higher-quality tier is still unbuilt.
2. **Command Mode.** Select text, hold a second hotkey, say "make this more formal."
   Needs AX read of `kAXSelectedTextAttribute` plus an LLM round-trip.
3. **Branding.** `Brand` in `HUDView.swift` is a two-color placeholder gradient. App icon,
   real palette, HUD motion design, onboarding.
4. **Onboarding.** A first-run window that walks through both permissions instead of
   relying on the menu's "Grant…" items.

---

## Releasing

Tag a commit and `.github/workflows/release.yml` builds `CONFIG=release`, signs with the
Developer ID, notarizes, staples, and publishes the `.zip` to Releases:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The tag must match `CFBundleShortVersionString` in `Resources/Info.plist` or the workflow
stops before signing anything. `workflow_dispatch` runs everything except the publish, so
the whole path can be rehearsed without spending a version number.

Six repository secrets drive it. Set them with `gh secret set`; none of them belong in the
repo:

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | The Developer ID Application certificate, exported as `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | The password set when exporting that `.p12` |
| `APPLE_ID` | Apple ID of the Developer Program account |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com, for `notarytool` |
| `APPLE_TEAM_ID` | The 10-character team ID, also in the certificate's common name |
| `SPARKLE_PRIVATE_KEY` | The EdDSA update key, exported with `generate_keys -x` |

**The update key has nothing to do with the other five.** Apple's certificate proves who
built the app; Sparkle's EdDSA key proves the archive an installed copy is about to download
is the one this workflow published. It is generated once with Sparkle's `generate_keys`,
lives in the login keychain of the Mac that made it, and only its public half —
`SUPublicEDKey` — is in the repo. Losing the private half means every installed copy stops
accepting updates until it is replaced by hand.

**An app-specific password, not an App Store Connect API key.** The key is the sturdier
credential and is what Apple documents first, but it adds a third secret file to manage for
a repo that publishes one artifact from one workflow. Revisit if notarization ever moves
off a single personal Apple ID.

**Local builds are unaffected.** `SIGN_TIMESTAMP` defaults to `--timestamp=none` so `make`
still works offline; only the release overrides it, because notarization rejects a
signature with no secure timestamp.

**The release also publishes `appcast.xml`**, the feed every installed copy reads from
`releases/latest/download/appcast.xml` — the one GitHub URL that follows the newest release
instead of pinning to a tag. Two gates guard it: the workflow refuses a `CFBundleVersion`
that is not greater than the published one, since Sparkle compares build numbers and would
silently offer nothing, and `swift test` refuses a feed URL that has been pointed at a
per-tag asset.

---

## Verified

Driven with a synthetic Right ⌥ hold (`scratchpad/ptt/ptt2.swift` posts `flagsChanged`
events) and confirmed via `/usr/bin/log show --predicate 'subsystem ==
"ai.pivotstudio.murmur"'`:

- Builds clean under Swift 6 strict concurrency.
- Signs with Developer ID; grants survive rebuild + reinstall.
- Launches as an accessory app, no Dock icon, menu bar item present.
- Event tap arms on grant without a restart (the poller catches it).
- Full state machine: `starting → listening → finishing → idle`, no errors.
- `SpeechAnalyzer` starts; models already installed, no download stall.
- Audio capture runs and converts native 48 kHz → 16 kHz for the engine.
- HUD renders bottom-center at `{{790, 96}, {340, 76}}` without taking focus.
- Silence produces an empty transcript and injects nothing.

**Not yet verified:** speech → transcript → cleanup → injection. Synthetic key events
can't produce audio, so this needs a human to hold the key and talk.

> `log` is shadowed in this shell — use `/usr/bin/log` explicitly or it returns nothing.
