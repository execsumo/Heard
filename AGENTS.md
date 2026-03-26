# AGENTS

## Purpose

This repository is building the macOS menu bar app described in `spec.md`.

Future Codex sessions should treat `spec.md` as the product source of truth and `handoff.md` as the current execution snapshot.

## Working Rules

- Preserve the architecture and scope in `spec.md` unless the user explicitly changes it.
- Prefer implementing the real macOS-native path rather than adding alternate cross-platform abstractions that are not in the spec.
- Keep the app as a single-process menu bar application.
- Do not introduce cloud APIs, LLM integrations, or non-English transcription support.
- Keep v1 focused on post-meeting transcription. Dictation remains placeholder scaffolding for v2.

## Current Codebase Shape

- `Package.swift` defines a macOS Swift package executable target.
- `Sources/MeetingTranscriber/MTApp.swift` contains the app entry point.
- `Sources/MeetingTranscriber/AppModel.swift` is the main app state container.
- `Sources/MeetingTranscriber/CoreModels.swift` holds app, pipeline, speaker, transcript, and settings models.
- `Sources/MeetingTranscriber/Stores.swift` contains persistence and file-system helpers.
- `Sources/MeetingTranscriber/Services.swift` contains the current service scaffolding for detection, recording, models, queue processing, and transcript writing.
- `Sources/MeetingTranscriber/Views.swift` contains the current menu bar and settings UI.

## Expectations For Future Sessions

- Read `handoff.md` before making changes.
- Update `handoff.md` after substantial implementation work, especially when macOS-specific integrations land.
- When replacing stubs with real implementations, keep the user-facing flow intact:
  - detect meeting
  - record app + mic audio
  - enqueue job
  - process sequentially
  - write markdown transcript
- Avoid broad refactors unless they directly help deliver the next real integration step.

## Priority Order

1. Make the project build and run on macOS with Xcode/Swift installed.
2. Replace simulated meeting detection with the real Teams/power assertion implementation.
3. Replace simulated recording with real dual-track capture.
4. Integrate model download and pipeline stages.
5. Refine permissions, speaker naming, and transcript quality details.
