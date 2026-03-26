# Meeting Transcriber

Swift package scaffold for the macOS menu bar app described in `spec.md`.

## Included

- SwiftUI menu bar app entry point
- persistent settings, speaker store, and pipeline queue
- menu bar and settings UI
- sequential post-meeting pipeline orchestration
- markdown transcript writer
- placeholder seams for Teams detection, recording, VAD, transcription, diarization, and permissions

## Notes

The Apple-only capture and CoreML model integrations from the spec are separated behind lightweight service types so the project can grow into the full implementation without reworking the app flow.
