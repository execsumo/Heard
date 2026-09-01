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
- Treat `DESIGN.md` as the visual source of truth. Never hardcode a color, font, or corner radius in a view — use `HeardTheme.Terminal.*`, `HeardFont.*`, and `HeardTheme.Spacing`/`Stroke` from `DesignSystem.swift`. If a token is missing, add it there rather than inlining a literal.

## Current Codebase Shape

- `Package.swift` defines a macOS Swift package executable target.
- `Sources/Heard/MTApp.swift` contains the app entry point.
- `Sources/HeardCore/AppModel.swift` is the main app state container.
- `Sources/HeardCore/CoreModels.swift` holds app, pipeline, speaker, transcript, and settings models.
- `Sources/HeardCore/Stores.swift` contains persistence and file-system helpers.
- `Sources/HeardCore/Services.swift` contains the current service scaffolding for detection, recording, models, queue processing, and transcript writing.
- The UI is split across `MenuBarView.swift`, `SettingsView.swift`, `SettingsTabs.swift`, `SettingsComponents.swift`, `SpeakerNamingView.swift`, `TranscriptLibraryView.swift`, `DictationHUD.swift`, and `MeetingNoteComposer.swift`. (The old single `Views.swift` no longer exists.)
- `Sources/HeardCore/DesignSystem.swift` holds every design token and shared component, implementing the system in `DESIGN.md`.

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
