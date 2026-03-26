# Handoff

## Current Status

The app builds cleanly with `swift build` and runs as a menu bar app on macOS 14.2+. Core infrastructure is complete — meeting detection, audio capture, and the full UI are functional. Pipeline stages (transcription, diarization) are stubbed pending CoreML model integration.

## What's Working

### Meeting Detection
- Polls `IOPMCopyAssertionsByProcess()` every 3 seconds for Teams power assertions
- Extracts meeting title from Teams window via `CGWindowListCopyWindowInfo`
- Debounce: requires 2 consecutive detections before triggering
- Cooldown: 30-second delay after meeting end before re-detection
- Simulation mode available for testing without a real Teams call

### Audio Capture
- **App audio**: `CATapDescription` process tap on the Teams PID, recorded via `AVAudioEngine` to WAV
- **Microphone**: Separate `AVAudioEngine` instance recording to WAV
- Both tracks saved to `~/Library/Application Support/MeetingTranscriber/recordings/`
- Mic delay calibration stored per session for alignment
- Temp file cleanup on app launch (removes stale `.wav` files older than 24 hours)

### Pipeline
- Sequential job queue with stages: queued → preprocessing → transcribing → diarizing → assigning → complete
- Jobs persist to JSON and survive app restart
- Failed jobs can be retried (up to 3 attempts)
- Jobs can be dismissed from the queue with associated audio file cleanup
- Currently writes a placeholder markdown transcript (real stages are stubbed)

### UI
- Menu bar dropdown with status dot, recording timer, job list, and action buttons
- Settings window with 6 tabs: General, Transcription, Dictation, Speakers, Permissions, About
- Output folder picker via `NSOpenPanel`
- Custom vocabulary management (add/remove terms, 4-char min, 50-term cap)
- Speaker table with inline rename, merge, delete, search, and sort
- Model download status display (ready for real download manager)
- Permission status with grant buttons and System Settings deep-links
- Launch at login via `SMAppService`

### Persistence
- `SettingsStore`: UserDefaults-backed app settings
- `SpeakerStore`: JSON file at `~/Library/Application Support/MeetingTranscriber/speakers.json`
- `PipelineQueueStore`: JSON file at `~/Library/Application Support/MeetingTranscriber/queue.json`

## What's Stubbed

### Pipeline Stages
All pipeline stages in `PipelineProcessor.processJob()` currently simulate work with delays and produce a placeholder transcript. The real implementations need:

1. **Preprocessing**: Load WAV, downmix to mono, resample to 16kHz, VAD trimming
2. **Transcription**: Run Parakeet TDT V2 CoreML model on preprocessed audio
3. **Diarization**: Run LS-EEND + WeSpeaker CoreML models for speaker segments
4. **Speaker Assignment**: Match diarization embeddings against `SpeakerStore` profiles

### Model Download Manager
`ModelDownloadManager` has the interface but `downloadAllModels()` is a no-op. Needs:
- URLs for CoreML model files (Silero VAD, Parakeet TDT, LS-EEND, WeSpeaker)
- Download with progress tracking to `~/Library/Application Support/MeetingTranscriber/Models/`
- Checksum verification

### CoreML Models
The models referenced in `spec.md` (Parakeet TDT V2, Silero VAD v6, LS-EEND, WeSpeaker) are not available as pre-built CoreML packages. They exist as PyTorch/ONNX and need conversion via `coremltools`.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `Package.swift` | ~20 | Package definition, macOS 14.2+, FluidAudio dependency |
| `MTApp.swift` | ~20 | App entry, MenuBarExtra + Settings scenes |
| `AppModel.swift` | ~240 | Central state, action handlers, lifecycle |
| `CoreModels.swift` | ~120 | AppPhase, PipelineJob, SpeakerProfile, AppSettings, etc. |
| `Services.swift` | ~600 | MeetingDetector, RecordingManager, PipelineProcessor, PermissionCenter |
| `Stores.swift` | ~180 | SettingsStore, SpeakerStore, PipelineQueueStore, FileManager extensions |
| `Views.swift` | ~470 | MenuBarView, SettingsView, all tabs and components |

## Next Steps

1. **Convert CoreML models** — Use `coremltools` (Python) to convert Parakeet TDT, Silero VAD, LS-EEND, and WeSpeaker from PyTorch/ONNX to `.mlpackage` format
2. **Implement real preprocessing** — WAV loading, mono downmix, 16kHz resample, VAD trim using Silero
3. **Implement real transcription** — Load Parakeet TDT CoreML model, run inference, extract timestamped segments
4. **Implement real diarization** — Run LS-EEND for speaker change detection, WeSpeaker for embeddings
5. **Implement speaker assignment** — Match embeddings against SpeakerStore, create NamingCandidates for unknowns
6. **Wire up model download manager** — Host models, implement download with progress, checksum verification
7. **Build .app bundle** — Package as a proper macOS app for distribution (currently runs as a Swift package executable)

## Known Issues

- Running via `swift run` in a terminal causes macOS to attribute microphone permission to the terminal app (e.g., Ghostty) rather than Meeting Transcriber itself. This resolves when packaged as a `.app` bundle.
- The `.window` style MenuBarExtra panel has a fixed max height; if many jobs accumulate, the bottom of the panel may clip.
- FluidAudio is listed as a dependency but its actual integration is pending model availability.
