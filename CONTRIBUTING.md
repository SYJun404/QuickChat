# Developing QuickChat

QuickChat is built for personal use and shared as-is, so there is no roadmap and no guarantee a pull request gets merged — but bug reports are welcome, and if you want to build on it yourself, this is what you need to know.

## Layout

Plain SwiftPM, no Xcode project. `Package.swift` builds a single executable target; `build.sh` wraps the binary in an app bundle (`LSUIElement`, ad-hoc signed) and `release.sh` does the Developer-ID + notarization path.

```
Sources/QuickChat/         AppKit shell, SwiftUI views, Theme
Sources/QuickChat/Chat/    providers, streaming clients, stores, web tools
Resources/               Info.plist, app icon
Tools/                   fake app-server fixtures used by the smoke harnesses
```

`KeyboardShortcuts` is pinned to exactly 1.15.0: later versions use `#Preview` macros, which need full Xcode and fail to compile with the Command Line Tools alone.

## Test harnesses

`./build.sh debug` produces `.build/debug/QuickChat`, which doubles as a headless test harness — there is no XCTest suite; the flags below are the test suite. (Go through the script rather than a bare `swift build`: it pins the build backend and, on Command Line Tools whose default SDK needs Xcode's SwiftUI macro plugin, the SDK.)

```sh
POPCHAT_API_KEY=… .build/debug/QuickChat --smoke              # live streaming round-trip
POPCHAT_API_KEY=… .build/debug/QuickChat --smoke-search       # tool-calling loop
.build/debug/QuickChat --smoke-file <path>                    # attachment extraction
.build/debug/QuickChat --smoke-typing                         # composer latency budget
.build/debug/QuickChat --smoke-scroll                         # transcript scroll perf
.build/debug/QuickChat --smoke-find                           # find-in-chat behavior
```

`--smoke-persist`, `--smoke-history`, `--smoke-minsize`, `--smoke-pasteable`, `--smoke-providers`, `--smoke-accent`, `--smoke-typewriter`, `--chatgpt-login` and `--smoke-chatgpt` cover the rest. `--check-codex-app-server` checks the installed Codex, ChatGPT login and available model catalog without starting a model turn; `--smoke-codex-refresh-coalescing` verifies overlapping checks share one process. `--shot <settings|general|switcher|transcript|thinking|accent> <path> [--dark|--light]` renders a view to PNG in-process (`transcript` forces a solid panel — glass has no backdrop to composite against offscreen — and seeds itself through `ConversationStore.save` so the shot exercises the real restore path).

The check-list harnesses share `CheckLog` (`check` / `finish`) and the GUI ones share `composerTextView(in:)`, `sendKey(...)` and `sendArrow(...)` — add to those rather than re-declaring a local copy.

Four more need neither network nor GUI, plus one that drives the real composer:

```sh
.build/debug/QuickChat --smoke-rerun         # Retry / Edit prompt truncation, fork safety, ↑ history storage
.build/debug/QuickChat --smoke-chat-search   # cross-conversation body search + excerpts
.build/debug/QuickChat --smoke-reasoning     # reasoning wire spellings, waiting-row line, metrics-neutral styling
.build/debug/QuickChat --smoke-update        # version ordering + GitHub release decoding
.build/debug/QuickChat --smoke-recall        # ↑/↓ prompt recall through real arrow-key events (GUI)
```

Three harnesses drive a fake app-server instead of the real one, so they cost no subscription quota and need no Codex install:

```sh
.build/debug/QuickChat --smoke-codex-app-server-streaming    Tools/fake-codex-stream
.build/debug/QuickChat --smoke-codex-app-server-timeout      Tools/fake-codex-stall
.build/debug/QuickChat --smoke-codex-app-server-backpressure Tools/fake-codex-wedge
```

They guard, in order: turn assembly and notification ordering (both agent messages must survive, the first delta must not wait on the `turn/start` response, a replayed `item/completed` must not duplicate its item, and a `willRetry` error must drop the aborted in-flight partial and surface a retry status rather than gluing the re-stream onto it in silence — plus the same three rules for reasoning: summary parts of one item stay separate thoughts, raw reasoning loses to a summary, and a retry drops the aborted thinking); recovery from a process that goes silent mid-turn; and the rule that a process which stops draining its stdin cannot wedge QuickChat — never hold a lock across the blocking write, or Stop and the watchdog both block behind it.

Two rules when running these:

- Each GUI harness builds a real key window, so **run them one at a time**, not back-to-back — otherwise they fight over key status and stray keystrokes land in the wrong field, failing spuriously.
- The performance harnesses fail on main-thread stalls, so run `--smoke-typing` and `--smoke-scroll` after touching the transcript, the composer or panel sizing.
- `--smoke-history` and `--smoke-recall` locate real controls by their placeholder text, so renaming one is a harness change too — that is the point, not an annoyance.

## Performance constraints

Responsiveness is a hard requirement, and several obvious-looking changes break it badly. Before touching the transcript or composer, know that: the transcript is a plain `VStack` (a `LazyVStack` fights `NSScrollView` into a freeze), message rows are `Equatable`-gated so a streaming tick re-renders only the changed row, the root `NSHostingView` has `sizingOptions = []` so composer resizing can't re-measure the whole tree, and panel show/hide animates a `CALayer` transform rather than the window frame. Visual fidelity matters; implementation fidelity does not — prefer the cheapest technique that looks the same.

## Releasing

`./release.sh` builds, signs with a Developer ID, notarizes and staples both the app and the disk image, then verifies it as Gatekeeper would. It needs a stored notarytool profile (see the header comment in the script) and only works with my certificate.
