# Heard — Roadmap

A living list of planned improvements and stretch ideas. Ordered by how close each item is to the current scope of `spec.md`. Anything that would change the product (cloud APIs, LLM integration, non-English transcription, Zoom/Webex support) belongs in [What's explicitly NOT in scope](#whats-explicitly-not-in-scope) unless the spec itself changes.

## Near-term — polish & stability

These land inside the existing v1 scope and mostly tighten things the user already sees.

### Distribution & install
- **App icon.** Design and ship a proper `AppIcon.icns` for the bundle — currently the About tab uses an SF Symbol as a placeholder.
- **DMG packaging.** Add a `scripts/dmg.sh` that builds, signs, notarizes, and stamps out a DMG for GitHub Releases.
- **Homebrew Cask.** Draft a Cask formula so the app is installable via `brew install --cask heard` once the DMG pipeline is live.
- **CI pipeline.** GitHub Actions workflow: `swift build`, run `HeardTests`, build the bundle, (optionally) notarize, publish artifacts on tag pushes.
- **Sparkle (or equivalent) update checker.** Explicitly out of scope per `spec.md`, but worth reconsidering once CI publishes releases.

### Menu bar icons & state feedback
- **Richer icon states.** Today the menu bar uses SF Symbols with built-in symbol effects. Investigate whether a custom `NSStatusItem` wrapper with frame-by-frame `NSImage` updates would give us more distinct states (error badge vs. user-action badge vs. processing vs. dictating) without adding a dependency.
- **Error badge persistence.** The spec calls out a red exclamation badge that persists until acknowledged. Verify this survives app relaunch when a failed job stays in the queue.
- **Menu bar dropdown height.** The `.window` style has a fixed max height; with many jobs queued, the bottom of the panel can clip. Add an internal `ScrollView` for the jobs list.

### Dictation UX
- **Hotkey recorder validation.** The Record sheet accepts any combo today. Block combinations that clash with common system shortcuts (⌘Tab, ⌘Space, ⌘Q, etc.) and show a soft warning for single-modifier combos.
- **Tune polling cadence.** The streaming loop sleeps 600 ms between transcriptions and requires 0.5 s of audio to start. Measure end-to-end latency with `os_signpost` and consider exposing the interval as a hidden developer setting.
- **Spoken command passthrough.** Strip or interpret common fillers (`"uh"`, `"um"`) before injection — trivial post-processing that dramatically improves feel without adding any new models.
- **Visible dictation indicator.** When dictation is active but the menu bar is hidden, the user has no feedback. Add an optional transient HUD (similar to macOS volume overlay) that fades while listening.
- **Graceful AX permission flow.** If Accessibility is revoked mid-session, text injection silently fails. Detect the failure and surface a one-shot banner with a re-grant button.

### Meeting detection & recording
- **Teams bundle-ID fallback.** Detection matches localized app names (`"Microsoft Teams"`, `"Microsoft Teams classic"`, `"Microsoft Teams (work or school)"`). Add bundle-ID matching (`com.microsoft.teams`, `com.microsoft.teams2`) so non-English localizations of macOS/Teams still work.
- **Audible meeting-start chime (opt-in).** A short non-intrusive sound confirms recording started. Off by default.
- **Recording self-test.** After starting, verify that non-zero samples are flowing from both the mic and the tap within 2 s. If not, surface an error and try to recover (re-create the aggregate device once).
- **Graceful fallback on tap failure.** Already mic-only-on-tap-error; surface a warning banner in the menu bar dropdown so the user knows the meeting will only have their own voice.

### Pipeline
- **Preprocessing concurrency guard.** Both tracks are currently preprocessed concurrently in a `TaskGroup`. On machines with tight memory, this doubles the peak RAM during VAD. Expose a setting to serialize preprocessing.
- **Progress in the UI.** The menu bar dropdown shows the current stage but no sub-stage progress. Emit sample-count-based progress from `AsrManager.transcribe` through an `AsyncStream`.
- **Transcript preview in the dropdown.** Show the first ~100 chars of the most recent completed transcript so the user can verify the right meeting got captured.
- **Open transcript in reveal mode.** Right-click → "Reveal in Finder" on each job row.
- **Re-run speaker assignment.** If the user renames a speaker or merges two profiles, older transcripts don't retroactively update. Add a "Re-run speaker assignment" action on completed jobs that re-reads the cached `.wav` files (while they're still within the 48 h window).
- **Per-job log viewer.** When a job fails, the error string is short. Capture a rolling per-job log (stdout/NSLog lines) and show it in a disclosure view.

### Custom vocabulary
- **Phrase boosting, not just terms.** The CTC path tokenizes whole strings, so multi-word phrases already work — but the UI suggests "terms" and the 3-char minimum blocks short acronyms. Reconsider the minimum and label the field "Terms or short phrases".
- **Import/export vocabulary list.** JSON round-trip via drag-and-drop.

## Mid-term — within-spec enhancements

Features that fit the on-device, single-process philosophy but require more code than a polish pass.

### Speaker management
- **Speaker merge preview.** Before committing a merge, show both speakers' recent meeting counts, first/last-seen dates, and a diff of embeddings count.
- **Manual speaker split.** Inverse of merge — split a speaker profile if the user realizes two voices were collapsed.
- **Per-speaker colors in the transcript.** Lightweight Markdown footer or HTML export with consistent per-speaker colors.
- **Voice clip gallery.** Store a single 10-second reference clip per known speaker so the user can play it back from Settings → Speakers to verify identity.
- **Bulk-delete / archive old speakers.** Speakers with no meeting activity in N months.

### Pipeline & output
- **Transcript re-ingest on settings change.** When the user edits their name or re-assigns a speaker, offer to regenerate recent transcripts (with the raw WAVs still on disk).
- **Alternative output formats.** Out of scope per spec today, but worth re-evaluating: plain `.txt`, `.srt`, VTT for video workflows, or a lightweight HTML with anchors.
- **Configurable date format.** The `YYMMDD_Title.md` filename is fixed. Let power users switch to `YYYY-MM-DD_Title.md`.
- **Transcript deduplication.** Detect when the same segment text appears from both the app and mic tracks (e.g. speaker bleed) and drop the quieter one.
- **Grounded speaker assignment.** Use the WeSpeaker embedding on the mic track to double-check that the "longest-duration speaker on mic = local user" heuristic holds. If it doesn't, fall back to prompting the user.

### Dictation
- **Dictation transcript log.** Optional history of dictated text (with timestamps and target-app name) for recovery if injection drops characters.
- **Per-app enable list.** Disable dictation in banking apps, password managers, or other sensitive fields.
- **Punctuation normalization.** `"new line"`, `"comma"`, `"period"` — explicitly deferred in the spec but a natural v1.5 addition once the batch-ASR loop is proven.
- **Vocab-scoped dictation.** Reuse the custom-vocab boosting in a "coding mode" with camelCase / snake_case post-processing.

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
- **Live speaker identification during the meeting.** Would need a streaming diarizer; today's LS-EEND is offline.
- **Meeting note summaries.** Requires an LLM, which is explicitly out of scope. Revisit only if a local, on-device model ships that meets the quality bar.
- **Batch import of existing recordings.** Drag-and-drop a `.wav` / `.m4a` file into the menu bar dropdown to run the same pipeline on it. Explicitly out of scope in v1.
- **Android / Windows companion.** Heard is macOS-only by design. Not planned.

## Technical debt

- **`hotkeyManagerInstance` global.** The Carbon callback bridge uses a singleton. Acceptable for a one-hotkey app, but brittle if we ever add a second global shortcut. Replace with a `UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())` context.
- **Settings window activation policy gymnastics.** `MTApp.swift` flips `NSApp.setActivationPolicy` between `.accessory` and `.regular` to make the Settings window accept keyboard input. This is fragile around the Name Speakers window and deserves a cleaner wrapper.
- **`Views.swift` size.** ~1.3 kLOC for all UI. Split by tab once we're past the early iteration phase.
- **Mic resampling in the dictation tap.** Linear interpolation is fine for 16 kHz ASR but audibly worse than `AVAudioConverter`. Unify with the pipeline resampler.
- **`pipelineKeepAlive = 0` default.** Meeting models unload immediately today, so back-to-back meetings reload the 800 MB pipeline twice. Consider a 60 s default once we're confident the unload-after path is tested on low-RAM machines.

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
