# Heard — Roadmap

A living list of planned improvements and stretch ideas. Ordered by how close each item is to the current scope of `spec.md`. Anything that would change the product (cloud APIs, LLM integration, non-English transcription, Google Meet support) belongs in [What's explicitly NOT in scope](#whats-explicitly-not-in-scope) unless the spec itself changes.

## Near-term — polish & stability

These land inside the existing v1 scope and mostly tighten things the user already sees.

### Distribution & install
- ~~**DMG packaging.**~~ Done — `scripts/dmg.sh` builds, signs, notarizes, and packages. v0.1.0 DMG published to GitHub Releases.
- ~~**Homebrew Cask.**~~ Done — `brew tap execsumo/heard && brew install --cask heard` ([tap repo](https://github.com/execsumo/homebrew-heard)).
- ~~**CI publish step.**~~ Done — on tag push, CI builds a release bundle, zips it with `ditto`, and uploads to GitHub Releases via `softprops/action-gh-release`. Notarization is stubbed out (commented step) pending Apple Developer secrets (`APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`).
- ~~**Update checker.**~~ Done — lightweight GitHub Releases poll on startup (24h interval). Shows banner in menu bar dropdown and Settings → About when a newer version is available; links directly to the GitHub release page. No auto-install — user re-runs the DMG or `brew upgrade --cask heard`.


### Meeting detection & recording
- **Audible meeting-start chime (opt-in).** A short non-intrusive sound confirms recording started. Off by default.

### Pipeline
- ~~**Preprocessing concurrency guard.**~~ Done — "Low Memory Mode" toggle in Settings → Advanced → Memory serializes preprocessing to halve peak RAM (~400 MB vs ~800 MB). Off by default.
- **Per-job log viewer.** When a job fails, the error string is short. Capture a rolling per-job log (stdout/NSLog lines) and show it in a disclosure view.

## Mid-term — within-spec enhancements

Features that fit the on-device, single-process philosophy but require more code than a polish pass.

### Speaker management
- **Manual speaker split.** Inverse of merge — split a speaker profile if the user realizes two voices were collapsed.
- **Split candidate at naming time.** When the naming prompt's clips reveal that diarization merged two voices into one cluster, let the user split the candidate into multiple `SpeakerProfile`s instead of just discarding it. Today the only options are name (and accept the merged embedding) or discard via "Multiple speakers" (no profile created). A future "Split…" action would let the user assign different names per clip and re-cluster the underlying segments — requires segment-level reassignment and a more involved naming UI.
- ✅ **Bulk-delete / archive old speakers.** Speakers with no meeting activity in N months — implemented as automatic deletion at launch based on `speakerRetentionDays` setting (default 90 days), configurable in Advanced → Speaker Archive. Set to 0 to disable.

### Pipeline & output
- **Alternative output formats.** Out of scope per spec today, but worth re-evaluating: plain `.txt`, `.srt`, VTT for video workflows, or a lightweight HTML with anchors.
- **Grounded speaker assignment.** Use the WeSpeaker embedding on the mic track to double-check that the "longest-duration speaker on mic = local user" heuristic holds. If it doesn't, fall back to prompting the user.

### Dictation
- **Dictation transcript log.** Optional history of dictated text (with timestamps and target-app name) for recovery if injection drops characters.

### Design ideas (from `design_handoff_app_surfaces`)
These surfaces are specified in the design handoff but not yet implemented:
- **First-run onboarding flow.** A 620×480px four-step permission wizard (Microphone → Screen Recording → System Audio → Accessibility) with progress indicator and Grant/Skip buttons. Shows on first launch before the main UI.
- **About as a modal sheet.** The design specifies About as a dimmed overlay sheet (380px wide) over the app, rather than a settings tab. Current tab is functional; this would be a polish upgrade.

### Diagnostics
- **In-app diagnostics pane.** Promote `scripts/diagnose.swift` into a hidden developer pane that surfaces Teams process IDs, active power assertions, CoreAudio device tree, and the most recent tap status.
- **One-click bug report bundle.** Zip up recent logs, `pipeline_queue.json`, and (opt-in) the last failed recording's WAVs for manual sharing.

## Long-term — bigger bets

These stretch the architecture and deserve a spec update before landing.

- **Live captions during the meeting.** The spec explicitly disables this to keep the Mac cool during calls; revisit once Apple Silicon idle cost improves or the user can opt-in per-meeting.
- **Sortformer diarizer.** FluidAudio includes `SortformerDiarizer` (~11% DER vs ~17.7% for current LS-EEND + WeSpeaker). Blocked by an embedding gap: Sortformer's `DiarizerTimeline` carries no per-segment speaker embeddings, which the cross-meeting speaker identity system requires. Unblock by adding a WeSpeaker embedding-extraction pass on Sortformer's segments before converting to `DiarizationResult`. Selectable per-meeting size makes sense (Sortformer has 4 fixed speaker slots).
- **Live speaker identification during the meeting.** Would need a streaming diarizer; today's LS-EEND is offline.

## Technical debt

- **In-meeting note editing.** Today the user edits notes by opening the rendered `.md` directly. A future polish: a "Notes" disclosure on each completed job in the menu bar dropdown that lists captured notes and lets the user edit/delete before the transcript is finalized (or rewrite the `.md` if it's already been written).
- **`Views.swift` size.** ~1.9 kLOC for all UI after the Paper design system landed. Split by tab once we're past the early iteration phase.
- **`SlidingWindowAsrConfig` doesn't expose `TdtConfig`.** The internal `asrConfig` hardcodes `TdtConfig()` (blankId 8192 = v3 default). `AsrManager` auto-adapts the blankId when it detects a mismatch against the loaded model, so v2 models work correctly today — but if FluidAudio ever removes that adaptation, v2 dictation would silently decode incorrectly. Bumped to FluidAudio 0.14.5. Upstream fix in review: [FluidInference/FluidAudio#611](https://github.com/FluidInference/FluidAudio/pull/611). Once merged, update `DictationManager.start()` per the TODO comment.

## Non-goals (from `spec.md`)

These are intentional exclusions. Don't add them without a spec update.

- LLM integration (no Claude, OpenAI, or local LLM)
- Cloud APIs of any kind
- Google Meet support (browser-tab; no per-meeting power assertion to detect)
- Manual app recording (pick any app)
- System-wide audio capture
- Multiple output formats beyond Markdown
- Configurable VAD threshold or speaker count
- macOS notifications
- Live captions or live speaker ID during meetings
- Batch import of existing recordings
- Pre-release update channels
- Dictation voice commands (`"scratch that"`, `"new paragraph"`) and spoken punctuation
