# Heard — Roadmap

A living list of known issues, technical debt, and core constraints. 

To preserve the focus, performance, and simplicity of Heard as a lean, native, single-process on-device app, we have explicitly pruned speculative enhancements (such as manual speaker splitting, alternative formats, live captions, or visual onboarding wizards) in favor of keeping the core tool highly polished and reliable.

## Technical Debt & Known Issues

These represent the remaining areas of focus to clean up and stabilize:

### Active Tech Debt & Known Issues
- **Watchdog abort can leak a zombie pipeline task.** `PipelineProcessor.abortAndFailCurrentJob` cancels the pipeline task and starts the next job, but FluidAudio may not honor cancellation promptly. A stuck transcribe/diarize call that eventually returns will write into the shared per-job state (`appTrack`, `appTranscription`, `appDiarization`, `transcriptionProgress`) while the next job is using it. Fix: tag each run with a generation/job ID and have stage write-backs verify they still own the current generation before mutating shared state.
- **App-audio self-test rebuild invalidates `micDelaySeconds`.** `attemptAppAudioRebuild` truncates and reopens the app WAV ~2–4 s after the original start and updates `appStartTime`, but the session's `micDelaySeconds` was computed once in `startRecording` and never recalculated. After a rebuild, mic/app track alignment is off by the rebuild delay, which skews `SegmentDeduplicator.dropMicBleed` and segment interleaving. Fix: recompute the delay (or store a rebuild offset on the session) after a successful rebuild.
- **PermissionCenter republishes identical state every 3 s.** `refresh()` builds a fresh `statuses` array on every poll tick, so every observing view re-renders 20×/minute for the app's lifetime even when nothing changed — plus a system-wide AX IPC call per tick while Accessibility is ungranted. Fix: make `PermissionStatus` equatable and only assign when the array actually changed. Related: the detector polls at 1 s while the docs (CLAUDE.md/handoff.md) say 3 s — reconcile the cadence or the docs.
- **In-meeting note editing.** Today the user edits notes by opening the rendered `.md` directly. A future polish: a "Notes" disclosure on each completed job in the menu bar dropdown that lists captured notes and lets the user edit/delete before the transcript is finalized (or rewrite the `.md` if it's already been written).
- **`Views.swift` size.** All SwiftUI UI components live in a single ~1.9 kLOC file after the Paper design system was implemented. Split this by tab or view area to improve build times and maintenance once early UI iteration is finished.
- **Menu bar dropdown height clipping.** The menu bar dropdown uses `.window` style and has a fixed max height. The jobs list can clip when many jobs accumulate.
- **Dictation auto-resume.** Dictation does not auto-resume after a meeting ends (it auto-pauses when a meeting starts to avoid injecting audio, but the user must restart it manually).
- **Teams detection localization.** Teams detection currently matches localized app names; non-English macOS system locales might fail to detect Teams meetings.

### Completed Technical Debt & Polish
- ~~**`SlidingWindowAsrConfig` doesn't expose `TdtConfig`.**~~ Done — FluidAudio updated to 0.14.7. We now pass the explicit `TdtConfig(blankId: modelVersion.blankId)` when initializing `SlidingWindowAsrManager` inside `DictationManager.start()`, avoiding reliance on internal blank-token auto-adaptation.
- ~~**DMG packaging.**~~ Done — `scripts/dmg.sh` builds, signs, notarizes, and packages.
- ~~**Homebrew Cask.**~~ Done — `brew tap execsumo/heard && brew install --cask heard`.
- ~~**CI publish step.**~~ Done — on tag push, CI builds a release bundle, zips it, and uploads to GitHub Releases.
- ~~**Update checker.**~~ Done — lightweight GitHub Releases poll on startup (24h interval). Shows banner in menu bar dropdown and Settings when a newer version is available.
- ~~**Preprocessing concurrency guard.**~~ Done — "Low Memory Mode" toggle in Settings → Advanced → Memory serializes preprocessing to halve peak RAM (~400 MB vs ~800 MB).
- ~~**Bulk-delete / archive old speakers.**~~ Done — automatic deletion at launch based on `speakerRetentionDays` setting (default 90 days), configurable in Advanced → Speaker Archive. Set to 0 to disable.

## Non-goals (from spec.md)

These are intentional exclusions. Do not add them without a formal spec update.

- LLM integration (no Claude, OpenAI, or local LLMs)
- Cloud APIs of any kind (Heard is 100% local)
- Google Meet support (browser-tab; no per-meeting power assertion to detect)
- Manual app recording (arbitrary app target selection)
- System-wide audio capture
- Multiple output formats beyond Markdown (no plain `.txt`, `.srt`, VTT, or HTML)
- Configurable VAD threshold or speaker count
- macOS notifications
- Live captions or live speaker ID during meetings
- Batch import of existing recordings
- Pre-release update channels
- Dictation voice commands (`"scratch that"`, `"new paragraph"`) and spoken punctuation (ITN rules handle basic spacing/lines)
- Complex manual speaker splitting or re-clustering tools
