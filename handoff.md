# Handoff

## Current Status

The app builds cleanly with `swift build` and runs as a menu bar app on macOS 14.2+. Core infrastructure is complete — meeting detection, dual-track audio capture, on-device transcription (Parakeet TDT V2), VAD (Silero), speaker diarization (LS-EEND + WeSpeaker), and speaker assignment are all functional via the FluidAudio framework. An `.app` bundle is available via `./scripts/bundle.sh`.

**Dictation feature is 90% complete** — speech recognition works perfectly, text injection is the sole remaining blocker (requires Accessibility permission which is invalidated by ad-hoc signing on each rebuild).

## What's Working

### Meeting Detection
- Polls `IOPMCopyAssertionsByProcess()` every 3 seconds for Teams power assertions
- Extracts meeting title from Teams window via `CGWindowListCopyWindowInfo`
- Debounce: requires 2 consecutive detections before triggering
- Cooldown: 5-second delay after meeting end before re-detection
- Simulation mode available for testing without a real Teams call (with `isSimulated` flag to prevent polling interference)

### Audio Capture
- **App audio**: `CATapDescription` process tap on the Teams PID, recorded via `AVAudioEngine` to WAV
- **Microphone**: Separate `AVAudioEngine` instance recording to WAV
- Both tracks saved to `~/Library/Application Support/Heard/recordings/`
- Mic delay calibration stored per session for alignment
- 4-hour max recording duration with automatic split and re-start
- Temp file cleanup on app launch (removes stale `.wav` files older than 48 hours)

### Pipeline (Fully Implemented)
- Sequential job queue with stages: queued → preprocessing → transcribing → diarizing → assigning → complete
- **Preprocessing**: Resample to 16kHz mono via `AudioConverter`, Silero VAD silence trimming, `VadSegmentMap` for timestamp remapping
- **Transcription**: Parakeet TDT V2 via `AsrManager` with 16k sample minimum guard
- **Diarization**: `OfflineDiarizerManager` for speaker segments + embeddings
- **Speaker Assignment**: Cosine distance matching against `SpeakerStore`, confidence margin filtering, embedding diversity management
- Non-retryable errors (no audio, too short) fail immediately; transient errors retry 3x with backoff (5s, 30s, 5min)
- Jobs persist to JSON and survive app restart; failed jobs auto-retry on relaunch
- Pipeline fires `onPipelineIdle` callback so app phase returns to dormant
- Markdown transcript output with timestamped speaker-labeled segments

### Model Management
- `ModelDownloadManager` pre-downloads all 3 batch model sets (VAD, Parakeet, Diarizer) via FluidAudio
- Streaming EOU model (160ms) also downloadable from Dictation settings tab
- Status detection checks FluidAudio's actual cache paths (`~/Library/Application Support/FluidAudio/Models/`)
- Progress tracking per model during download
- Models auto-download on first meeting if not pre-downloaded

### Dictation (Transcription Working, Injection Blocked)

The dictation feature captures mic audio, transcribes in real-time, and attempts to inject text into the focused app. **Speech-to-text works perfectly.** Text injection requires Accessibility permission which is not currently granted.

#### What's built:
- **`DictationManager.swift`**: Uses batch `AsrManager` (same Parakeet TDT V2 model as meeting transcription) with a 0.6s polling loop. Accumulates mic audio in a thread-safe buffer, re-transcribes every 0.6s, diffs output to find new words. Standalone `AVAudioEngine` for mic (independent of `RecordingManager`). Model keep-alive of 120s after stop.
- **`TextInjector.swift`**: CGEvent unicode insertion via `keyboardSetUnicodeString` + `postToPid` (same approach as FluidVoice). Falls back to HID tap, then clipboard paste. All methods require Accessibility permission.
- **`HotkeyManager.swift`**: Carbon `RegisterEventHotKey` for global Ctrl+Shift+D hotkey. Does NOT require Accessibility permission. Supports configurable hotkey combos stored in `AppSettings`.
- **Global hotkey**: Working. Ctrl+Shift+D toggles dictation on/off from any app.
- **Mic capture**: Working. 48kHz → 16kHz resampling via linear interpolation in tap callback.
- **Speech recognition**: Working perfectly. Tested transcriptions: "Alright, did Claude figure it out this time? Beep bop boop.", "Is this working now?", etc.
- **Text diffing**: Working. Only injects new words, not the full retranscription.
- **UI**: Dictation settings tab with enable toggle, hotkey display, model download card, Accessibility warning, live status. Menu bar shows dictation state.

#### What's blocked:
- **Text injection**: `AXIsProcessTrusted()` returns `false`. ALL macOS text injection methods (CGEvent `postToPid`, CGEvent HID tap, clipboard + Cmd+V, AppleScript System Events) require Accessibility permission. Ad-hoc code signing creates a new identity each rebuild, invalidating the previous Accessibility grant.

### UI
- Menu bar dropdown with status dot (pulsing red during recording), recording timer, job list with dismiss buttons
- Settings window (opened via `@Environment(\.openWindow)`) with 6 tabs: General, Transcription, Dictation, Speakers, Permissions, About
- Keyboard input works in Settings (activation policy switching)
- Output folder picker via `NSOpenPanel`
- Custom vocabulary management (add/remove terms, 3-char min, 50-term cap, immediate UI update on delete)
- Speaker table with inline rename, merge, delete (context menu), search, and sort (Name / Last Seen / Meeting Count)
- Model download status with progress bars and per-card download buttons
- Permission status with grant buttons and System Settings deep-links
- Launch at login via `SMAppService`
- Quit button in menu bar dropdown

### Accessibility Roster Scraping
- `RosterReader.swift` reads Teams participant names via macOS Accessibility APIs (`AXUIElement`)
- Three fallback strategies: identifier-based search → container search → window title parsing
- Filters out UI control strings (mute, unmute, raise hand, etc.)
- Polled every 15 seconds during active meetings to accumulate participant names
- Used for automatic speaker name assignment when diarization detects unmatched speakers

### App Bundle
- `Info.plist` with `LSUIElement` (menu bar app), `NSMicrophoneUsageDescription`, bundle ID `com.execsumo.heard`
- `Heard.entitlements` with audio-input only (no sandbox per spec)
- `scripts/bundle.sh` builds via SPM, creates `.app` bundle, ad-hoc signs
- Supports `--release` and `--sign IDENTITY` flags for distribution builds

### Testing
- `HeardTests` executable target with 30+ tests covering: VadSegmentMap, cosine distance, SpeakerMatcher, SegmentMerger, AudioPreprocessor, TranscriptWriter, SpeakerStore, PipelineQueueStore
- Custom lightweight test harness (no XCTest/Xcode dependency)
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
| `Package.swift` | SPM config, macOS 14.2+, FluidAudio dependency |
| `Sources/Heard/MTApp.swift` | `@main` entry, MenuBarExtra + Window scenes |
| `Sources/HeardCore/AppModel.swift` | Central state, action handlers, lifecycle, dictation wiring |
| `Sources/HeardCore/CoreModels.swift` | AppPhase, PipelineJob, SpeakerProfile, AppSettings, HotkeyCombo, etc. |
| `Sources/HeardCore/Services.swift` | MeetingDetector, RecordingManager, PipelineProcessor, PermissionCenter, TranscriptWriter |
| `Sources/HeardCore/Stores.swift` | SettingsStore, SpeakerStore, PipelineQueueStore, FileManager extensions |
| `Sources/HeardCore/Views.swift` | MenuBarView, SettingsView, all tabs and components |
| `Sources/HeardCore/AudioProcessing.swift` | AudioPreprocessor, VadSegmentMap, PreprocessedTrack |
| `Sources/HeardCore/SpeakerAssignment.swift` | SpeakerMatcher, SegmentMerger, cosineDistance |
| `Sources/HeardCore/ModelDownloadManager.swift` | Pre-download manager for FluidAudio models |
| `Sources/HeardCore/DictationManager.swift` | Real-time dictation engine (batch ASR + polling loop) |
| `Sources/HeardCore/TextInjector.swift` | Text injection via CGEvent unicode insertion |
| `Sources/HeardCore/HotkeyManager.swift` | Global hotkey via Carbon RegisterEventHotKey |
| `Info.plist` | App bundle metadata |
| `Heard.entitlements` | Audio input entitlement |
| `scripts/bundle.sh` | Build + bundle script |

## Next Steps

### 1. Fix Text Injection (Accessibility Permission)

**The problem**: `AXIsProcessTrusted()` returns `false` because ad-hoc code signing creates a new identity each rebuild, and macOS invalidates the Accessibility grant for the old identity.

**Solutions (pick one)**:
- **Sign with a stable Developer ID certificate** (`./scripts/bundle.sh --sign "Developer ID Application: ..."`) — this keeps the same code signing identity across rebuilds, so Accessibility permission persists. This is the correct production fix.
- **Self-signed certificate** — create a local certificate in Keychain Access, sign with it consistently. Cheaper than a Developer ID but works the same way for Accessibility. Instructions below.
- **Install to /Applications and manually re-grant** — after each rebuild, remove the old Heard entry in System Settings > Privacy & Security > Accessibility, then re-add the new build. Tedious but works for development.

**Self-signed certificate setup (one-time)**:
```bash
# 1. Open Keychain Access > Certificate Assistant > Create a Certificate
#    - Name: "Heard Dev"
#    - Identity Type: Self Signed Root
#    - Certificate Type: Code Signing
#    - Click Create

# 2. Verify it shows up:
security find-identity -v -p codesigning
# Look for "Heard Dev" in the output

# 3. Build with stable signing:
./scripts/bundle.sh --sign "Heard Dev"

# 4. Grant Accessibility once:
#    Open build/Heard.app → enable dictation → grant Accessibility when prompted
#    This grant persists across rebuilds as long as you use the same cert
```

**What NOT to try** (already attempted and ruled out):
- AppleScript `System Events` keystroke: requires Automation permission, also blocked for ad-hoc apps (error -1743)
- `CGEvent.post(tap: .cgSessionEventTap)`: still requires Accessibility
- `CGEvent.post(tap: .cghidEventTap)`: still requires Accessibility
- `NSEvent` global monitors: observe-only, can't inject
- There is no macOS text injection method that works without Accessibility permission

### 2. Clean Up Debug Logging

Remove the `dictLog()` file logger and `~/heard_dictation.log` once text injection is verified working. The `dictLog` function is in `DictationManager.swift` and referenced in `TextInjector.swift`.

### 3. Improve Dictation UX

- Remove the streaming EOU model card from the Dictation settings tab (no longer used — we use the batch Parakeet model)
- Add a visual indicator in the menu bar when dictation is active (partial transcript preview)
- Consider adding a "Record Shortcut" UI for custom hotkey binding (the button exists but the recording sheet may not be implemented)
- Tune the polling interval (currently 0.6s) and minimum sample threshold (currently 1s) based on real-world usage

### 4. FluidAudio Mel Spectrogram Bug

A patch was applied to `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioMelSpectrogram.swift` line 193: changed `let numFrames = audioCount / hopLength` to `let numFrames = 1 + audioCount / hopLength`. This fixes a frame count off-by-one for center-padded mode. This patch will be lost on `swift package clean` or `swift package resolve`. If the StreamingEouAsrManager is revisited in the future, this bug needs to be reported/fixed upstream in FluidAudio.

### 5. Other

- **App icon** — Create and include an app icon for the bundle
- **CI/CD pipeline** — GitHub Actions workflow for build, sign, notarize, publish
- **DMG packaging** — Create distributable disk image for direct download
- **Homebrew Cask formula** — For `brew install heard`

### 6. Menu Bar Icons (Pending User Input)

- We need designated custom icons/animations from the user for the following states:
  - `error` (currently falling back to `menu-bar-idle.gif`)
  - `userAction` (currently falling back to `menu-bar-idle.gif`)
  - `isDictating` (currently defaulting to `menu-bar-recording.gif`)
- **Note on GIF Animations**: SwiftUI's native `MenuBarExtra(image:)` will only render the first frame of the provided `.gif` files. If true animations (e.g. 60fps) are required in the menu bar, we need to replace `MenuBarExtra` with a custom AppKit `NSStatusItem` wrapper that manually loops via a `Timer` and updates the `button.image` frame-by-frame. This should be addressed later based on user preference.

## Attempted Approaches for Dictation (Historical)

These approaches were tried and failed, documented here to prevent re-attempting:

### StreamingEouAsrManager (abandoned)
- FluidAudio's `StreamingEouAsrManager` was the original plan for low-latency streaming ASR
- **320ms mode**: CoreML shape mismatch `(1, 128, 63) vs (1, 128, 64)` — bug in `computeFlat` mel spectrogram
- **160ms mode**: Same class of bug `(1, 128, 16) vs (1, 128, 17)`
- Root cause: `computeFlat` calculates `numFrames = audioCount / hopLength` but center-padded STFT should be `1 + audioCount / hopLength`
- Even after patching the mel bug (0 CoreML errors), the RNNT decoder produced no tokens — no partial or EOU callbacks ever fired despite correctly-shaped audio flowing through
- **Solution adopted**: Use batch `AsrManager` with 0.6s polling loop (same approach as FluidVoice app). Works perfectly.

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

- **Accessibility permission for dictation text injection**: `AXIsProcessTrusted()` returns `false` for ad-hoc signed builds because macOS invalidates the grant when the code signing identity changes. Fix: sign with a stable certificate.
- Running via `swift run` in a terminal causes macOS to attribute microphone permission to the terminal app (e.g., Ghostty) rather than Heard. Use `./scripts/bundle.sh && open build/Heard.app` instead.
- The `.window` style MenuBarExtra panel has a fixed max height; if many jobs accumulate, the bottom of the panel may clip.
- Simulated meetings produce very short recordings that fail in the pipeline (expected — they exist for UI testing, not audio testing).
- The FluidAudio `computeFlat` mel spectrogram has an off-by-one bug affecting streaming ASR. A local patch exists in `.build/checkouts/` but will be lost on package resolution.
- Debug logging (`~/heard_dictation.log`) is still active — remove before shipping.
