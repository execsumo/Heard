# Handoff

## Current Status

The app builds cleanly with `swift build` and runs as a menu bar app on macOS 15.0+. Core infrastructure is complete — meeting detection, dual-track audio capture, on-device transcription (Parakeet TDT V2), VAD (Silero), speaker diarization (LS-EEND + WeSpeaker), and speaker assignment are all functional via the FluidAudio framework. An `.app` bundle is available via `./scripts/bundle.sh`.

**v0.1.0 is released** — notarized DMG published to [GitHub Releases](https://github.com/execsumo/Heard/releases/tag/v0.1.0) and installable via `brew tap execsumo/heard && brew install --cask heard`.

**Dictation feature is fully functional** — speech recognition, text injection via CGEvent unicode insertion, and global hotkey (Ctrl+Shift+D) all working. Requires building with a stable code signing identity (`./scripts/bundle.sh --sign "Heard Dev"`) so Accessibility permission persists across rebuilds.

**In-meeting notes are fully functional** — global hotkey (Ctrl+Shift+N by default) opens a focused composer panel during recording; notes interleave chronologically into the rendered transcript as italicized `**Note from <userName>:**` lines. See "In-Meeting Notes" below.

## What's Working

### Meeting Detection
- Polls `IOPMCopyAssertionsByProcess()` every 3 seconds for Teams power assertions
- Extracts meeting title from Teams window via Accessibility API (`AXUIElement`)
- Debounce/cooldown logic lives in the pure `MeetingDetectionState` value type — 2 consecutive detections to start, 5s cooldown after end — so the state machine is driven by tests without IOKit
- Simulation mode available for testing without a real Teams call (with `isSimulated` flag to prevent polling interference)

### Audio Capture
- **App audio**: `CATapDescription` process tap on all Teams-related PIDs (main + helpers), routed through a private aggregate device + `AudioDeviceCreateIOProcIDWithBlock`, recorded to WAV (32-bit float non-interleaved PCM)
- **Microphone**: Separate `AVAudioEngine` instance recording to WAV
- Both tracks saved to `~/Library/Application Support/Heard/recordings/`
- Mic delay calibration stored per session for alignment
- 4-hour max recording duration with automatic split and re-start
- Temp file cleanup on app launch (removes stale `.wav` files older than 48 hours)
- Orphan aggregate-device cleanup on app launch (destroys any `com.execsumo.heard.tap.*` private aggregate devices left behind by a crashed recording)
- **Tap UID**: `tapDesc.uuid = UUID()` is set on `CATapDescription` before calling `AudioHardwareCreateProcessTap`; `tapDesc.uuid.uuidString` is used directly in the aggregate device's tap list — avoids the silent failure path of querying `kAudioTapPropertyUID` via `AudioObjectGetPropertyData` after the fact
- **IOProc instead of AUHAL**: `AudioDeviceCreateIOProcIDWithBlock` is called directly on the aggregate device (dispatched to a serial queue so CoreAudio copies buffers before dispatch). The tap delivers interleaved stereo float32; the IOProc deinterleaves into `AVAudioPCMBuffer` matching `AVAudioFile.processingFormat` (non-interleaved float32) before writing
- **Diagnostic logging** (`log show --last 1m --predicate 'process == "Heard"' --info`): default output device + sample rate at start; default-output-change warnings; IOProc stats every 10s (cycles, frames, non-zero %, peak/RMS in dB); silence warnings distinguishing "no callbacks fired" vs "callbacks firing but all-zero samples"
- **Recording self-test + one-shot recovery**: at T+2s, the monitor checks whether non-zero samples have arrived. If silent, it tears down and rebuilds the tap/aggregate/IOProc once with fresh helper-process enumeration. If the rebuild's self-test still fails, the recording is flagged `appAudioTapFailed` and the menu bar shows "Recording (mic only)".
- **`stopWatching` ends the active meeting**: toggling watching off mid-meeting fires `onMeetingEnded` synchronously so the recording stops and the transcript pipeline runs. `AppModel.stopWatching` preserves the resulting `.processing` phase instead of overwriting it with `.dormant`.
- **TCC permissions required**: Microphone (`NSMicrophoneUsageDescription`), System Audio Capture (`NSAudioCaptureUsageDescription`), Screen Recording (`NSScreenCaptureUsageDescription`), Accessibility (`NSAccessibilityUsageDescription`) — all four must be granted. Use `./scripts/bundle.sh --reset` to clear all four TCC grants and reinstall cleanly.

### Pipeline (Fully Implemented)
- Sequential job queue with stages: queued → preprocessing → transcribing → diarizing → assigning → complete
- **Preprocessing**: Resample to 16kHz mono via `AudioConverter`, Silero VAD silence trimming, `VadSegmentMap` for timestamp remapping
- **Transcription**: Parakeet TDT V2/V3 (user-selectable) via `AsrManager` with 16k sample minimum guard. Each transcribe call uses a fresh `TdtDecoderState`, so no context bleeds between tracks or jobs. Always passes `language: .english` — required by FluidAudio 0.14.x to keep v3 from emitting Cyrillic for short Latin-script utterances; ignored by v2.
- **Diarization**: `OfflineDiarizerManager` on app track only (mic track is a single known speaker, diarization was unused). Clustering parameter is user-configurable via `AppSettings.diarizationClusteringSimilarity` (default 0.65, range 0.40–0.85 in 0.05 steps; FluidAudio's library default is 0.60). FluidAudio's `OfflineDiarizerConfig(clusteringThreshold:)` is actually a cosine *similarity* — AHC merges when cos_sim ≥ threshold, so higher = stricter separation, more clusters. The 0.65 default biases toward over-splitting because merging in the Speakers tab is easier than recovering a polluted embedding.
- **Speaker Assignment**: Cosine distance matching against `SpeakerStore`, confidence margin filtering, embedding diversity management
- Non-retryable errors (no audio, too short) fail immediately; transient errors retry 3x per session with backoff (5s, 30s, 5min) via `PipelineProcessor.executeWithRetry` (closure-driven, testable)
- `retryCount` is cumulative across sessions with a lifetime cap of 6 (`PipelineProcessor.lifetimeRetryLimit`). User-initiated retry (`retryFailedJob`) resets `retryCount = 0` for a fresh budget.
- Jobs persist to JSON and survive app restart. `PipelineQueueStore.prepareForResume()` runs at launch: failed/mid-stage jobs (orphaned by crash) are re-queued if `retryCount < lifetimeRetryLimit`; jobs at/above the cap stay `.failed` until the user explicitly retries.
- Pipeline fires `onPipelineIdle` callback so app phase returns to dormant
- Markdown transcript output with timestamped speaker-labeled segments

### Custom Vocabulary Boosting
- FluidAudio 0.13.6+ removed `configureVocabularyBoosting` from batch `AsrManager` — it now only exists on `SlidingWindowAsrManager` (used by Dictation)
- Batch pipeline applies vocabulary via post-processing rescoring in `PipelineProcessor.applyVocabularyBoosting`: runs `CtcKeywordSpotter.spotKeywordsWithLogProbs` over the same 16 kHz samples to compute log-probs, then `VocabularyRescorer.ctcTokenRescore` rewrites low-confidence words from the user's `customVocabulary` against the saved `ASRResult.tokenTimings`. The rescored text replaces the original via `ASRResult.withRescoring`
- Best-effort: any failure (CTC model not downloaded, tokenizer load failure, missing tokenTimings) is logged and the original transcript is kept — vocab boosting never fails the pipeline
- Requires the user to download the CTC 110M model from the Models tab; without it, vocabulary terms are stored but not applied

### Model Management
- `ModelDownloadManager` pre-downloads all 4 model sets (VAD, Parakeet, Diarizer, CTC 110M) via FluidAudio
- Streaming EOU model (160ms) also downloadable from Dictation settings tab
- Status detection checks FluidAudio's actual cache paths (`~/Library/Application Support/FluidAudio/Models/`)
- Progress tracking per model during download
- Models auto-download on first meeting if not pre-downloaded

### In-Meeting Notes
- During an active recording, the user can press a global hotkey (default Ctrl+Shift+N, configurable in Settings → General → Meeting Notes) to open a small floating composer panel.
- Composer is an `NSPanel` subclass overriding `canBecomeKey` so the text editor takes focus immediately; first keystroke goes into the field. Return saves, Cmd+Return inserts a newline, Esc cancels. The text field is a custom `NSViewRepresentable` (`NoteTextEditor`/`NoteNSTextView`) that intercepts key events at the AppKit level — SwiftUI's `onKeyPress` is not used because `TextEditor`'s underlying `NSTextView` consumes Return before SwiftUI sees it.
- The note's recording-relative timestamp is captured at panel-open time (not submit time), so a slow typer's note still anchors to when they reacted.
- Notes are stored on `RecordingSession.notes` while the meeting is in progress; carried into the `PipelineJob` when recording stops; persisted in `pipeline_queue.json` (with backwards-compat decoding for pre-feature queue files).
- If the user submits *after* the meeting has ended, `PipelineProcessor.attachNoteToFinishedJob(at:text:)` finds the matching enqueued/processing job by wall-clock time and attaches there instead.
- `TranscriptWriter.renderBody` interleaves notes with spoken segments by timestamp and renders them as `[mm:ss] _**Note from <userName>:** ...text..._` (italicized, distinct from `**Speaker:**` blocks). Empty `userName` falls back to `Me` — same convention as the mic-track speaker label.
- `HotkeyManager` was refactored to support multiple hotkeys: each manager owns a unique `id` (1 = dictation, 2 = notes), all sharing one Carbon event handler that dispatches by `EventHotKeyID`.
- Hotkey-pressed with no active recording: opens a standalone composer (no elapsed-time offset shown). On save, writes a Markdown file named `yyyy-MM-dd_HH-mm-ss_note.md` to the user's configured output folder. Write failures surface as `errorMessage` + a beep.

### Dictation (Fully Working)

The dictation feature captures mic audio, transcribes in real-time, and injects text into the focused app via CGEvent unicode insertion. Requires Accessibility permission granted to a stable-signed build.

#### What's built:
- **`DictationManager.swift`**: Uses `SlidingWindowAsrManager` (FluidAudio's proper streaming ASR) with the `.streaming` config preset. Audio is passed as `AVAudioPCMBuffer` directly via `streamAudio()`; the manager handles overlapping windows, format conversion, and stable/volatile split internally. Confirmed text is injected incrementally via `injectDelta`; any unconfirmed volatile text is flushed on stop via `finish()`. Standalone `AVAudioEngine` for mic (independent of `RecordingManager`). Model keep-alive of 120s after stop. Custom vocabulary boosting is wired via `configureVocabularyBoosting()` when CTC models are downloaded. Punctuation normalization (ITN) is applied natively to deltas before text injection.
- **Auto-pause on meeting start**: `AppModel.stopDictationIfActive()` is called from `onMeetingStarted` before recording begins. This prevents the dictation mic engine from picking up remote participants' audio through speakers and injecting it as text into the focused app. Dictation does not auto-resume when the meeting ends — the user must restart it manually.
- **Push-to-talk race condition fixed**: `AppModel` tracks a `pushToTalkKeyHeld` flag (set on press, cleared on release). After `DictationManager.start()` completes (which can take several seconds on first use due to model loading), `toggleDictation()` checks whether the key is still held. If the key was released before loading finished, dictation is stopped immediately, preventing it from becoming stuck on.
- **`TextInjector.swift`**: CGEvent unicode insertion via `keyboardSetUnicodeString` + `postToPid` (same approach as FluidVoice). Falls back to HID tap, then clipboard paste. All methods require Accessibility permission.
- **`HotkeyManager.swift`**: Carbon `RegisterEventHotKey` for global Ctrl+Shift+D hotkey. Does NOT require Accessibility permission. Supports configurable hotkey combos stored in `AppSettings`. Function keys (F1–F20) are allowed as hotkeys without a modifier key — the `HotkeyRecorderView` validator skips the modifier-required check for function key codes.
- **Global hotkey**: Working. Ctrl+Shift+D toggles dictation on/off from any app.
- **Mic capture**: Working. Tap installed at the bus's native format; one `AVAudioConverter` handles both stereo→mono downmix and any-rate→16 kHz resampling in the callback (proper polyphase filter, not linear interpolation).
- **Speech recognition**: Working perfectly. Tested transcriptions: "Alright, did Claude figure it out this time? Beep bop boop.", "Is this working now?", etc.
- **Text diffing**: Working. Only injects new words, not the full retranscription.
- **UI**: Dictation settings tab with enable toggle, hotkey display, model download card, Accessibility warning, live status. Menu bar shows dictation state.

### UI
- **Paper design system** — full visual reskin applied. 20-token warm "Paper" palette (`bg #F5EFE4`, `surface #FBF7EF`, `surfaceAlt #EFE7D7`, `sidebar #EBE2CE`, `accent #3F5C8C`, `good/warn/bad` soft tints, dark recording strip `recordingBg #2E3338`). All windows and sheets force light-only appearance via `preferredColorScheme(.light)`.
- **Custom sidebar** — `NavigationSplitView` replaced with a manual `HStack` (188 px sidebar + detail pane) for full color control. `HeardMark` squircle glyph (Canvas-drawn: warm gradient bg, dark bubble, three-dot motif) in sidebar header and About tab.
- **Card-based settings layout** — `SettingsCard`/`CardRow`/`ToggleRow` primitives replace `Form`/`.formStyle(.grouped)`. `HeardToggleStyle` (30×18 px pill, accent on / muteSoft off). `StatusDot` with 13 px glow-ring pulse animation.
- Menu bar dropdown (268 px wide) with status card (dark `#2E3338` bg while recording/dictating, Paper bg otherwise), recording timer, and quick actions
- Menu bar icons are SF Symbols with symbol effects (`recordingtape`, `record.circle` + `.breathe`, `waveform` + `.variableColor`, `exclamationmark.circle.fill`, `person.crop.circle.badge.exclamationmark`)
- **Menu bar reactivity fix**: `MenuBarView` holds direct `@ObservedObject` subscriptions to `queueStore`, `recordingManager`, `pipelineProcessor`, and `meetingDetector` — required because `MenuBarExtra(.window)` does not reliably re-render from forwarded child-store `objectWillChange` events. `MeetingDetector` is now an `ObservableObject` with `@Published isWatching`; `MenuBarIcon` subscribes directly so the paused/dimmed state reflects toggles immediately. `PipelineProcessor.runNextIfNeeded` also recovers orphaned non-terminal jobs (left in mid-stage when the processor is idle) by re-queuing them, charging a retry against the lifetime cap.
- Settings window (880×600, opened via `@Environment(\.openWindow)`) with 6 tabs: **General** (launch at login, auto-watch, developer mode, custom vocabulary, output folder, permissions, meeting notes hotkey), **Transcription** (model download status, pipeline keep-alive, force-unload), **Dictation** (enable, push-to-talk, hotkey recorder, model keep-alive, custom formatting commands, live status), **Speakers** (your name, inline rename, merge, delete, search/sort), **Advanced** (diarization clustering threshold slider with "More speakers" ↔ "Fewer speakers" labels, live numeric readout, reset-to-default), **About**
- Standalone "Name Speakers" window scene (id `speaker-naming`, 560×520) with per-candidate audio playback, roster suggestions, and 120 s auto-dismiss
- Keyboard input works in Settings — `WindowActivationCoordinator` reference-counts `.accessory`/`.regular` transitions across the Settings and Name Speakers windows so closing one while the other is still open never steals keyboard focus
- Output folder picker via `NSOpenPanel`
- Custom vocabulary management lives in the General tab (add/remove terms, 3-char min, 50-term cap) — terms applied to both transcription and dictation via CTC boosting
- Custom formatting commands live in the Dictation tab (map spoken phrases like "new paragraph" to written text like `\n\n`) — applied to both transcription and dictation via ITN rules
- Speaker table with inline rename, merge, delete (context menu), search, and sort (Name / Last Seen / Meeting Count); a leading **Voice** column has a play/stop button that replays the speaker's saved voice clip via a shared `SpeakerClipController` so only one clip plays at a time
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
- **"Save & Close"** commits all entered names and dismisses the window via `dismissWindow(id: "speaker-naming")`; **"Skip All"** saves remaining unnamed speakers with `Speaker N` labels and dismisses
- **"Multiple speakers" discard**: a per-row button (and context-menu entry) drops the candidate without creating a `SpeakerProfile`, keeping the speaker database clean when diarization merged two voices into one cluster. Temporary audio clips are deleted immediately. The transcript retains the UUID placeholder label; the user can rename it manually in the Markdown file.
- 120-second auto-dismiss countdown — saves unnamed speakers with "Speaker N" labels
- Speaker profiles created with voice embeddings from diarization, enabling future recognition
- **No duplicate "Speaker N" profiles**: `SpeakerMatcher.updateDatabase` only refreshes already-matched profiles. Roster-auto-assigned new speakers get a profile with the resolved name in `runSpeakerAssignment`. Unresolved new speakers are persisted exactly once — by `saveSpeakerName` (real name) or `skipNaming`/auto-dismiss (`Speaker N`).
- **Globally unique "Speaker N" numbering**: `SpeakerStore` previously used a monotonic counter, but now assigns unique `UUID`-based placeholders (e.g. `Speaker_1AB23C`). This avoids collisions entirely across installations and ensures renaming safely affects only the right transcripts.
- **Transcript files are rewritten with real names**: `NamingCandidate` carries the meeting's `transcriptPath`. `saveSpeakerName` calls `TranscriptWriter.renameSpeakerInDirectory(_:from:to:)` to scan every `.md` in the configured output directory and rewrite both `**Speaker N:**` body tags and the `**Participants:**` header line. With UUID-based placeholder numbers this safely catches and updates old transcripts.
- **Cumulative transcription stats**: Every time the pipeline successfully assigns speakers to speech segments, `SpeakerStore` accurately accumulates that speaker's `totalSpeechDuration` and `totalWordCount`, visible in the Settings tab.
- **Clips persist for replay**: clips are extracted to `recordings/` during the prompt, then moved to the persistent `speaker_clips/` directory by `AudioClipExtractor.persistClip` when the user saves (or skips) and stored on `SpeakerProfile.audioClipURLs`. They survive the 48-hour stale-recording cleanup and power the play button in the Speakers settings tab. Deleting a speaker also deletes its persisted clips.
- `AudioClipExtractor.swift` handles WAV segment extraction from original 48kHz recordings
- Menu bar shows "Name Speakers..." button and orange badge icon during `.userAction` phase
- Window also accessible from menu bar dropdown if dismissed

### App Bundle
- `Info.plist` with `LSUIElement` (menu bar app), `NSMicrophoneUsageDescription`, bundle ID `com.execsumo.heard`, `CFBundleIconFile = AppIcon`
- `Heard.entitlements` with audio-input only (no sandbox per spec)
- `Resources/AppIcon.iconset/` ships 16/32/128/256/512 PNG pairs; `bundle.sh` runs `iconutil -c icns` to compile `AppIcon.icns` into the bundle. Settings → About displays the real bundle icon via `NSApp.applicationIconImage`
- `scripts/bundle.sh` builds via SPM, creates `.app` bundle, auto-signs with `Dev Cert` if available else ad-hoc. When `--sign` is a `Developer ID Application:` cert, automatically adds `--options runtime --timestamp` (required for notarization); self-signed local certs are left unchanged.
- Flags: `--release`, `--sign IDENTITY`, `--output DIR`, `--install` (quit running app, replace `/Applications/Heard.app`, relaunch — anchors TCC grants to a stable path), `--reset` (also `tccutil reset` Microphone/ScreenCapture/Accessibility before install — implies `--install`)
- `scripts/dmg.sh` — distribution pipeline: release build → zip → notarize `.app` via `xcrun notarytool` → staple → create DMG with `/Applications` symlink → sign DMG → notarize DMG → staple DMG → print SHA256. Uses `--keychain-profile heard-notary` (stored via `notarytool store-credentials`). Pass `--skip-notarize` for local testing.
- **v0.1.0 released**: `dist/Heard-0.1.0.dmg` (notarized, stapled). GitHub Release at `github.com/execsumo/Heard/releases/tag/v0.1.0`. Homebrew tap at `github.com/execsumo/homebrew-heard` (`brew tap execsumo/heard && brew install --cask heard`).

### Testing
- `HeardTests` executable target with 100 tests across: VadSegmentMap, cosine distance, SpeakerMatcher (incl. threshold/margin edge cases), SegmentMerger, AudioPreprocessor, TranscriptWriter, SpeakerStore, PipelineQueueStore, pipeline resume/recovery (`prepareForResume`), meeting detection state machine (`MeetingDetectionState`), retry executor (`PipelineProcessor.executeWithRetry`) incl. lifetime cap, Teams identification, MeetingDetector lifecycle, and RosterReader (window-title parser + filter)
- Custom lightweight test harness (no XCTest/Xcode dependency). `test(...)` for sync, `testAsync(...)` for async bodies
- Run with `swift run HeardTests`

### Persistence
- `SettingsStore`: UserDefaults-backed app settings (includes `dictationEnabled`, `dictationHotkey`, `speakerRetentionDays`)
- `SpeakerStore`: JSON file at `~/Library/Application Support/Heard/speakers.json` — `SpeakerProfile` now carries an optional `audioClipURL` pointing into `speaker_clips/`
- `PipelineQueueStore`: JSON file at `~/Library/Application Support/Heard/queue.json`
- `~/Library/Application Support/Heard/speaker_clips/`: persistent voice samples for replay (kept beyond the 48-hour `recordings/` cleanup)

### Speaker Archive
- `SpeakerStore.archiveInactiveSpeakers(retentionDays:)` deletes profiles whose `lastSeen` is older than N days (and their audio clips). Called at app launch via `AppModel.bootstrap()`.
- Default is 90 days; configurable via `AppSettings.speakerRetentionDays` (0 = never). UI in Advanced → Speaker Archive (Picker: Never / 30 / 60 / 90 / 180 / 365 days).
- Also fixed a pre-existing extraneous `}` in `Views.swift` that was causing the file to fail to compile (struct `SettingsView` was closing one brace too early, pushing pane-helper functions out of scope).

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
| `Sources/HeardCore/HotkeyManager.swift` | Global hotkey via Carbon RegisterEventHotKey (multi-hotkey registry, dispatched by `EventHotKeyID`) |
| `Sources/HeardCore/MeetingNoteComposer.swift` | Floating `NSPanel` composer for in-meeting notes |
| `Info.plist` | App bundle metadata |
| `Heard.entitlements` | Audio input entitlement |
| `scripts/bundle.sh` | Build + bundle script (auto-enables hardened runtime for Developer ID certs) |
| `scripts/dmg.sh` | Release DMG pipeline: build, sign, notarize, staple, package |

## Next Steps

See [`ROADMAP.md`](./ROADMAP.md) for the full list of planned improvements, organized by near-term polish, mid-term features, long-term bets, and technical debt. The highlights:

### 1. Distribution (done for v0.1.0)
- ✅ DMG packaging — `scripts/dmg.sh` (build, sign, notarize, staple, package)
- ✅ GitHub Release — `github.com/execsumo/Heard/releases/tag/v0.1.0`
- ✅ Homebrew Cask — `brew tap execsumo/heard && brew install --cask heard`
- ✅ CI pipeline — `.github/workflows/ci.yml` builds + tests on all pushes; on tag push, builds a release bundle, zips with `ditto`, and uploads to GitHub Releases via `softprops/action-gh-release`. Notarization is stubbed (commented) pending Apple Developer secrets (`APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`).
- ✅ Update checker — `UpdateChecker` polls `api.github.com/repos/execsumo/Heard/releases/latest` at startup (rate-limited to once per 24 hours). When a newer version is detected, a banner appears in the menu bar dropdown and in Settings → About with a link to the GitHub release. No new dependencies; no auto-install (user re-runs the DMG or `brew upgrade --cask heard`).

### 2. Known rough edges
- Menu bar dropdown uses `.window` style and has a fixed max height — jobs list can clip when many jobs accumulate
- Dictation does not auto-resume after a meeting ends (auto-pauses on meeting start; user must restart manually)
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

- ~~**Custom vocabulary is a no-op**~~: Resolved — dictation uses `SlidingWindowAsrManager.configureVocabularyBoosting`; batch transcription uses post-processing CTC rescoring (`CtcKeywordSpotter` + `VocabularyRescorer.ctcTokenRescore` + `ASRResult.withRescoring`) inside `PipelineProcessor.applyVocabularyBoosting`. Both require the CTC 110M model to be downloaded.
- **TCC permissions on rebuild**: macOS ties Screen Recording / Accessibility grants to the code signature *and* the bundle path. Each rebuild changes the CDHash, and a copy in `build/` is treated as a different app from one in `/Applications/`. Use `./scripts/bundle.sh --install` to anchor to `/Applications/Heard.app`, or `--reset` to also wipe TCC grants first. After granting, **fully Quit Heard from the menu bar and relaunch** — Screen Recording grants do not propagate to a process that was already running.
- Running via `swift run` in a terminal causes macOS to attribute microphone permission to the terminal app (e.g., Ghostty) rather than Heard. Use `./scripts/bundle.sh && open build/Heard.app` instead.
- The `.window` style MenuBarExtra panel has a fixed max height; if many jobs accumulate, the bottom of the panel may clip.
- Simulated meetings produce very short recordings that fail in the pipeline (expected — they exist for UI testing, not audio testing).
