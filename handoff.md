# Handoff

## Current Status

The app builds cleanly with `swift build` and runs as a menu bar app on macOS 15.0+. Core infrastructure is complete — meeting detection, dual-track audio capture, on-device transcription (Parakeet TDT V2), VAD (Silero), speaker diarization (LS-EEND + WeSpeaker), and speaker assignment are all functional via the FluidAudio framework. An `.app` bundle is available via `./scripts/bundle.sh`.

**Dictation feature is fully functional** — speech recognition, text injection via CGEvent unicode insertion, and global hotkey (Ctrl+Shift+D) all working. Requires building with a stable code signing identity (`./scripts/bundle.sh --sign "Heard Dev"`) so Accessibility permission persists across rebuilds.

## What's Working

### Meeting Detection
- Polls `IOPMCopyAssertionsByProcess()` every 3 seconds for Teams power assertions
- Extracts meeting title from Teams window via Accessibility API (`AXUIElement`)
- Debounce/cooldown logic lives in the pure `MeetingDetectionState` value type — 2 consecutive detections to start, 5s cooldown after end — so the state machine is driven by tests without IOKit
- Simulation mode available for testing without a real Teams call (with `isSimulated` flag to prevent polling interference)

### Audio Capture
- **App audio**: `CATapDescription` process tap on all Teams-related PIDs (main + helpers), routed through a private aggregate device + raw AUHAL, recorded to WAV
- **Microphone**: Separate `AVAudioEngine` instance recording to WAV
- Both tracks saved to `~/Library/Application Support/Heard/recordings/`
- Mic delay calibration stored per session for alignment
- 4-hour max recording duration with automatic split and re-start
- Temp file cleanup on app launch (removes stale `.wav` files older than 48 hours)
- Orphan aggregate-device cleanup on app launch (destroys any `com.execsumo.heard.tap.*` private aggregate devices left behind by a crashed recording)
- **Diagnostic logging** (`Console.app` filter `Heard:`): default output device + sample rate at start; default-output-change warnings (aggregate stays bound to original device); render-thread stats every 10s (cycles, frames, non-zero %, peak/RMS in dB, render errors); silence warnings distinguishing "no callbacks fired" (tap broken) vs "callbacks firing but all-zero samples" (likely wrong process tapped)
- **Recording self-test + one-shot recovery**: at T+2s, the monitor checks whether non-zero samples have arrived. If silent, it tears down and rebuilds the tap/aggregate/AUHAL once with fresh helper-process enumeration (catches Teams 2.0 helpers that opened audio after the initial setup). If the rebuild's self-test still fails at +2s, the recording is flagged `appAudioTapFailed` and the menu bar shows "Recording (mic only)".
- **`stopWatching` ends the active meeting**: toggling watching off mid-meeting now fires `onMeetingEnded` synchronously so the recording stops and the transcript pipeline runs (previously the snapshot was orphaned and the recording continued indefinitely). `AppModel.stopWatching` preserves the resulting `.processing` phase instead of overwriting it with `.dormant`.

### Pipeline (Fully Implemented)
- Sequential job queue with stages: queued → preprocessing → transcribing → diarizing → assigning → complete
- **Preprocessing**: Resample to 16kHz mono via `AudioConverter`, Silero VAD silence trimming, `VadSegmentMap` for timestamp remapping
- **Transcription**: Parakeet TDT V3 via `AsrManager` with 16k sample minimum guard; decoder state reset between cached jobs to prevent context bleed
- **Diarization**: `OfflineDiarizerManager` on app track only (mic track is a single known speaker, diarization was unused)
- **Speaker Assignment**: Cosine distance matching against `SpeakerStore`, confidence margin filtering, embedding diversity management
- Non-retryable errors (no audio, too short) fail immediately; transient errors retry 3x with backoff (5s, 30s, 5min) via `PipelineProcessor.executeWithRetry` (closure-driven, testable)
- Jobs persist to JSON and survive app restart. `PipelineQueueStore.prepareForResume()` runs at launch: failed jobs *and* mid-stage jobs (orphaned by a crash during `.preprocessing`/`.transcribing`/`.diarizing`/`.assigning`) are re-queued so they resume on the next pipeline run
- Pipeline fires `onPipelineIdle` callback so app phase returns to dormant
- Markdown transcript output with timestamped speaker-labeled segments

### Custom Vocabulary Boosting (Needs Migration)
- FluidAudio 0.13.6 removed `configureVocabularyBoosting` from batch `AsrManager` — it now only exists on `SlidingWindowAsrManager`
- Vocabulary terms are still stored in Settings → Transcription (and `customVocabulary` property on `DictationManager`), but are not yet applied
- Migration path: use `CtcKeywordSpotter` + `VocabularyRescorer.ctcTokenRescore()` as post-processing after batch transcription (see `TranscribeCommand.swift` in FluidAudio CLI for reference)
- CTC models (`CtcModels`, `CtcTokenizer`) are still available for this purpose; `ModelDownloadManager` still downloads them

### Model Management
- `ModelDownloadManager` pre-downloads all 4 model sets (VAD, Parakeet, Diarizer, CTC 110M) via FluidAudio
- Streaming EOU model (160ms) also downloadable from Dictation settings tab
- Status detection checks FluidAudio's actual cache paths (`~/Library/Application Support/FluidAudio/Models/`)
- Progress tracking per model during download
- Models auto-download on first meeting if not pre-downloaded

### Dictation (Fully Working)

The dictation feature captures mic audio, transcribes in real-time, and injects text into the focused app via CGEvent unicode insertion. Requires Accessibility permission granted to a stable-signed build.

#### What's built:
- **`DictationManager.swift`**: Uses batch `AsrManager` (same Parakeet TDT V2 model as meeting transcription) with a 0.6s polling loop. Accumulates mic audio in a thread-safe buffer, re-transcribes every 0.6s, diffs output to find new words. Standalone `AVAudioEngine` for mic (independent of `RecordingManager`). Model keep-alive of 120s after stop.
- **`TextInjector.swift`**: CGEvent unicode insertion via `keyboardSetUnicodeString` + `postToPid` (same approach as FluidVoice). Falls back to HID tap, then clipboard paste. All methods require Accessibility permission.
- **`HotkeyManager.swift`**: Carbon `RegisterEventHotKey` for global Ctrl+Shift+D hotkey. Does NOT require Accessibility permission. Supports configurable hotkey combos stored in `AppSettings`.
- **Global hotkey**: Working. Ctrl+Shift+D toggles dictation on/off from any app.
- **Mic capture**: Working. 48kHz → 16kHz resampling via linear interpolation in tap callback.
- **Speech recognition**: Working perfectly. Tested transcriptions: "Alright, did Claude figure it out this time? Beep bop boop.", "Is this working now?", etc.
- **Text diffing**: Working. Only injects new words, not the full retranscription.
- **UI**: Dictation settings tab with enable toggle, hotkey display, model download card, Accessibility warning, live status. Menu bar shows dictation state.

### UI
- Menu bar dropdown with status card (pulsing red while recording/dictating, orange while processing, green/yellow when watching/paused), recording timer, and quick actions
- Menu bar icons are SF Symbols with symbol effects (`recordingtape`, `record.circle` + `.breathe`, `waveform` + `.variableColor`, `exclamationmark.circle.fill`, `person.crop.circle.badge.exclamationmark`)
- Settings window (opened via `@Environment(\.openWindow)`) with 5 tabs: **General** (launch at login, auto-watch, developer mode, custom vocabulary, output folder, permissions), **Dictation** (enable, push-to-talk, hotkey recorder, model keep-alive, live status), **Models** (download status, pipeline keep-alive, force-unload), **Speakers** (your name, inline rename, merge, delete, search/sort), **About**
- Standalone "Name Speakers" window scene (id `speaker-naming`) with per-candidate audio playback, roster suggestions, and 120 s auto-dismiss
- Keyboard input works in Settings — `WindowActivationCoordinator` reference-counts `.accessory`/`.regular` transitions across the Settings and Name Speakers windows so closing one while the other is still open never steals keyboard focus
- Output folder picker via `NSOpenPanel`
- Custom vocabulary management lives in the General tab (add/remove terms, 3-char min, 50-term cap) — terms applied to both transcription and dictation via CTC boosting
- Speaker table with inline rename, merge, delete (context menu), search, and sort (Name / Last Seen / Meeting Count)
- Model download status with progress bars and per-card download buttons, plus a "Download All Models" shortcut
- Permission status with grant buttons and System Settings deep-links (Microphone + Screen Recording + Accessibility), surfaced inside the General tab
- Launch at login via `SMAppService`
- Quit button in menu bar dropdown

### Accessibility Roster Scraping
- `RosterReader.swift` reads Teams participant names via macOS Accessibility APIs (`AXUIElement`)
- Three fallback strategies: identifier-based search → container search → window title parsing (all via AX API)
- Filters out UI control strings (mute, unmute, raise hand, etc.)
- Polled every 15 seconds during active meetings to accumulate participant names
- Used for automatic speaker name assignment when diarization detects unmatched speakers

### Speaker Naming Prompt (Fully Working)
- Dedicated "Name Speakers" window opens automatically after a meeting when unmatched speakers are detected
- Each unmatched speaker shows a **playable audio clip** (~10s of their clearest speech from diarization)
- Audio playback via `AVAudioPlayer` with play/stop toggle per speaker
- Suggested names from Teams roster when available (shown as orange hint text)
- Text fields pre-populated with roster suggestions for quick confirmation
- "Save All" commits all entered names, "Skip All" saves with generic labels
- 120-second auto-dismiss countdown — saves unnamed speakers with "Speaker N" labels
- Speaker profiles created with voice embeddings from diarization, enabling future recognition
- Clip files saved to `recordings/` dir and cleaned up after naming
- `AudioClipExtractor.swift` handles WAV segment extraction from original 48kHz recordings
- Menu bar shows "Name Speakers..." button and orange badge icon during `.userAction` phase
- Window also accessible from menu bar dropdown if dismissed

### App Bundle
- `Info.plist` with `LSUIElement` (menu bar app), `NSMicrophoneUsageDescription`, bundle ID `com.execsumo.heard`
- `Heard.entitlements` with audio-input only (no sandbox per spec)
- `scripts/bundle.sh` builds via SPM, creates `.app` bundle, auto-signs with `Dev Cert` if available else ad-hoc
- Flags: `--release`, `--sign IDENTITY`, `--output DIR`, `--install` (quit running app, replace `/Applications/Heard.app`, relaunch — anchors TCC grants to a stable path), `--reset` (also `tccutil reset` Microphone/ScreenCapture/Accessibility before install — implies `--install`)

### Testing
- `HeardTests` executable target with 86 tests across: VadSegmentMap, cosine distance, SpeakerMatcher (incl. threshold/margin edge cases), SegmentMerger, AudioPreprocessor, TranscriptWriter, SpeakerStore, PipelineQueueStore, pipeline resume/recovery (`prepareForResume`), meeting detection state machine (`MeetingDetectionState`), retry executor (`PipelineProcessor.executeWithRetry`), and RosterReader (window-title parser + filter)
- Custom lightweight test harness (no XCTest/Xcode dependency). `test(...)` for sync, `testAsync(...)` for async bodies
- Run with `swift run HeardTests`

### Persistence
- `SettingsStore`: UserDefaults-backed app settings (includes `dictationEnabled`, `dictationHotkey`)
- `SpeakerStore`: JSON file at `~/Library/Application Support/Heard/speakers.json`
- `PipelineQueueStore`: JSON file at `~/Library/Application Support/Heard/queue.json`

## Architecture

| Target | Purpose |
|--------|---------|
| `HeardCore` (library) | All models, services, views, stores |
| `Heard` (executable) | App entry point, imports HeardCore |
| `HeardTests` (executable) | Test runner, imports HeardCore |

| File | Purpose |
|------|---------|
| `Package.swift` | SPM config, macOS 15.0+, FluidAudio dependency |
| `Sources/Heard/MTApp.swift` | `@main` entry, MenuBarExtra + Window scenes |
| `Sources/HeardCore/AppModel.swift` | Central state, action handlers, lifecycle, dictation wiring |
| `Sources/HeardCore/CoreModels.swift` | AppPhase, PipelineJob, SpeakerProfile, AppSettings, HotkeyCombo, etc. |
| `Sources/HeardCore/Services.swift` | MeetingDetector, RecordingManager, PipelineProcessor, PermissionCenter, TranscriptWriter, TempFileCleanup, AudioDeviceCleanup, LaunchAtLogin, WindowActivationCoordinator |
| `Sources/HeardCore/Stores.swift` | SettingsStore, SpeakerStore, PipelineQueueStore, FileManager extensions |
| `Sources/HeardCore/Views.swift` | MenuBarView, SettingsView, all tabs and components |
| `Sources/HeardCore/AudioProcessing.swift` | AudioPreprocessor, VadSegmentMap, PreprocessedTrack |
| `Sources/HeardCore/SpeakerAssignment.swift` | SpeakerMatcher, SegmentMerger, cosineDistance |
| `Sources/HeardCore/AudioClipExtractor.swift` | Extract speaker audio clips from WAV for naming prompt |
| `Sources/HeardCore/ModelDownloadManager.swift` | Pre-download manager for FluidAudio models |
| `Sources/HeardCore/DictationManager.swift` | Real-time dictation engine (batch ASR + polling loop) |
| `Sources/HeardCore/TextInjector.swift` | Text injection via CGEvent unicode insertion |
| `Sources/HeardCore/HotkeyManager.swift` | Global hotkey via Carbon RegisterEventHotKey |
| `Info.plist` | App bundle metadata |
| `Heard.entitlements` | Audio input entitlement |
| `scripts/bundle.sh` | Build + bundle script |

## Next Steps

See [`ROADMAP.md`](./ROADMAP.md) for the full list of planned improvements, organized by near-term polish, mid-term features, long-term bets, and technical debt. The highlights:

### 1. Distribution
- App icon (currently an SF Symbol placeholder in the About tab)
- CI pipeline — GitHub Actions: build, test, bundle, notarize, publish
- DMG packaging for GitHub Releases
- Homebrew Cask formula

### 2. Known rough edges
- Menu bar dropdown uses `.window` style and has a fixed max height — jobs list can clip when many jobs accumulate
- Dictation hotkey recorder accepts any combo, including ones that clash with system shortcuts
- Teams detection only matches localized app names — non-English macOS locales may miss Teams

## Attempted Approaches for Dictation (Historical)

These approaches were tried and failed, documented here to prevent re-attempting:

### Hotkey implementations (settled on Carbon)
1. **NSEvent global/local monitors**: Can observe but not suppress key events — causes macOS error sound on every hotkey press. Abandoned.
2. **CGEvent tap (`CGEvent.tapCreate`)**: Requires Accessibility permission which gets invalidated on every ad-hoc rebuild. Abandoned.
3. **Carbon `RegisterEventHotKey`**: No Accessibility permission needed. Working perfectly. This is the current implementation.

### Text injection attempts (all require Accessibility)
1. **CGEvent Cmd+V paste** (`post(tap: .cghidEventTap)`): Requires Accessibility
2. **CGEvent Cmd+V paste** (`post(tap: .cgSessionEventTap)`): Requires Accessibility
3. **AppleScript System Events**: Requires Automation permission, blocked for ad-hoc apps (error -1743)
4. **CGEvent unicode insertion** (`keyboardSetUnicodeString` + `postToPid`): Requires Accessibility — current implementation, will work once AX permission is granted

## Known Issues

- ~~**Custom vocabulary is a no-op**~~: Resolved — custom vocabulary now uses CTC-based vocabulary boosting for both pipeline transcription and dictation.
- **TCC permissions on rebuild**: macOS ties Screen Recording / Accessibility grants to the code signature *and* the bundle path. Each rebuild changes the CDHash, and a copy in `build/` is treated as a different app from one in `/Applications/`. Use `./scripts/bundle.sh --install` to anchor to `/Applications/Heard.app`, or `--reset` to also wipe TCC grants first. After granting, **fully Quit Heard from the menu bar and relaunch** — Screen Recording grants do not propagate to a process that was already running.
- Running via `swift run` in a terminal causes macOS to attribute microphone permission to the terminal app (e.g., Ghostty) rather than Heard. Use `./scripts/bundle.sh && open build/Heard.app` instead.
- The `.window` style MenuBarExtra panel has a fixed max height; if many jobs accumulate, the bottom of the panel may clip.
- Simulated meetings produce very short recordings that fail in the pipeline (expected — they exist for UI testing, not audio testing).
