# Heard — Roadmap

A living list of planned improvements and stretch ideas. Ordered by how close each item is to the current scope of `spec.md`. Anything that would change the product (cloud APIs, LLM integration, non-English transcription, Zoom/Webex support) belongs in [What's explicitly NOT in scope](#whats-explicitly-not-in-scope) unless the spec itself changes.

## Near-term — polish & stability

These land inside the existing v1 scope and mostly tighten things the user already sees.

### Distribution & install
- ~~**App icon.**~~ Done — `Resources/AppIcon.iconset/` ships full 16–512 px pairs, `bundle.sh` compiles them with `iconutil -c icns` into `AppIcon.icns`, `Info.plist` references it via `CFBundleIconFile`, and the About tab now renders `NSApp.applicationIconImage` instead of the SF Symbol placeholder.
- **DMG packaging.** Add a `scripts/dmg.sh` that builds, signs, notarizes, and stamps out a DMG for GitHub Releases.
- **Homebrew Cask.** Draft a Cask formula so the app is installable via `brew install --cask heard` once the DMG pipeline is live.
- **CI pipeline.** GitHub Actions workflow: `swift build`, run `HeardTests`, build the bundle, (optionally) notarize, publish artifacts on tag pushes.
- **Sparkle (or equivalent) update checker.** Explicitly out of scope per `spec.md`, but worth reconsidering once CI publishes releases.

### Menu bar icons & state feedback
- ~~**Icon state signaling via tint and opacity.**~~ Done — Menu bar icon now uses **accent tint** (blue) when recording or dictating, and **primary tint** (white/gray) when idle. **Opacity** is 100% when watching or recording, and 50% when paused (dormant, not dictating, meeting detection off).
- **Richer icon states (future).** Today the menu bar uses SF Symbols with built-in symbol effects. Once tint/opacity is stable, investigate whether a custom `NSStatusItem` wrapper with frame-by-frame `NSImage` updates would give us more distinct badges (error vs. user-action vs. processing vs. dictating) without adding a dependency.
- **Error badge persistence.** The spec calls out a red exclamation badge that persists until acknowledged. Verify this survives app relaunch when a failed job stays in the queue.
- **Menu bar dropdown height.** The `.window` style has a fixed max height; with many jobs queued, the bottom of the panel can clip. Add an internal `ScrollView` for the jobs list.

### Dictation UX
- ~~**Hotkey recorder validation.**~~ Done — `HotkeyRecorderView` validates combos: no-modifier and known system shortcuts (⌘Tab, ⌘Space, ⌘Q, ⌘H, ⌘M, ⌘W, ⌃Space, screenshot shortcuts) are blocked with a red error and Save disabled; single-modifier combos show an orange soft warning but allow saving.
- ~~**Spoken command passthrough.**~~ Done — `DictationManager.stripFillers` removes standalone instances of "uh", "um", "er", "ah", "hmm", "hm", "uhh", "umm", "mhm" (case-insensitive, word-boundary safe) before text injection. `injectedText` still advances past fillers so they're never re-processed.
- ~~**Visible dictation indicator.**~~ Done — `DictationHUD` is a floating `NSPanel` (`.floating` level, `nonactivatingPanel`, `canJoinAllSpaces`) showing a waveform icon + "Dictating" pill at bottom-centre of the screen. Appears on start, dims to 35% alpha after 2.5 s, fades out on stop. Opt-in via Settings → Dictation → "Show Dictation Indicator".
- ~~**Graceful AX permission flow.**~~ Done — `AppModel.startAXPolling()` checks `AXIsProcessTrusted()` every 2 s while dictating. On revocation, sets `dictationAXLost`, stops dictation and hides the HUD. The menu bar dropdown shows an orange banner ("Accessibility access was revoked") with a "Re-grant Access…" button (calls `TextInjector.ensureAccessibility()`) and a Dismiss button.

### Meeting detection & recording
- ~~**Teams bundle-ID fallback.**~~ Done — `MeetingDetector.isTeamsMainApp` matches `com.microsoft.teams` / `com.microsoft.teams2` first, with the localized-name set kept as a fallback for builds under unfamiliar bundle IDs.
- **Audible meeting-start chime (opt-in).** A short non-intrusive sound confirms recording started. Off by default.
- ~~**Recording self-test.**~~ Done — tap is verified at T+2s; on silence, the chain is rebuilt once with fresh helper enumeration; persistent silence flips `appAudioTapFailed` and shows "Recording (mic only)" in the menu bar. Mic-side self-test still TODO.
- **Graceful fallback on tap failure.** Already mic-only-on-tap-error; surface a warning banner in the menu bar dropdown so the user knows the meeting will only have their own voice.
- ~~**`stopWatching` should end the active meeting.**~~ Done — `MeetingDetector.stopWatching` now synchronously fires `onMeetingEnded` for any active snapshot, and `AppModel.stopWatching` preserves the resulting `.processing` phase.

### Pipeline
- ~~**Lifetime retry ceiling.**~~ Done — `executeWithRetry` now increments `retryCount` cumulatively (`+=`) with a `lifetimeRetryLimit = 6` cap; `prepareForResume()` leaves capped jobs in `.failed`; `retryFailedJob` resets the count so user-initiated retry gets a fresh budget.
- **Preprocessing concurrency guard.** Both tracks are currently preprocessed concurrently in a `TaskGroup`. On machines with tight memory, this doubles the peak RAM during VAD. Expose a setting to serialize preprocessing.
- **Progress in the UI.** The menu bar dropdown shows the current stage but no sub-stage progress. Emit sample-count-based progress from `AsrManager.transcribe` through an `AsyncStream`.
- **Transcript preview in the dropdown.** Show the first ~100 chars of the most recent completed transcript so the user can verify the right meeting got captured.
- ~~**Open transcript in reveal mode.**~~ Done — Right-click → "Reveal in Finder" on each job row in the new Recent Meetings dropdown.
- ~~**Re-run speaker assignment.**~~ Done — Merging or renaming a speaker in Settings now prompts to retroactively replace the names across all old transcripts. Replaced monotonic `Speaker N` counter with unique UUID identifiers.
- **Per-job log viewer.** When a job fails, the error string is short. Capture a rolling per-job log (stdout/NSLog lines) and show it in a disclosure view.
- **Exclude silent clips from speaker naming.** When extracting audio clips for the speaker naming dialogue, filter out segments with silence/VAD gaps so each playback is continuous speech.
- **Fix speaker naming dialogue auto-close.** The 120-second auto-dismiss is too aggressive when the user is actively filling out speaker names. Change behavior: close only if the window has been open and dormant (no text edits) for the full duration.
- **Improve speaker table sorting.** Replace the sort dropdown with standard column-header sorting: click a column name (Name / Last Seen / Meeting Count) to sort by that field, click again to toggle descending (default) ↔ ascending. Show a subtle indicator (caret) on the active sort column.
- ~~**Fix dictation hotkey reuse.**~~ Done — `stop()` now calls `mgr.cleanup()` after `finish()` to close the `transcriptionUpdates` AsyncStream and release the internal ASR manager before the next session reuses `asrModels`. `start()` now throws `DictationError.notIdle` instead of silently returning, so state corruption from rapid presses is surfaced. `AppModel.toggleDictation()` drops concurrent presses with an in-flight guard. Real-time injection fixed: `injectDelta` is called on every transcription update (not only `isConfirmed` updates) so words flow in as the sliding window confirms them.

### Testing
- **Golden-file tests for `RosterReader` AX traversal.** The parser and filter are covered, but the actual DOM walk (`findRosterPanel`, `findParticipantList`, `extractTextChildren`) is still untested because it's bound to live `AXUIElement`. Introduce a small protocol wrapper around the AX tree that can be fed captured JSON snapshots from real Teams meetings (various states: pre-join lobby, 2-person call, 10-person call, roster panel open vs collapsed). This is the single highest-value remaining roster test — the one most likely to catch breakage when Teams updates its DOM.

### Custom vocabulary
- ~~**Batch transcription path.**~~ Done — `PipelineProcessor.applyVocabularyBoosting` post-processes each track's `ASRResult` with `CtcKeywordSpotter` + `VocabularyRescorer.ctcTokenRescore`, then applies via `ASRResult.withRescoring`. Best-effort: gracefully skips when the CTC 110M model isn't downloaded or when an `ASRResult` lacks `tokenTimings`.
- **Phrase boosting, not just terms.** The CTC path tokenizes whole strings, so multi-word phrases already work — but the UI suggests "terms" and the 3-char minimum blocks short acronyms. Reconsider the minimum and label the field "Terms or short phrases".
- **Import/export vocabulary list.** JSON round-trip via drag-and-drop.

## Mid-term — within-spec enhancements

Features that fit the on-device, single-process philosophy but require more code than a polish pass.

### Speaker management
- ~~**Cumulative transcription stats per speaker.**~~ Done - On the Speakers tab, show each speaker's cumulative hours transcribed and word count across all meetings.
- ~~**Retroactive speaker name mapping.**~~ Done - When a new speaker is identified and named (via the naming dialogue or manual entry), automatically search and replace that speaker ID across all existing transcripts in the output directory. Surfaces a confirmation dialogue showing how many transcripts will be updated.
- **Speaker merge preview.** Before committing a merge, show both speakers' recent meeting counts, first/last-seen dates, and a diff of embeddings count. When merging, keep the name that is not a "Speaker X" placeholder (prefer the real human-given name).

- **Manual speaker split.** Inverse of merge — split a speaker profile if the user realizes two voices were collapsed.
- **Per-speaker colors in the transcript.** Lightweight Markdown footer or HTML export with consistent per-speaker colors.
- **Voice clip gallery.** Store a single 10-second reference clip per known speaker so the user can play it back from Settings → Speakers to verify identity.
- **Bulk-delete / archive old speakers.** Speakers with no meeting activity in N months.

### Pipeline & output
- **Live meeting notes.** During an active meeting, allow the user to add timestamped text notes via a menu bar button or hotkey (e.g., Ctrl+Shift+N). Notes are stored in-memory and merged into the final transcript as `[HH:MM:SS] **Note:** text here` blocks, inserted chronologically. Future enhancements: voice notes that auto-transcribe, notes outside active meetings, note editing/deletion.
- **Alternative output formats.** Out of scope per spec today, but worth re-evaluating: plain `.txt`, `.srt`, VTT for video workflows, or a lightweight HTML with anchors.
- ~~**Configurable date format.**~~ Done - The `YYMMDD_Title.md` filename is fixed. Let power users switch to `YYYY-MM-DD_Title.md`.
- **Transcript deduplication.** Detect when the same segment text appears from both the app and mic tracks (e.g. speaker bleed) and drop the quieter one.
- **Grounded speaker assignment.** Use the WeSpeaker embedding on the mic track to double-check that the "longest-duration speaker on mic = local user" heuristic holds. If it doesn't, fall back to prompting the user.

### Dictation
- **Dictation transcript log.** Optional history of dictated text (with timestamps and target-app name) for recovery if injection drops characters.
- **Per-app enable list.** Disable dictation in banking apps, password managers, or other sensitive fields.
- **Punctuation normalization.** `"new line"`, `"comma"`, `"period"` — explicitly deferred in the spec but a natural v1.5 addition.
- **Vocab-scoped dictation.** Reuse the custom-vocab boosting (already wired into `SlidingWindowAsrManager`) in a "coding mode" with camelCase / snake_case post-processing.

### Preferences & UI
- **Localize the settings UI.** The spec says English-only for transcription, but the app chrome could be localized.
- **Keyboard shortcuts in the dropdown.** ⌘S (start/stop watching), ⌘N (name speakers), ⌘, (settings), ⌘Q (quit) — mentioned in the spec but currently only partially wired.
- **Re-ordered settings tabs.** "General" is crowded today. Consider splitting out a "Transcription" tab (custom vocabulary + output folder + CTC keep-alive) once we have more to put there.

### Diagnostics
- **In-app diagnostics pane.** Promote `scripts/diagnose.swift` into a hidden developer pane that surfaces Teams process IDs, active power assertions, CoreAudio device tree, and the most recent tap status.
- **One-click bug report bundle.** Zip up recent logs, `pipeline_queue.json`, and (opt-in) the last failed recording's WAVs for manual sharing.

## Long-term — bigger bets

These stretch the architecture and deserve a spec update before landing.

- **Zoom / Webex / Google Meet detection.** Today Heard only recognises Teams power assertions. A pluggable "meeting source" abstraction could add others without touching the pipeline. Out of scope in `spec.md` as of v1.
- **Live captions during the meeting.** The spec explicitly disables this to keep the Mac cool during calls; revisit once Apple Silicon idle cost improves or the user can opt-in per-meeting.
- **Sortformer diarizer.** FluidAudio includes `SortformerDiarizer` (~11% DER vs ~17.7% for current LS-EEND + WeSpeaker). Blocked by an embedding gap: Sortformer's `DiarizerTimeline` carries no per-segment speaker embeddings, which the cross-meeting speaker identity system requires. Unblock by adding a WeSpeaker embedding-extraction pass on Sortformer's segments before converting to `DiarizationResult`. Selectable per-meeting size makes sense (Sortformer has 4 fixed speaker slots).
- **Live speaker identification during the meeting.** Would need a streaming diarizer; today's LS-EEND is offline.
- **Meeting note summaries.** Requires an LLM, which is explicitly out of scope. Revisit only if a local, on-device model ships that meets the quality bar.
- **Batch import of existing recordings.** Drag-and-drop a `.wav` / `.m4a` file into the menu bar dropdown to run the same pipeline on it. Explicitly out of scope in v1.
- **Android / Windows companion.** Heard is macOS-only by design. Not planned.

## Technical debt

- **`hotkeyManagerInstance` global.** The Carbon callback bridge uses a singleton. Acceptable for a one-hotkey app, but brittle if we ever add a second global shortcut. Replace with a `UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())` context.
- **`Views.swift` size.** ~1.3 kLOC for all UI. Split by tab once we're past the early iteration phase.
- **`SlidingWindowAsrConfig` doesn't expose `TdtConfig`.** The internal `asrConfig` hardcodes `TdtConfig()` (blankId 8192 = v3 default). `AsrManager` auto-adapts the blankId when it detects a mismatch against the loaded model, so v2 models work correctly today — but if FluidAudio ever removes that adaptation, v2 dictation would silently decode incorrectly. Upstream fix: add a `tdtConfig` parameter to `SlidingWindowAsrConfig`.

## Non-goals (from `spec.md`)

These are intentional exclusions. Don't add them without a spec update.

- LLM integration (no Claude, OpenAI, or local LLM)
- Cloud APIs of any kind
- Non-English transcription / multilingual models
- Zoom / Webex / Google Meet support
- Manual app recording (pick any app)
- System-wide audio capture
- Multiple output formats beyond Markdown
- Configurable VAD threshold or speaker count
- macOS notifications
- Live captions or live speaker ID during meetings
- Batch import of existing recordings
- Pre-release update channels
- Dictation voice commands (`"scratch that"`, `"new paragraph"`) and spoken punctuation
