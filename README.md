# Heard

A macOS menu bar app that automatically detects Microsoft Teams meetings, records dual-track audio (app + mic), and produces on-device transcripts with speaker diarization. Also includes a real-time dictation mode that types transcribed speech into any focused text field.

No cloud, no LLM, no external APIs — everything runs on-device on Apple Silicon.

## Features

### Meeting Transcription
- **Teams auto-detection** — Polls `IOPMCopyAssertionsByProcess()` every 3 seconds for Teams power assertions (`PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion` / "Call in progress"). Requires 2 consecutive hits before triggering; applies a 5-second cooldown on end. Recognises Teams classic, New Teams, and "work or school" variants.
- **Meeting title extraction** — Reads the Teams window title via the Accessibility API and strips the ` | Microsoft Teams` suffix for the transcript filename.
- **Dual-track recording** — The mic track is captured via `AVAudioEngine`; the app track is captured via `CATapDescription` + a private aggregate device + a raw AUHAL output unit. The tap collects **all** Teams-related CoreAudio process object IDs (main + renderer children) so audio from Electron/Chromium sub-processes isn't lost. Both tracks land on disk as 48 kHz WAVs and are never mixed during recording.
- **Roster scraping** — Reads Teams participant names via Accessibility APIs every 15 s while a meeting is active. Three strategies: known roster-panel identifiers → AXList/AXTable containers → window-title parsing. Filters out UI control strings (mute, raise hand, etc.).
- **On-device pipeline** — Sequential stages per job: preprocessing (48 kHz → 16 kHz mono via `AVAudioConverter`, in-memory Silero VAD trimming + `VadSegmentMap`) → Parakeet TDT V2 transcription (per-track, with optional CTC vocabulary boosting) → LS-EEND + WeSpeaker diarization → speaker assignment and Markdown output.
- **Speaker identification** — Cosine-distance matching (threshold 0.40, confidence margin 0.10) against a persistent speaker database, with embedding diversity management and auto-update on confident matches.
- **Roster-aware auto-naming** — When one speaker is unmatched and exactly one roster name is unclaimed, the roster name is assigned automatically without prompting.
- **Speaker naming window** — When unmatched speakers remain, a dedicated "Name Speakers" window opens with a **playable audio clip** (~10 s of each speaker's clearest speech, extracted from the 48 kHz recording), a text field pre-populated with any roster suggestion, and a 120 s auto-dismiss countdown.
- **Custom vocabulary boosting** — CTC-based keyword boosting via `Parakeet CTC 110M` applied to both meeting transcription and dictation. Terms are added from Settings → General (min 3 chars, max 50 terms). Falls back gracefully if the CTC model can't be loaded.
- **Persistent job queue** — `pipeline_queue.json` survives app restarts; failed jobs are re-queued once on relaunch. Non-retryable errors (no audio, too short) fail immediately; transient errors retry 3× with exponential backoff (5 s, 30 s, 5 min).
- **Long-meeting handling** — 4 h hard cap; on hit, the current recording is finalized and a fresh one starts if the meeting is still active.
- **Markdown output** — Timestamped, speaker-labeled transcripts written to a configurable output folder. Consecutive segments from the same speaker are merged into continuous blocks.

### Dictation
- **Real-time speech-to-text** — Uses the same Parakeet TDT V2 batch `AsrManager` with a 0.6 s polling loop. Accumulates mic audio in a thread-safe buffer, re-transcribes every cycle, and diffs the output.
- **Stability-based text injection** — Only injects words that appear in the same position across **two consecutive** transcription cycles. This prevents duplicates when the model revises earlier words as more audio accumulates.
- **Text injection** — `CGEvent.keyboardSetUnicodeString` + `postToPid` targets the frontmost app; falls back to HID-level events, then clipboard paste. All paths require Accessibility permission.
- **Global hotkey** — Default ⌃⇧D, registered via Carbon `RegisterEventHotKey`. No Accessibility permission needed for the hotkey itself, so it keeps working across ad-hoc rebuilds. Rebindable via a Record sheet in the Dictation tab.
- **Toggle and push-to-talk modes** — Tap to toggle, or hold the hotkey to dictate and release to stop.
- **Model keep-alive** — ASR models stay resident for a configurable period (0 – 10 min, default 120 s) after dictation stops to avoid reload latency between utterances.

### UI
- **Menu bar icon** — SF Symbols with symbol effects: static `recordingtape` when idle, pulsing/breathing `record.circle` while recording or dictating, iterative `waveform` while processing, `exclamationmark.circle.fill` on error, `person.crop.circle.badge.exclamationmark` when waiting for speaker naming.
- **Menu bar dropdown** — Current status card (watching/recording/processing/dictating), quick actions (start dictation, open transcripts, name speakers, settings, quit), and developer-mode simulate buttons.
- **Settings window** — Five tabs: **General** (launch at login, auto-watch, developer mode, custom vocabulary, output folder, permissions), **Dictation** (enable, push-to-talk, hotkey recorder, model keep-alive slider, live status), **Models** (download cards with progress, pipeline keep-alive, "Unload All Models"), **Speakers** (your name, inline rename, merge, delete, search, sort), **About**.
- **Name Speakers window** — Standalone scene with audio-clip playback per candidate, roster-suggestion hints, save/skip, and a 120 s countdown.

## Requirements

- macOS 14.2+ (required by `CATapDescription`)
- Apple Silicon (FluidAudio CoreML/ANE models are ARM-only)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.12.4+ (resolved automatically via SPM)

## Build & Run

```bash
# Compile only
swift build

# Run from the terminal (⚠ mic permission is attributed to the terminal, not Heard)
swift run Heard

# Build a .app bundle and launch it (recommended for day-to-day use)
./scripts/bundle.sh
open build/Heard.app

# Stable-signed build — required for dictation so the Accessibility grant
# persists across rebuilds. Replace "Heard Dev" with any local identity.
./scripts/bundle.sh --sign "Heard Dev"
open build/Heard.app

# Release build
./scripts/bundle.sh --release
```

> **Tip:** If dictation's Accessibility grant gets stuck after rebuilds, reset it with `tccutil reset Accessibility com.execsumo.heard` and re-grant.

## Architecture

Single-process SwiftUI menu bar app. Three scenes: a `MenuBarExtra(.window)` dropdown, a Settings `Window`, and a Speaker Naming `Window`. All persistence is JSON files under `~/Library/Application Support/Heard/`.

```
Heard/
├── Sources/
│   ├── Heard/
│   │   └── MTApp.swift               # @main, MenuBarExtra + two Window scenes
│   └── HeardCore/
│       ├── AppModel.swift            # Central state, action handlers, dictation wiring
│       ├── CoreModels.swift          # AppPhase, PipelineJob, SpeakerProfile,
│       │                             # AppSettings, HotkeyCombo, ModelKind, …
│       ├── Services.swift            # MeetingDetector, RecordingManager (AUHAL + tap),
│       │                             # PipelineProcessor, PermissionCenter,
│       │                             # TranscriptWriter, TempFileCleanup, LaunchAtLogin
│       ├── Stores.swift              # SettingsStore, SpeakerStore, PipelineQueueStore
│       ├── Views.swift               # MenuBarView, SettingsView, SpeakerNamingView
│       ├── AudioProcessing.swift     # AudioPreprocessor, VadSegmentMap
│       ├── AudioClipExtractor.swift  # Extract speaker audio clips for the naming prompt
│       ├── SpeakerAssignment.swift   # SpeakerMatcher, SegmentMerger, cosine distance
│       ├── ModelDownloadManager.swift # Pre-download & status for FluidAudio models
│       ├── DictationManager.swift    # Batch ASR + polling + stability diffing
│       ├── TextInjector.swift        # CGEvent unicode / HID / clipboard paths
│       ├── HotkeyManager.swift       # Carbon RegisterEventHotKey wrapper
│       └── RosterReader.swift        # Teams roster via AXUIElement
├── Tests/HeardTests/
│   └── TestRunner.swift              # Lightweight harness — no XCTest / no Xcode
├── scripts/
│   ├── bundle.sh                     # Build + bundle + (optional) sign
│   └── diagnose.swift                # Print what Heard sees from Teams & power assertions
├── Info.plist                        # LSUIElement, NSMicrophoneUsageDescription
├── Heard.entitlements                # Audio input only (no sandbox)
├── Package.swift                     # SPM config, FluidAudio 0.12.4+
├── spec.md                           # Product source of truth
├── handoff.md                        # Current implementation status
├── ROADMAP.md                        # Planned improvements (this doc)
└── CLAUDE.md                         # Working rules for AI assistants
```

### Targets

| Target | Kind | Purpose |
|---|---|---|
| `HeardCore` | library | All models, services, views, stores |
| `Heard` | executable | `@main` app entry, depends on `HeardCore` |
| `HeardTests` | executable | Test runner with a lightweight in-house harness |

### Key Design Decisions

- **No sandbox.** Required for `CATapDescription` app-audio tapping and `CGEvent` text injection. The entitlements file grants `audio-input` and nothing else.
- **AUHAL + private aggregate device for the tap.** `AVAudioEngine.inputNode` silently re-binds to the system default input when `prepare()` runs after a `kAudioOutputUnitProperty_CurrentDevice` change, so a standalone `kAudioUnitSubType_HALOutput` configured *before* `AudioUnitInitialize` is the only reliable path to capture from the tap's aggregate device.
- **Multi-process Teams tap.** New Teams renders audio in renderer/GPU child processes, not in the process holding the power assertion. The recorder enumerates every Teams-related CoreAudio process object and taps them all.
- **Batch ASR with polling for dictation.** Dictation reuses the same batch `AsrManager` as meeting transcription, re-running it every 0.6 s against an accumulating audio buffer. This is accurate and fast enough in practice; the stability-based injection guard (see below) prevents duplicates when the model revises earlier tokens.
- **Carbon for global hotkeys.** `RegisterEventHotKey` doesn't need Accessibility permission and survives ad-hoc rebuilds, unlike `CGEvent.tapCreate` or `NSEvent` monitors (which can't suppress events).
- **Stability-based text injection.** Only words that are identical across two consecutive dictation cycles are committed to the target app, preventing duplicates when the model revises earlier tokens.
- **Per-track transcription.** The app and mic tracks are transcribed separately, then merged by timestamp. Avoids crosstalk artifacts from a pre-mixed source.
- **Local user is the mic track.** No diarization needed to identify the local user — the mic track is always "Me" (or the name set in Settings → Speakers). The mic embedding is stored and updated silently each meeting.

## Models

All models are CoreML, loaded via [FluidAudio](https://github.com/FluidInference/FluidAudio) into `~/Library/Application Support/FluidAudio/Models/`. They auto-download on first use or can be pre-downloaded from Settings → Models.

| Kind | Model | Purpose |
|---|---|---|
| `batchVad` | Silero VAD v6 | In-memory silence trimming during preprocessing |
| `batchParakeet` | Parakeet TDT V2 0.6B | English speech-to-text for meetings and dictation |
| `diarization` | LS-EEND + WeSpeaker | Speaker segmentation + 256-d embedding extraction |
| `ctcVocabulary` | Parakeet CTC 110M | Optional CTC vocabulary boosting for custom terms |

Pipeline models stay unloaded during recording. The Models tab exposes **pipeline keep-alive** (how long meeting models stay resident after a job completes, 0 – 10 min) and a **force-unload** button. The Dictation tab has its own keep-alive slider for the dictation ASR.

## Permissions

| Permission | Purpose | When required |
|---|---|---|
| Microphone | Record the local user | Always |
| Screen Recording | Surface the Teams window title for nicer filenames | Recommended |
| Accessibility | Read Teams window title & roster, inject dictation text | Required for dictation; recommended for roster-based auto-naming |

Only Microphone is strictly required; everything else degrades gracefully. Permission status is shown inside the General tab with deep-links to the right System Settings pane.

## Data

```
~/Library/Application Support/Heard/
├── pipeline_queue.json   # Persistent job queue
├── speakers.json         # Speaker embeddings + metadata
└── recordings/           # 48 kHz WAVs, auto-cleaned after 48 h

~/Library/Application Support/FluidAudio/Models/
├── silero-vad-coreml/
├── parakeet-tdt-0.6b-v2-coreml/
├── speaker-diarization-coreml/
└── parakeet-tdt-0.6b-v2-ctc-110m-coreml/

~/Documents/Heard/        # Default transcript output (configurable)
└── 260324_Sprint_Planning.md
```

Orphan WAVs from previous crashes are cleaned on launch. Files referenced by an in-flight pipeline job are always preserved.

## Testing

```bash
swift run HeardTests
```

~35 tests covering `VadSegmentMap`, cosine distance, `SpeakerMatcher`, `SegmentMerger`, `AudioPreprocessor`, `TranscriptWriter`, `SpeakerStore`, and `PipelineQueueStore` via a lightweight in-house harness — no XCTest or Xcode required.

**Manual smoke test:** `./scripts/bundle.sh && open build/Heard.app`, enable Developer Mode in Settings → General, then use **Simulate Meeting** from the menu bar to exercise the full flow without a real Teams call.

**Diagnostics:** `swift scripts/diagnose.swift` prints what Heard sees from Teams processes and power assertions — useful for debugging detection on a specific machine.

## References

- [`spec.md`](./spec.md) — Full product specification (source of truth)
- [`handoff.md`](./handoff.md) — Current implementation status and known issues
- [`ROADMAP.md`](./ROADMAP.md) — Planned improvements and stretch ideas
- [`CLAUDE.md`](./CLAUDE.md) — Working rules for AI assistants
