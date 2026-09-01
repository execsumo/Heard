# Heard — Roadmap

A living list of known issues, technical debt, and core constraints. 

To preserve the focus, performance, and simplicity of Heard as a lean, native, single-process on-device app, we have explicitly pruned speculative enhancements (such as manual speaker splitting, alternative formats, live captions, or visual onboarding wizards) in favor of keeping the core tool highly polished and reliable.

## Technical Debt & Known Issues

These represent the remaining areas of focus to clean up and stabilize:

### Active Tech Debt & Known Issues
- **Terminal design-system conversion is unverified (2026-09-01).** The UI was converted from the "Paper" language to the terminal system in `DESIGN.md` (see `plans/terminal-design-conversion.md`), but the work was done on Linux where `swift build` cannot run. It passes `swiftc -parse` and every design token resolves, but it has never been type-checked, run, or looked at. `handoff.md` carries the verification checklist. Until that passes, treat the UI as broken-until-proven-working.
- **Light-mode palette is derived, not specified.** `DESIGN.md` ships a dark-only palette. The light halves of `HeardTheme.Terminal` were invented to keep the System/Light/Dark preference working, and have not been contrast-checked against WCAG or eyeballed. Amber-on-white is the pair most likely to need adjustment.

### Completed Technical Debt & Polish
- ~~**Menu bar dropdown height clipping.**~~ Obsolete — `PipelineQueueStore.recentTranscripts` bounds the list at 3 items (`prefix(3)`) by construction, so job accumulation cannot occur in the UI. Total panel height (~360 pt) fits comfortably within macOS `MenuBarExtra(.window)` max height bounds without clipping bottom actions (Settings, Quit).
- ~~**`Views.swift` size.**~~ Done — the ~1.9 kLOC single file was split by view area into `DesignSystem.swift` (Paper tokens + `SettingsCard`/`StatusDot`/layout primitives), `MenuBarView.swift` (dropdown UI + menu-bar icon), `SpeakerNamingView.swift`, `SettingsView.swift` (window shell + sidebar nav), `SettingsTabs.swift` (General/Recording/Dictation/Speakers/Advanced/About tab bodies), and `SettingsComponents.swift` (reusable rows like `MicrophonePickerRow`/`HotkeyRecorderView`). Pure move — no logic changes; build clean and all tests green.
- ~~**Silent corruption reset in JSON stores.**~~ Done — an existing-but-undecodable `queue.json`/`speakers.json` is quarantined to `<name>.corrupt` (logged) before resetting, instead of being silently discarded.
- ~~**Persist amplification in `SpeakerStore`.**~~ Done — per-meeting stat updates and retention archiving now rewrite the JSON once per operation, not once per profile. (`SettingsStore.persist()` still rewrites all keys per change — left alone deliberately: UserDefaults writes are in-memory/coalesced and the JSON encodes are tiny.)
- ~~**Mic failure killed the whole recording.**~~ Done — mic capture is best-effort like the app tap; recording degrades to app-audio-only with a "Recording (no mic)" header and warning banner. Start only throws when both tracks fail.
- ~~**WAV write errors silently swallowed.**~~ Done — mic-tap and app-IOProc write failures (disk full etc.) log once and feed the existing `renderErrorCount`/periodic stats line.
- ~~**PermissionCenter republishes identical state every 3 s.**~~ Done — `refresh()` builds the candidate array and assigns only when it differs from the published value (`PermissionStatus` was already `Equatable`), so observing views no longer re-render 20×/minute on identical state. The 1 s detector poll turned out to be per spec ("2 consecutive polls (2 seconds)" start latency); the stale "every 3 seconds" references in spec.md/CLAUDE.md/handoff.md were corrected instead.
- ~~**Watchdog abort can leak a zombie pipeline task.**~~ Done — every pipeline run carries a generation token (`PipelineProcessor.runGeneration`); the watchdog abort bumps it, and every post-await resumption point checks `ensureCurrent(generation)` before touching shared per-job state or persisting queue updates. A stuck FluidAudio call that eventually returns now dies at its next checkpoint instead of corrupting the replacement run. The abort also re-kicks `runNextIfNeeded()` so the rest of the queue isn't stalled.
- ~~**App-audio self-test rebuild invalidates `micDelaySeconds`.**~~ Done — `attemptAppAudioRebuild` recomputes `mic.start − app.start` from the post-rebuild `appStartTime` and updates the active session, so bleed dedup and interleaving stay aligned.
- ~~**`SlidingWindowAsrConfig` doesn't expose `TdtConfig`.**~~ Done — FluidAudio updated to 0.14.7. We now pass the explicit `TdtConfig(blankId: modelVersion.blankId)` when initializing `SlidingWindowAsrManager` inside `DictationManager.start()`, avoiding reliance on internal blank-token auto-adaptation.
- ~~**DMG packaging.**~~ Done — `scripts/dmg.sh` builds, signs, notarizes, and packages.
- ~~**Homebrew Cask.**~~ Done — `brew tap execsumo/tap && brew install --cask heard`.
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
