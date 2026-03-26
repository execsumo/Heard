# Lurk

macOS menu bar app that automatically detects Microsoft Teams meetings, records dual-track audio (app + mic), and produces on-device transcripts with speaker diarization. No cloud, no LLM, no external APIs.

## Features

- **Auto-detection**: Polls `IOPMCopyAssertionsByProcess()` to detect active Teams meetings without Accessibility permissions
- **Dual-track recording**: Captures app audio via `CATapDescription` process tap and microphone via `AVAudioEngine`
- **On-device pipeline**: Sequential preprocessing → transcription → diarization → speaker assignment
- **Speaker management**: Persistent speaker profiles with embedding-based identification, rename, and merge
- **Markdown output**: Timestamped transcripts with speaker labels saved to a configurable folder
- **Menu bar UI**: Status indicator, recording timer, job queue, settings window with 6 tabs

## Requirements

- macOS 14.2+
- Swift 5.9+
- FluidAudio framework (for transcription/VAD/diarization models)

## Build & Run

```bash
swift build
swift run
```

The app appears as a menu bar icon. Click it to access controls, or use ⌘, for Settings.

## Architecture

Single-process SwiftUI menu bar app (`MenuBarExtra` with `.window` style).

| File | Purpose |
|------|---------|
| `MTApp.swift` | App entry point, scene setup |
| `AppModel.swift` | Central state orchestration |
| `CoreModels.swift` | Data types (phases, jobs, speakers, settings) |
| `Services.swift` | Meeting detection, audio capture, pipeline processing, permissions |
| `Stores.swift` | JSON persistence, file system helpers |
| `Views.swift` | Menu bar dropdown and settings window UI |

## Current State

**Working:**
- Meeting detection via power assertions (Teams process polling)
- Dual-track audio capture (app tap + mic recording to WAV)
- Microphone permission request and screen recording/accessibility deep-links
- Launch at login via `SMAppService`
- Settings persistence, speaker store, pipeline queue (all JSON-backed)
- Full settings UI (General, Transcription, Dictation, Speakers, Permissions, About)
- Recording timer, job dismiss, folder picker, custom vocabulary management
- Simulate meeting flow for testing without a real Teams call

**Stubbed (awaiting CoreML models):**
- Preprocessing (VAD trimming, resampling)
- Transcription (Parakeet TDT V2)
- Diarization (LS-EEND + WeSpeaker)
- Speaker embedding extraction and assignment

## Permissions

| Permission | Why | Required |
|-----------|-----|----------|
| Microphone | Record local audio | Yes |
| Screen Recording | Tap app audio via process tap | For app audio |
| Accessibility | Window title extraction | Optional |

## References

- `spec.md` — Full product and architecture specification
- `handoff.md` — Current implementation status and next steps
