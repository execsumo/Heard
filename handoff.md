# Handoff

## Current Status

The repo now contains an initial Swift package scaffold for the app in `spec.md`.

Implemented:

- Swift package setup for a macOS executable app
- SwiftUI menu bar app entry point
- central app state model
- settings persistence via `UserDefaults`
- JSON-backed speaker store
- JSON-backed pipeline queue
- menu bar dropdown UI
- settings tabs for General, Transcription, Dictation, Speakers, Permissions, and About
- basic speaker management UI
- sequential pipeline processor skeleton
- markdown transcript file writer

Not yet implemented:

- real macOS Teams meeting detection via `IOPMCopyAssertionsByProcess()`
- Teams window title extraction via `CGWindowListCopyWindowInfo()`
- real dual-track audio capture with `CATapDescription` and `AVAudioEngine`
- real microphone publisher pattern for future dictation
- model downloading into `~/Library/Application Support/MeetingTranscriber/Models/`
- VAD, transcription, diarization, embeddings, speaker assignment, and retry semantics from the spec
- launch-at-login wiring via `SMAppService`
- real permission checks and System Settings deep-links
- pending-speaker audio preview flow

## Important Context

This work was done in a Windows sandbox without the Swift toolchain or macOS frameworks available at runtime. The code was structured to reflect the app architecture and flow, but it has not been compiled here.

`swift build` could not be run in this environment because the `swift` command was not installed.

## Files To Start With

- `spec.md`: full product and architecture requirements
- `Package.swift`: package definition
- `Sources/MeetingTranscriber/MTApp.swift`: app entry
- `Sources/MeetingTranscriber/AppModel.swift`: state orchestration
- `Sources/MeetingTranscriber/Services.swift`: best place to replace stubs with real implementations
- `Sources/MeetingTranscriber/Views.swift`: current UI surface

## Recommended Next Steps On Mac

1. Open the package on macOS and make the project compile cleanly in Xcode.
2. Split the large source files into the intended subfolders if desired after the first successful build.
3. Replace `MeetingDetector` simulation with the real polling implementation from the spec.
4. Replace `RecordingManager` simulation with real app-audio and mic capture.
5. Add actual file lifecycle management for recordings and queue recovery.
6. Integrate the model download manager and real pipeline stages one at a time.
7. Replace the fake transcript generation with real segment merge/output logic.

## Suggested Implementation Order

- First compile and fix syntax or API mismatches.
- Then land real detection and recording.
- Then land persistence-safe preprocessing/transcription/diarization stages.
- Then improve settings, permissions, and speaker workflows.

## Notes For The Next Session

- The current UI includes "Simulate Meeting Start" and "Simulate Meeting End" actions to exercise the stubbed flow. Remove or hide those once real detection is in place.
- `Services.swift` currently writes a placeholder transcript with sample segments. That is intentional scaffolding.
- The architecture should continue to honor the v1/v2 separation in the spec, especially around dictation.
