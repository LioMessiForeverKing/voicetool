# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio | Parakeet via sherpa-onnx |
| Location | repo root | `windows/` |

**The macOS app works and is in daily use.**

**The Windows app is complete but has never run on real hardware.** Every layer exists;
CI builds it, runs 63 tests, publishes a single-file executable, launches it on Windows and
confirms the platform layer loads and constructs. What has never happened is a person
holding the key and speaking into a microphone. Describe it that way — not as "working",
not as "unfinished".

---

## The one rule that matters

**`shared/dictionary-test-vectors.json` is the specification for correction behaviour.**

CI runs `swift test` unfiltered, and it must stay that way. It once ran
`--filter VectorTests`, which meant any suite added later was compiled but never executed —
the vocabulary learner's tests were green through two merges without one assertion running.

Both implementations run it in CI. If you change how corrections work, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
swift test --filter VectorTests                    # macOS side
cd windows && dotnet test Murmur.CrossPlatform.slnf # Windows side, runs anywhere
```

The Swift copy at `Tests/MurmurDictionaryTests/dictionary-test-vectors.json` is a copy, and
CI fails if it drifts from `shared/`. After editing the shared file:

```bash
cp shared/dictionary-test-vectors.json Tests/MurmurDictionaryTests/
```

---

## Things that look like bugs and are not

**`dotnet build Murmur.sln` fails on macOS** with `NETSDK1073`. Expected —
`Murmur.Platform.Windows` targets `net10.0-windows`. Use `Murmur.CrossPlatform.slnf`, which
omits it; everything else, including the whole UI suite, builds and tests on macOS in about
half a second.

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**`swift test` fails with `no such module 'Testing'`.** The tests use swift-testing, which
ships inside `Xcode.app` — not in the Command Line Tools, whose Swift compiler is otherwise
complete enough to build the whole app. On a machine with no Xcode installed, `xcode-select
-p` points at `/Library/Developer/CommandLineTools` and the test target won't compile at all.
CI sidesteps this by selecting the newest `Xcode.app` on the runner. Locally, either install
Xcode or install a swift.org toolchain, which bundles swift-testing:

```bash
brew install swiftly && swiftly init --assume-yes
PATH="$HOME/.swiftly/bin:$PATH" swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/swiftly-scratch"
```

**A green local `swift test` can still fail CI, with `Symbol not found` at `dlopen`.** The
package declares `.macOS(.v26)` but the workflow runs on `macos-15`, so the test bundle is
*compiled* for macOS 26 and then *loaded* on macOS 15. Anything in `MurmurDictionary` that
touches a runtime symbol newer than the runner's OS builds cleanly and dies on load. It has
happened once already, to `EnumeratedSequence`'s `Collection` conformance — a Swift 6.2
addition — reached via an innocent `.enumerated()`. Iterate with `indices` there instead.

Locally this is invisible: your Mac *is* macOS 26, so the symbol resolves and the tests pass.
Only CI can catch it. Keep the dictionary target's dependencies boring.

Keep the scratch path separate from the one `make` uses: the two toolchains write
incompatible module caches, and sharing a path makes every switch a full rebuild. Note that
the newer toolchain also surfaces diagnostics the Command Line Tools compiler doesn't, so
`swift build` there can warn where `make build` is silent.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

---

## The audio path

**`AsrManager.transcribe` silently transcribes garbage at the wrong sample rate.** FluidAudio
performs no resampling and no rate validation. Feed it 8 kHz and it does not throw, it returns
plausible nonsense. `ParakeetEngine` routes everything through FluidAudio's own `resampleBuffer`
to 16 kHz mono float32 for exactly this reason. It is a live risk, not a theoretical one: in
compare mode the capture format is Apple's choice, and `bestAvailableAudioFormat` may
legitimately return 8 kHz.

**Compare mode captures in Apple's format, not one of our choosing.** `SpeechAnalyzer` enforces
16-bit signed integers as a hard precondition and kills the process on float32 rather than
failing gracefully. Parakeet's `feed` converts int16, int32 and float32, so the strict engine
picks the format and the tolerant one adapts. Both still replay identical buffers.

**Audio must reach an engine in capture order.** One `AsyncStream` drained by a single task
guarantees that. Spawning a `Task` per buffer does not: unstructured tasks have no ordering
guarantee, the replay audio assembles out of order, and the comparison produces word-salad that
looks like an engine defect.

**`AVAudioEngine` reuses the tap's buffer as soon as the tap returns.** The engine must never see
it directly. Copy when no conversion would otherwise allocate.

**Parakeet's models take about 20 seconds to load.** That cost lands on whichever dictation
touches them first, so the first hold after launch would stall with the HUD showing nothing. They
are warmed in the background at startup, but only when they will actually be used and are already
downloaded.

---

## Things found the hard way elsewhere

**Wispr Flow stamps a row with the *start* of the utterance, not the end.** The two hotkeys are
never pressed on the same millisecond, so its row is routinely stamped slightly before our hold
began and a forward search from the hold start misses it every time. The search window is bounded
on both sides rather than just widened backwards: Wispr creates the row with null text when the
utterance starts and fills the text in afterwards, so an open-ended search happily returns the
previous dictation's row and reports it as this one's.

**Text injection falls back on a movement check, not an exact-length check.** Falling back after a
write that actually landed pastes the text a second time, and a duplicated paragraph is far worse
than a missing one. Some apps normalize newlines or run autocorrect, so the caret can legitimately
advance by something other than the UTF-16 count. Only a completely unmoved selection proves
nothing happened.

**A chord is matched on modifier flags alone, never on keyCode.** The event that completes `fn+⌃`
carries only the keyCode of whichever key moved last, so filtering by keyCode first drops half the
transitions depending on the order the user pressed them in.

**The speech bias list is capped at `DictionaryCorrector.biasLimit`.** A long context list makes
these models drift: on quiet or ambiguous audio they begin emitting the terms they were primed
with, which is a worse failure than the misspelling the biasing prevents.

**The HUD panel and its content must size from the same tokens.** `HUDPanel` sizes its window from
`DS.Material.hudWidth` and `hudHeight`. Duplicating those numbers is how the capsule ends up
off-centre inside its own window.

---

## Design system

`Sources/Murmur/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it.

The direction is 1980s field recorders — Sony TC-D5, Marantz PMD, Nakamichi, Braun. Silver
face in light appearance, black face in dark. Two rules that are not negotiable:

- **Red means recording.** Nothing else in the app is red.
- **Amber and green are instrumentation only** — level meters, never UI chrome.

Explicitly ruled out: neon, vaporwave, synthwave, purple/pink gradients, glowing text, chrome
lettering, grid horizons. There are **no gradients anywhere**; depth comes from flat panels,
hairline bevels and procedurally-drawn brushed grain.

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**No Developer ID? Make a local one.** The `Makefile` prefers a Developer ID, then falls
back to a self-signed certificate named **Murmur Local Signing**, then to ad-hoc. Only the
last is a problem: TCC needs the identity to be *stable*, not to be trusted by anyone else,
so a self-signed cert keeps the Accessibility grant across rebuilds just as well — it simply
isn't valid on any other Mac. Create one once, in **Keychain Access ▸ Certificate Assistant
▸ Create a Certificate**:

| Field | Value |
|---|---|
| Name | `Murmur Local Signing` |
| Identity Type | Self Signed Root |
| Certificate Type | **Code Signing** |
| Let me override defaults | unchecked |

It has to be created through the GUI: the trust settings that make `codesign` accept it are
written to the user's keychain and macOS requires an interactive authorisation for that, so
there is no `security` incantation that does the whole job unattended. Confirm it took with
`security find-identity -v -p codesigning`, then `make install` and re-grant Accessibility
one final time.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Windows specifics

The specifics below were expensive to establish and several were found the hard way. Treat
them as load-bearing. Full detail in `windows/README.md` and `docs/PARAKEET-WINDOWS.md`.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**`Murmur.App` loads the platform layer by reflection, not by reference.** A direct
reference would force the UI onto `net10.0-windows` and you would lose the ability to run it
on your own machine. Two consequences that have already bitten once: the assembly is
invisible to `PublishSingleFile`, so it is published as a loose file beside the exe *and*
resolved by an explicit `AssemblyLoadContext` handler; and the published self-test checks
this, because when it breaks the app starts perfectly and then does nothing at all when the
key is pressed.

**Keep `Murmur.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

**A `WH_KEYBOARD_LL` hook must always chain, and must never throw.** Microsoft is explicit that
failing to chain leaves other applications' hooks without notifications. An exception escaping
into the hook chain takes the process down from a thread with no useful context, so the callback
swallows and chains regardless.

**A global hook needs a message pump.** The system delivers hook callbacks by *sending a message*
to the installing thread, so without a pump the hook is installed and never invoked. The pump
deliberately skips `TranslateMessage`/`DispatchMessage`: the thread owns no windows and cares only
about the `WM_QUIT` that ends it. Stay ahead of the 1000 ms timeout that silently removes a slow
hook.

**Audio uses the Communications device role, not Console.** It follows the device the user chose
as their default *communication* device, which is what headset users expect. The capture channel
is bounded and drop-oldest on purpose: losing the oldest audio is bad, stalling the audio engine
is worse.

**Avalonia throws if you assign a property during the render pass.** Not a log line, an exception:
"Visual was invalidated during the render pass." `Equipment.cs` updates `Foreground` outside
`Render` for this reason. Render must stay a pure function of current state.

**The dictionary replacement must stay literal.** The C# side uses a `MatchEvaluator` rather than a
replacement string, because a plain `Replace` treats `$1` and `$&` appearing in *the user's own
text* as substitutions, and that text is arbitrary input. Triggers are sorted longest-first;
LINQ's `OrderByDescending` is stable while Swift's sort is not, but ties can only occur between
triggers of identical length, which cannot overlap the same span twice, so both platforms observe
the same result.

---

## Regex, if you touch the dictionary

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **Command Mode** — select text, hold a second key, "make this more formal."
2. **Onboarding** — a first-run window walking through the macOS permissions.
3. **Notarization** (macOS) and **code signing** (Windows). Both apps are unsigned for
   distribution, so Windows users will meet SmartScreen.
4. **An installer** for Windows, and model download from inside the app rather than by
   following `docs/PARAKEET-WINDOWS.md` by hand.

## What no amount of CI can verify

On Windows, nobody has yet held the key and spoken. Specifically unverified:

- Text injection landing in a foreground app — runners have an interactive desktop but
  cannot take the foreground.
- A real microphone: format negotiation, the OS privacy block, unplugging mid-capture.
- The keyboard hook firing on a physical keypress.
- Parakeet transcribing real speech, and whether ~2 GB resident is tolerable.

Everything those feed into is behind an interface and tested with fakes. The bindings
themselves are not. **First real-hardware run should start with `--selftest`, then a single
short dictation into Notepad.**
