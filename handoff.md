# Handoff

## Current Status

The app builds cleanly with `swift build` and runs as a menu bar app on macOS 15.0+. Core infrastructure is complete — meeting detection, dual-track audio capture, on-device transcription (Parakeet TDT V2), VAD (Silero), speaker diarization (LS-EEND + WeSpeaker), and speaker assignment are all functional via the FluidAudio framework. An `.app` bundle is available via `./scripts/bundle.sh`.

**v0.1.0 is released** — notarized DMG published to [GitHub Releases](https://github.com/execsumo/Heard/releases/tag/v0.1.0) and installable via `brew tap execsumo/tap && brew install --cask heard`.

**Homebrew tap renamed (2026-07-08):** `homebrew-heard` → `homebrew-tap`, so the same tap can host formulas/casks for other projects (e.g. Dossier) alongside Heard's cask. `ci.yml`'s release job and `update-tap.yml` now clone/push to `homebrew-tap.git`; install/update commands are `brew tap execsumo/tap` and `brew upgrade --cask heard`.

**Dictation feature is fully functional** — speech recognition, text injection via clipboard paste (Cmd+V), and global hotkey (Ctrl+Shift+D) all working. Requires a stable (non-ad-hoc) code signing identity so Accessibility permission persists across rebuilds; `./scripts/bundle.sh` auto-signs with the available `Developer ID Application` cert (else `Dev Cert`), so a bare `./scripts/bundle.sh` is sufficient.

**Dictation paste targets the field focused at start (not at paste time):** `AppModel.toggleDictation` snapshots the focused AX element + owning app pid (`TextInjector.captureFocusTarget`) synchronously at trigger time; `TextInjector.inject(_:restoringFocusTo:)` re-activates that app, raises the element's window, and re-sets `kAXFocused` before sending Cmd+V (with a 0.2 s settle delay when focus had to change). If the user never moved focus nothing changes; if the capture fails, focus was on Heard itself, or the target app has quit, injection falls back to the old paste-at-current-focus behavior. `DictationManager.onUtterance` is now typed `@MainActor` (its handler reads main-actor state).

**In-meeting notes are fully functional** — global hotkey (Ctrl+Shift+N by default) opens a focused composer panel during recording; notes interleave chronologically into the rendered transcript as italicized `**Note from <userName>:**` lines. See "In-Meeting Notes" below.

**FluidAudio upgraded to 0.15.5** (2026-07-11). Brings long-form chunk-merge fixes, Silero VAD v6.2.1, per-term custom-vocabulary thresholds, and the new `ModelHub` download layer. (The 0.15.5 fused decoder is streaming-only and does not apply to Heard's batch `AsrManager`.)
- **ModelHub migration:** `ModelDownloadManager` now uses `AsrModels.modelsExist` to verify Parakeet cache presence instead of manual directory peeking; the VAD/CTC/diarizer presence checks are unchanged (the upgrade was otherwise non-breaking, so a full ModelHub rewrite was deliberately skipped).
- **Custom Vocabulary Thresholding:** Added a length-based similarity threshold policy (`String.defaultVocabularySimilarityThreshold`) to reduce false positives on short custom terms. Dictation and batch rescoring now construct `CustomVocabularyTerm` with this dynamic `minSimilarity`.
- Note: Fused decoder and Compute Units features from 0.15.5 were evaluated but not adopted (fused decoder is streaming-only; compute units are automatic in `loadModels`).

**FluidAudio upgraded to 0.15.2** (from 0.14.7). Brings Parakeet v3 ASR throughput gains for free and exposes per-chunk speaker embeddings. Speaker assignment now builds a **duration-weighted, outlier-trimmed centroid per speaker** from `DiarizationResult.chunkEmbeddings` instead of the previous "first segment per speaker" embedding — more stable cross-meeting identity. The aggregation lives in pure, unit-tested code (`SpeakerEmbeddingAggregator` in `SpeakerAssignment.swift`); the diarizer is configured with `exposeChunkEmbeddings = true` in `runDiarization`, and `buildSpeakerEmbeddings(from:)` in `Services.swift` falls back to the legacy per-segment path when chunk embeddings are unavailable (very short audio / older model builds).

**Speaker Pre-enrollment & User Self-Profile (2026-07-12):**
- **Offline pre-enrollment was evaluated and skipped:** FluidAudio 0.15.5's speaker pre-enrollment (`enrollSpeaker`) is restricted to the streaming diarizer (`SortformerDiarizer` / `LSEENDDiarizer`). The `OfflineDiarizerManager` used by Heard has no equivalent pre-enrollment API. Heard's existing post-hoc `SpeakerMatcher` already provides the equivalent outcome for the offline path (known voices resolve to names without the naming prompt when matched). This should be revisited if FluidAudio adds offline enrollment or if Heard ever adopts the streaming diarizer.
- **User self-profile shipped:** The user's mic track (which is the user by construction) is now diarized (strictly to extract chunk embeddings) in `runDiarization`. A single duration-weighted centroid representing the user's voice is extracted and fed into a new unit-tested `SpeakerMatcher.updateSelfProfile` method. This method automatically creates or case-insensitively merges this embedding into a profile named `settings.userName` (skipped if empty). This ensures the user's profile is automatically refreshed on every meeting without manual naming.

**Robustness/efficiency hardening pass (post-v0.2.3):**
- `DebugFileLog` is now gated behind Developer Mode (off by default), rotates at 5 MB, and never logs transcript content (lengths only) — previously it logged every dictated utterance to an unbounded plaintext file and ran a 1 Hz heartbeat in every install.
- Meeting-start title/roster AX scraping and the 15 s roster poll now run on detached background tasks with a 1 s `AXUIElementSetMessagingTimeout`, so a busy/hung Teams can no longer stall Heard's main thread. The meeting (and recording) starts when the scrape completes; if the meeting ends mid-scrape, the detection state machine prevents an orphaned start.
- **Teams accessibility-tree wake (fixes empty meeting titles → "Meeting" filename; unblocks — but does not yet verify — the Teams roster scrape).** Teams is an Electron/Chromium app whose accessibility tree is dormant until a client requests it; AX reads of its windows/titles/roster failed (logged `axErr=-25211`, `kAXErrorAPIDisabled`) even though Heard is trusted (stable Developer ID signing + live `AXIsProcessTrusted`). At meeting detection we now set `AXManualAccessibility=true` on the Teams app element (`MeetingDetector.enableMeetingAppAccessibility`) to wake the tree; the build is async and the join-time set can time out against a busy Teams, so the 15 s roster poll **re-nudges while the roster is still empty**, re-extracts the title until non-empty, and the late title is pushed into the live session via `RecordingManager.updateTitle` in `onMeetingEnded` (parallel to `updateRosterNames`) before the filename is built at transcript-write time. `RecordingSession.title` is now `var`.
  - **RESOLVED (see the dated entry near the top of this section for the full fix): the first real-meeting test came back `titleRefreshed=false` on every tick with `setErr=-25205` (`kAXErrorAttributeUnsupported`) — not `-25211`.** Root cause: `AXManualAccessibility` is a known-broken no-op on current Electron (electron/electron#37465 — Electron never advertises the attribute in `accessibilityAttributeNames`, so the set is rejected before it reaches Chromium's tree-builder). This is an upstream Electron bug, not a Heard AX-trust problem. Fixed by falling back to `AXEnhancedUserInterface` (the same attribute VoiceOver sets) when `AXManualAccessibility` fails — see `enableMeetingAppAccessibility`. **Still pending a second real-meeting confirmation** that the fallback actually wakes the tree end to end (title/roster populate).
  - **Roster — unblocked but unverified.** Waking the tree is *necessary* but not *sufficient*: `RosterReader`'s parser (hardcoded identifiers `roster-list`/`people-pane`/… and AXList/AXTable heuristics) has never run against real woken Teams output, so the roster may still return empty due to a parser/structure mismatch independent of the tree-wake. (Today participant names in transcripts come from voice matching, not this scrape.)
  - **Diagnostics for the next real meeting (Developer Mode on, tail `~/Library/Application Support/Heard/dict-debug.log`).** The flow is now self-diagnosing end to end:
    - `meeting start scrape: source=teams pid=… titleCaptured=<bool> rosterCount=N` — the anchor line at join.
    - `enableMeetingAppAccessibility: … setErr=<n>` — the wake result. `setErr=0` = nudge accepted (good); `setErr=-25211` = Heard itself untrusted (whole theory wrong, fix the grant); other non-zero = app busy/unsupported.
    - `roster poll tick=K: read=N total=M titleEmpty=<bool> titleRefreshed=<bool>` — one per 15 s poll; the timeline of title/roster recovery.
    - `roster poll tick=K: readRoster empty — AX tree dump (n/3): …` — emitted up to **3×** per meeting while the roster stays empty. A bounded (depth ≤ 9, ≤ 500 nodes) outline of Teams' real AX tree — role, identifier, description, truncated title/value per node. **This is the artifact to retune the parser from:** find the container holding participant names and update `RosterReader`'s `rosterIdentifiers` / list-role heuristics to match. The dump core is `RosterReader.diagnosticTreeDump(root:)` (unit-tested for structure/bounds/depth); live entry `diagnosticTreeDump(pid:)`.
    - Title extraction also logs its own `extractMeetingTitle: …` lines (windows-query error, window count, each raw→cleaned title) on every attempt.
  - **Screen-capture permission observer concurrency fix (unrelated cleanup found during this work):** the `NSWorkspace.didDeactivateApplicationNotification` observer block in `RecordingManager` accessed main-actor state from a `@Sendable` closure (4 warnings, would be Swift 6 errors). Now wrapped in `MainActor.assumeIsolated` (the block already runs on `queue: .main`). Build is warning-free for these.
- App-audio process collection is now per-app (`MeetingApp.isProcessFamilyMember`) instead of hard-coded to Teams — Zoom/Webex helper processes are tapped too. `RecordingManager.startRecording` takes a `source:` parameter.
- `skipNaming` uses `processingJob` (not `activeJob`) so a stale failed job can't pin the phase at `.processing` after "Skip All".
- Removed the dead `partialTranscript` plumbing (the batch dictation engine never produced partials) and its 10 Hz polling loop in `AppModel`.
- Dictation buffer is capped at 4 hours (matches the recording max); further audio is dropped with a one-shot log line.
- `PreprocessedTrack` stores its duration and supports `releasingSamples()`; the pipeline frees the mic track's sample buffer after transcription and the app track's after diarization, cutting late-stage peak memory.
- The cached System Audio grant (`audioCaptureTCCGranted`) is validated once per launch with a momentary tap, so a revoked permission no longer shows "Granted" forever. (Edge case: after `tccutil reset` with the flag still set, this validation tap triggers the TCC prompt at launch.)

- The pipeline is **generation-fenced** against the watchdog-abort race: `runGeneration` is bumped when a run starts and when `abortAndFailCurrentJob` fires; every post-await resumption point calls `ensureCurrent(generation)` (and the retry driver's `onUpdate` is guarded) before touching shared per-job state. A stuck FluidAudio call that ignores cancellation and returns minutes later now exits at its next checkpoint instead of corrupting the job that replaced it. The abort also re-kicks `runNextIfNeeded()`.
- `attemptAppAudioRebuild` recalibrates `micDelaySeconds` (`mic.start − app.start` against the post-rebuild `appStartTime`), so the ~2–4 s rebuild gap no longer skews `SegmentDeduplicator.dropMicBleed`.
- `PermissionCenter.refresh()` publishes only when the statuses actually changed, so the 3 s permission poll no longer re-renders every observing view on identical state. The 1 s meeting-detection poll is per spec (2 consecutive polls = ~2 s start latency); the stale "every 3 seconds" doc references were corrected.
- **Corrupt store files are quarantined, not wiped**: when `queue.json` / `speakers.json` exists but fails to decode, it is moved aside to `<name>.corrupt` (and logged) before starting fresh, so accumulated voice embeddings stay recoverable.
- **Batched speaker persistence**: per-meeting stat updates and retention archiving rewrite `speakers.json` once instead of once per profile (`SpeakerStore.updateStats(_:)` batch overload; `archiveInactiveSpeakers` single-pass).
- **Mic failure no longer loses the meeting**: `startRecording` treats the mic as best-effort, symmetric with the app tap. If the mic engine fails but the app tap comes up, recording continues app-audio-only with a `micCaptureFailed` flag — menu bar shows "Recording (no mic)" plus a warning banner. Only when *both* tracks fail does the start throw.
- **WAV write failures are surfaced**: disk-full/volume-gone errors in the mic tap and app IOProc are logged (once, plus counted into the periodic app-audio stats line) instead of being silently swallowed by `try?`.

- **Low Memory Mode is now automatic.** The old manual `lowMemoryMode: Bool` toggle is replaced by a tri-state `MemoryMode` enum (`.auto` / `.low` / `.normal`, default `.auto`) on `AppSettings`. `.auto` resolves via `SystemMemory.isLowMemoryMachine` — machines with **≤ 8 GB** physical RAM (`physicalMemory <= 8_589_934_592` bytes, via `ProcessInfo.processInfo.physicalMemory`) preprocess audio tracks sequentially; larger machines run concurrently. `AppSettings.effectiveLowMemory` is the computed resolution the pipeline consumes (`Services.runPreprocessing`). The settings UI (Advanced → Memory) is now a picker (Automatic / Force Low / Force Normal) whose subtitle reports the detected RAM and what Automatic resolved to. This also **fixes a persistence bug**: the old `lowMemoryMode` flag was never read or written in `SettingsStore`, so it silently reset every launch; `memoryMode` is now loaded and persisted by `rawValue`, with a one-time migration of the legacy boolean (`true → .low`, `false → .auto`). The threshold check is pure and unit-tested (`runSystemMemoryTests`).

**Dictation reliability fix (v0.2.4):** diagnosed an intermittent failure where dictation "started" (HUD shown) but nothing was transcribed/pasted, plus a perceived "hotkey won't stop it" lag. Root cause was an **AVAudioEngine input-tap stall** — `engine.start()` returned `running=true` while the input node delivered no buffers for 3–11 s (a CoreAudio HAL race), so the user spoke into a dead mic and `stop()` transcribed silence → empty result → no injection. Dev-mode correlation was a red herring (the debug log only writes when Developer Mode is on, so dev-mode-off sessions were simply invisible; failures occurred with dev mode on too). Four fixes:
- **Mic-stall detection + one rebuild** (`DictationManager.start`): after `startMicCapture`, `waitForFirstBuffer` polls up to 750 ms for the first tap buffer; if none arrives the engine is torn down and rebuilt once (clears most transient races), then `throw DictationError.micStalled` if it still stalls — converting a silent dead-mic into a visible error instead of an empty paste.
- **Empty-capture guard** (`DictationManager.stop` → `onNoAudioCaptured`): when a stop yields no usable text but the user listened ≥ 1.5 s, the UI surfaces "No speech captured — please try again" (`AppModel.dictationError`) rather than failing silently. Quick taps stay silent.
- **First-buffer latency logging**: `appendSamples` logs `latencyMs` from mic start to first buffer, so a recurrence is diagnosable at a glance (happy path ≈ 100 ms).
- **Hotkey debounce** (`HotkeyManager.handleHotkeyPressed`): a single physical press was delivered as 2+ `kEventHotKeyPressed` events within the same millisecond, causing a double-toggle; repeats within 250 ms are now dropped.

**Verifying the v0.2.4 dictation fix from logs (for the next agent).** The user runs the live test, then hands off; read the debug log and confirm the signatures below. The log only writes when **Developer Mode is on** — Settings → General → "Show Advanced Settings" ON, then Advanced tab → "Developer Mode" ON. Log path: `~/Library/Application Support/Heard/dict-debug.log`.

Pull the relevant lines:
```bash
grep -E "latencyMs|mic tap stalled|recovered after rebuild|throwing micStalled|onNoAudioCaptured|— debounced|firing onUtterance|TextInjector.inject" \
  ~/Library/Application\ Support/Heard/dict-debug.log | tail -80
```

What each fix should look like (and how to read pass/fail):
- **Healthy capture (fix #1/#4 baseline):** every start logs `appendSamples first buffer received — samples=… latencyMs=<N>`. On a healthy tap `N ≈ 50–200 ms`. Pre-fix failures showed multi-second gaps (e.g. `latencyMs=3527`, `11221`) with **no** recovery. A small `latencyMs` on every start = tap is delivering promptly.
- **Stall caught and recovered (fix #1 working):** if the tap stalls, you'll see `DictationManager.start mic tap stalled (<750ms no audio) — rebuilding engine once` immediately followed by `DictationManager.start mic tap recovered after rebuild`, and that session should then transcribe normally (`firing onUtterance` + `TextInjector.inject … axTrusted=true`). This is the success case — the bug self-healed instead of producing an empty paste.
- **Stall not recoverable (fix #1 degraded-but-visible):** `DictationManager.start mic tap still stalled after rebuild — throwing micStalled` means the mic is genuinely unavailable; the user sees the `micStalled` error (no silent dead-mic). If this recurs, suspect a device/HAL issue (input device, sample rate), not the app logic.
- **Empty result surfaced (fix #2 working):** `DictationManager firing onNoAudioCaptured — listenedFor=<N>s` (N ≥ 1.5) means a real session produced no text and the UI showed "No speech captured — please try again." Quick taps under 1.5 s intentionally stay silent and won't log this.
- **Hotkey debounce (fix #3 working):** duplicate presses now appear as `handleHotkeyPressed id=1 — debounced` instead of two `toggleDictation entered …` at the same timestamp (the second previously logged `toggleDictation dropped — inFlight=true`). Seeing `— debounced` lines = duplicates are being dropped earlier.

**Overall pass criteria:** across several start/stop cycles on real speech — small `latencyMs` every time, each session ends in `firing onUtterance` + a successful `TextInjector.inject … axTrusted=true`, text lands in the target app, and **zero** empty/silent results that aren't explained by a `recovered after rebuild`, `micStalled`, or `onNoAudioCaptured` line. Any unexplained empty transcript (no first buffer, no recovery line) means the stall guard isn't catching a case — capture the surrounding log window.

All items from the post-v0.2.2 robustness review are now resolved (see `ROADMAP.md` → Completed Technical Debt & Polish).

**Speaker labeling overhaul (post-v0.2.6, branch `claude/speaker-labeling-review-tgiikq`):**
- **Naming is now user-paced — countdown and auto-open removed.** The "Name Speakers" window no longer opens itself after a meeting and no longer auto-saves on a 120 s timer. Cues are the orange menu-bar badge, the "Name Speakers…" dropdown row, and a banner (with an open button) at the top of the Speakers settings tab. Closing the window means "later", not "skip" — candidates stay pending (in memory) and the window can be reopened; "Skip All" is the only path that persists placeholders. `onNamingRequired` now *appends* candidates so a second meeting's batch can't clobber a pending one, and `onPipelineIdle` restores `.userAction` (not `.dormant`) while candidates are pending. Pending candidates do not survive an app quit (clips live in `recordings/`, cleaned after 48 h).
- **No more unidentifiable speakers with dead play buttons.** (a) Candidates with no extractable clip are dropped before the prompt (transcript keeps the `Speaker N` label; no profile is created). (b) `skipNaming` no longer persists a placeholder whose clips failed to persist. (c) `SpeakerStore.pruneUnidentifiablePlaceholders()` runs at launch and deletes placeholder-named profiles with no clip file on disk (they're excluded from matching, so nothing of value is lost). (d) Roster-auto-assigned profiles now get up to two voice clips extracted straight into `speaker_clips/` (`PipelineProcessor.extractProfileClips`).
- **Speakers table: "Time in Meetings" is now sortable** (the column was missing its `value:` key path; Name/Meetings/Last Seen already worked).
- **"Split voices" replaces discard-only handling of merged clusters.** The pipeline computes a per-clip embedding for every extracted sample (`PipelineProcessor.perClipEmbeddings`: diarizer chunk embeddings overlapping the clip's region, VAD-mapped to original time, aggregated via `SpeakerEmbeddingAggregator`; carried on `NamingCandidate.clipEmbeddings`). In the naming window, a candidate with ≥ 2 samples offers "Split voices": `AppModel.splitCandidate` replaces it with one sub-candidate per clip (named `<placeholder> · voice N`), each carrying its clip-local embedding — never the polluted cluster centroid (empty if unavailable). The transcript keeps the original placeholder (segment-level re-attribution is impossible post-merge). "Discard" remains for hopeless candidates.
- **Naming a speaker with an existing profile's name now merges instead of duplicating**: `saveSpeakerName` folds the new embedding (via `SpeakerMatcher.addEmbedding`, extracted from `updateDatabase` and unit-tested) and clips into the case-insensitively matching non-placeholder profile, bumping stats; clips are capped at 5 per profile (oldest deleted from disk).
- **Roster N:N ordered auto-assignment removed.** Pairing sorted roster names to diarizer cluster order was a coin flip that wrote wrong name↔voice pairs into transcripts and poisoned profiles. Only the unambiguous 1:1 case still auto-assigns; multiple unknowns become suggestions in the naming prompt.
- Dead code removed: `AppModel.namingDismissTask` (never scheduled), `showNamingPrompt` (auto-open plumbing), unused `NamingCandidateRow` view.
- First pass verified green on macOS CI (run 165: build + full test suite).

**Speaker labeling follow-up (same branch, second pass):**
- **Speaking Time metric.** `SpeakerProfile.totalSpeakingTime` (backward-compatible decode, defaults 0 for old files) accumulates the sum of each speaker's *pre-merge* transcript segment durations — `mergeConsecutive` extends blocks across intra-speaker silence, so merged segments would overcount. Flows through `UnmatchedSpeaker` → `NamingCandidate` → profile creation/merge, and `SpeakerStore.updateStats` gained an `addSpeaking` field. New sortable "Speaking Time" column in the Speakers table ("Time in Meetings" retained; both use a shared `durationText` formatter: "2h 05m" / "14m" / "38s").
- **Pending naming candidates survive restart.** `NamingCandidate` is now Codable; `NamingCandidateStore` (`naming_candidates.json`) mirrors every change to `AppModel.namingCandidates` via `didSet` and reloads at bootstrap — dropping clips whose files are gone and whole candidates left clipless (same "can't listen → can't identify" rule as the pipeline). Pending clips are added to the stale-recordings-cleanup preserve set so the 48 h sweep can't strand them. Restored candidates re-raise the `.userAction` badge; `startWatching`/`stopWatching` no longer clobber it.
- **Voice match strictness is user-tunable.** `AppSettings.speakerMatchThreshold` (default 0.30, range 0.15–0.45) feeds `SpeakerMatcher.matchSpeakers(matchThreshold:)`; new Advanced → Voice Matching card (slider "Stricter" ↔ "Looser" + reset), parallel to the Diarization card. The confidence margin (0.10) remains a constant.
- **Roster suggestions are now honest.** Instead of pairing the *i*-th sorted roster name to the *i*-th candidate (arbitrary), every candidate carries the full unmatched-roster list (`NamingCandidate.suggestedNames`) rendered as tappable chips ("maybe: Alice · Bob …", capped at 3 + overflow count) that fill the name field; the field is only pre-filled when exactly one roster name is unmatched (the unambiguous case). Split parts inherit the parent's suggestions.
- **N-way merge.** "Merge Selected" now accepts 2+ profiles. The survivor is picked by `SpeakerMatcher.mergePrimary` (human-given name beats placeholder, then most meetings, then oldest `firstSeen` — unit-tested); one consent dialog covers all explicitly-named profiles being folded in (placeholders rewrite without asking). `SpeakerStore.merge` now also caps merged embeddings at `maxEmbeddingsPerSpeaker` and clips at 5 (overflow clip files deleted) and sums `totalSpeakingTime`.
- Tuple cleanup: the 5-field unmatched-speaker tuple threaded through `TranscriptDocument`/`AudioClipExtractor` is now the `UnmatchedSpeaker` struct.
- New tests: updateStats speaking time, merge caps/speaking sum, NamingCandidateStore round-trip + missing-clip pruning, custom match threshold, mergePrimary ordering.

**UI file split (tech debt):** the ~1.9 kLOC `Views.swift` was split by view area into `DesignSystem.swift`, `MenuBarView.swift`, `SpeakerNamingView.swift`, `SettingsView.swift`, `SettingsTabs.swift`, and `SettingsComponents.swift` (all in `Sources/HeardCore/`). Pure move — no logic or symbol changes; `swift build` is clean and all 181 tests pass.

**Transcript library ("Meetings" settings tab) added (2026-07-11, unreleased).** A searchable, sortable table of prior meeting transcripts; rows open the `.md` externally via `NSWorkspace.open` (no in-app rendering). Backend: `TranscriptLibrary` (`Sources/HeardCore/TranscriptLibrary.swift`) — `scan(directory:)` enumerates top-level `.md` files in the configured output folder (skipping hidden files and standalone `*_note.md`), `parseRecord` reads the first ~1 KB header (`# Title` / `**Date:**` / `**Duration:**` / `**Participants:**`) with filename-title + mtime fallback for malformed/pre-format files; newest-first sort; no index file or persistence. UI: `TranscriptLibraryView.swift`, wired as `SettingsTab.meetings` between Speakers and Advanced — search on title+participants, sortable columns, per-row Open + double-click, context menu (Open / Reveal in Finder / Move to Trash with confirmation), empty + missing-folder states, refresh on appear/output-dir change/manual button. The menu bar dropdown's old "Open Transcripts" (open folder) row was replaced by "Transcripts…" which deep-links to the tab. 7 new tests (`runTranscriptLibraryTests`); 212 total pass. Built via two delegated workstreams (Antigravity/Gemini 3.1 Pro High) against a frozen API contract; plan at `plans/transcript-library.md`.

**AX-tree-wake root cause found + fixed, plus a new opt-in meeting-chat-scraping feature (post-v0.2.6, unreleased).** A real Teams meeting confirmed the tree-wake nudge was failing with `setErr=-25205` (`kAXErrorAttributeUnsupported`), not the `-25211` the original fix assumed. Root cause (confirmed via electron/electron#37465, cross-checked with a second opinion from an independent Antigravity/agy investigation run through the `delegate` skill): `AXManualAccessibility` never actually works on current Electron builds — Electron doesn't advertise the attribute in `accessibilityAttributeNames`, so the set is rejected before Chromium's tree-builder ever sees it. This affects any Electron app, not just Teams, and isn't fixable from Heard's side.

- **Fix:** `enableMeetingAppAccessibility` now falls back to the private `AXEnhancedUserInterface` attribute (the same one VoiceOver sets) whenever `AXManualAccessibility` fails; it logs `setErr=<n> fallbackSetErr=<n>` so a future log capture shows which path actually woke the tree. `AXEnhancedUserInterface` is confirmed (both via the Electron issue thread and agy's independent research) as the standard, low-risk way third-party AX tools coexist with Electron on macOS — no realistic risk of Microsoft treating it as automation abuse. It does have side effects on the *target app* while set (reported: altered window positioning/sizing, interference with tools like Rectangle/Magnet, and possibly disabled UI animations) — so `disableMeetingAppAccessibility` unsets it again on every meeting-end path (`stopWatching`, disabled-mid-meeting, and normal `.endMeeting`). **Still needs a second real-meeting confirmation** that this actually resolves `titleRefreshed`/roster population end to end — the fallback logic itself is unit-untestable (it's a live AX side effect), so this can only be confirmed from `dict-debug.log` on a real call.
- **New: opt-in Teams-chat scraping, interleaved into the transcript.** `ChatReader.swift` mirrors `RosterReader`'s identifier-heuristic pattern (ships with only the identifier-search strategy — no generic "any list" fallback, to avoid a false-positive match against the roster panel) and is polled from the same 15 s roster-poll tick, gated behind a new `AppSettings.includeMeetingChat` toggle (**default OFF** — a considered call, not an oversight: unlike the roster (names only) or in-meeting notes (the user's own words), this passively captures other participants' written words without their per-message consent, which agy's review flagged as a real enterprise-IT/compliance risk if defaulted on). New `ChatMessage` model (offsetSeconds/sender/text) follows the exact `MeetingNote` carry-through pattern: `RecordingSession.chatMessages` → `RecordingManager.updateChatMessages` (dedups by exact sender+text against everything already captured, stamping `offsetSeconds` as "now" since Teams' AX tree doesn't reliably expose per-message send times) → `PipelineJob.chatMessages` → `TranscriptDocument.chatMessages` → `TranscriptWriter.renderBody` (rendered as `_**Chat — <Sender>:** ...text..._`, interleaved chronologically alongside segments and notes). Settings UI: new "Meeting Chat" section in the Recording tab.
  - **Known, documented limitations** (see `ChatReader`'s doc comment): Electron's chat list is virtualized/lazy-rendered, so only on-screen messages ever reach the AX tree — scrollback and messages sent while the panel is closed are unreachable, permanently. Dedup is exact (sender, text) match, so a genuinely repeated identical short message ("yes", "+1") from the same sender is only captured once. Message edits/deletes are not reflected. **Real AX identifiers for Teams' chat pane are still unknown** — `chatIdentifiers` in `ChatReader.swift` are best-guess placeholders; `ChatReader.diagnosticTreeDump` (reuses `RosterReader`'s dump core) is the tool to retune them from once a real meeting has the chat panel open during the same diagnostic session as the AX-wake retest above.
  - 7 new tests (`runChatReaderTests` + chat-interleaving cases in the transcript-writer tests); all 196 tests pass, `swift build` clean.
  - This workstream was validated mid-flight by an independent Antigravity CLI (`agy`) investigation, launched via the `delegate` skill for a second opinion on both the AX-fix root cause and the chat-scraping design (privacy default, dedup approach, virtualization gotchas) before implementation — see conversation history for the full report.

## What's Working

### Meeting Detection
- Polls `IOPMCopyAssertionsByProcess()` every second for meeting-app power assertions (2 consecutive hits = ~2 s start latency, per spec)
- Extracts meeting title from Teams window via Accessibility API (`AXUIElement`)
- Debounce/cooldown logic lives in the pure `MeetingDetectionState` value type — 2 consecutive detections to start, 5s cooldown after end — so the state machine is driven by tests without IOKit
- Simulation mode available for testing without a real Teams call (with `isSimulated` flag to prevent polling interference)

### Audio Capture
- **App audio**: `CATapDescription` process tap on all Teams-related PIDs (main + helpers), routed through a private aggregate device + `AudioDeviceCreateIOProcIDWithBlock`, recorded to WAV (32-bit float non-interleaved PCM)
- **Microphone**: Separate `AVAudioEngine` instance recording to WAV
- Both tracks saved to `~/Library/Application Support/Heard/recordings/`
- Mic delay calibration stored per session for alignment
- 4-hour max recording duration with automatic split and re-start
- Temp file cleanup on app launch (removes stale `.wav` files older than 48 hours)
- Orphan aggregate-device cleanup on app launch (destroys any `com.execsumo.heard.tap.*` private aggregate devices left behind by a crashed recording)
- **Tap UID**: `tapDesc.uuid = UUID()` is set on `CATapDescription` before calling `AudioHardwareCreateProcessTap`; `tapDesc.uuid.uuidString` is used directly in the aggregate device's tap list — avoids the silent failure path of querying `kAudioTapPropertyUID` via `AudioObjectGetPropertyData` after the fact
- **IOProc instead of AUHAL**: `AudioDeviceCreateIOProcIDWithBlock` is called directly on the aggregate device (dispatched to a serial queue so CoreAudio copies buffers before dispatch). The tap delivers interleaved stereo float32; the IOProc deinterleaves into `AVAudioPCMBuffer` matching `AVAudioFile.processingFormat` (non-interleaved float32) before writing
- **Diagnostic logging** (`log show --last 1m --predicate 'process == "Heard"' --info`): default output device + sample rate at start; default-output-change warnings; IOProc stats every 10s (cycles, frames, non-zero %, peak/RMS in dB); silence warnings distinguishing "no callbacks fired" vs "callbacks firing but all-zero samples"
- **Recording self-test + one-shot recovery**: at T+2s, the monitor checks whether non-zero samples have arrived. If silent, it tears down and rebuilds the tap/aggregate/IOProc once with fresh helper-process enumeration. If the rebuild's self-test still fails, the recording is flagged `appAudioTapFailed` and the menu bar shows "Recording (mic only)".
- **`stopWatching` ends the active meeting**: toggling watching off mid-meeting fires `onMeetingEnded` synchronously so the recording stops and the transcript pipeline runs. `AppModel.stopWatching` preserves the resulting `.processing` phase instead of overwriting it with `.dormant`.
- **TCC permissions required**: Microphone (`NSMicrophoneUsageDescription`), System Audio Capture (`NSAudioCaptureUsageDescription`), Screen Recording (`NSScreenCaptureUsageDescription`), Accessibility (`NSAccessibilityUsageDescription`) — all four must be granted. Use `./scripts/bundle.sh --reset` to clear all four TCC grants and reinstall cleanly.
- **Screen Recording grant caching**: the grant persists in UserDefaults (`screenCaptureTCCGranted`) so it survives macOS 15's stale `CGPreflightScreenCaptureAccess()` on fresh launches. The cache is reconfirmed after launch via `ScreenCaptureGrantCache` (pure, tested state machine in `Services.swift`): a grant cached from a previous session is trusted for a ~30 s grace window (10 probes × 3 s poll) and cleared if probes keep failing — covering revocation while the app wasn't running. A grant confirmed live within a session is never downgraded (revocations only take effect after restart); an authoritative `SCShareableContent` false (post-"Grant…" check) clears the cache immediately.

### Pipeline (Fully Implemented)
- Sequential job queue with stages: queued → preprocessing → transcribing → diarizing → assigning → complete
- **Preprocessing**: Resample to 16kHz mono via `AudioConverter`, Silero VAD silence trimming, `VadSegmentMap` for timestamp remapping
- **Transcription**: Parakeet TDT V2/V3 (user-selectable) via `AsrManager` with 16k sample minimum guard. Each transcribe call uses a fresh `TdtDecoderState`, so no context bleeds between tracks or jobs. Always passes `language: .english` — required by FluidAudio 0.14.x to keep v3 from emitting Cyrillic for short Latin-script utterances; ignored by v2.
- **Diarization**: `OfflineDiarizerManager` on app track only (mic track is a single known speaker, diarization was unused). Clustering parameter is user-configurable via `AppSettings.diarizationClusteringSimilarity` (default 0.65, range 0.40–0.85 in 0.05 steps; FluidAudio's library default is 0.60). FluidAudio's `OfflineDiarizerConfig(clusteringThreshold:)` is actually a cosine *similarity* — AHC merges when cos_sim ≥ threshold, so higher = stricter separation, more clusters. The 0.65 default biases toward over-splitting because merging in the Speakers tab is easier than recovering a polluted embedding.
- **Speaker Assignment**: Cosine distance matching against `SpeakerStore`, confidence margin filtering, embedding diversity management
- Non-retryable errors (no audio, too short) fail immediately; transient errors retry 3x per session with backoff (5s, 30s, 5min) via `PipelineProcessor.executeWithRetry` (closure-driven, testable)
- `retryCount` is cumulative across sessions with a lifetime cap of 6 (`PipelineProcessor.lifetimeRetryLimit`). User-initiated retry (`retryFailedJob`) resets `retryCount = 0` for a fresh budget.
- Jobs persist to JSON and survive app restart. `PipelineQueueStore.prepareForResume()` runs at launch: failed/mid-stage jobs (orphaned by crash) are re-queued if `retryCount < lifetimeRetryLimit`; jobs at/above the cap stay `.failed` until the user explicitly retries.
- Pipeline fires `onPipelineIdle` callback so app phase returns to dormant
- Markdown transcript output with timestamped speaker-labeled segments

### Custom Vocabulary Boosting
- FluidAudio 0.13.6+ removed `configureVocabularyBoosting` from batch `AsrManager` — it now only exists on `SlidingWindowAsrManager` (used by Dictation)
- Batch pipeline applies vocabulary via post-processing rescoring in `PipelineProcessor.applyVocabularyBoosting`: runs `CtcKeywordSpotter.spotKeywordsWithLogProbs` over the same 16 kHz samples to compute log-probs, then `VocabularyRescorer.ctcTokenRescore` rewrites low-confidence words from the user's `customVocabulary` against the saved `ASRResult.tokenTimings`. The rescored text replaces the original via `ASRResult.withRescoring`
- Best-effort: any failure (CTC model not downloaded, tokenizer load failure, missing tokenTimings) is logged and the original transcript is kept — vocab boosting never fails the pipeline
- Requires the user to download the CTC 110M model from the Models tab; without it, vocabulary terms are stored but not applied

### Model Management
- `ModelDownloadManager` pre-downloads all 4 model sets (VAD, Parakeet, Diarizer, CTC 110M) via FluidAudio
- Streaming EOU model (160ms) also downloadable from Dictation settings tab
- Status detection checks FluidAudio's actual cache paths (`~/Library/Application Support/FluidAudio/Models/`)
- Progress tracking per model during download
- Models auto-download on first meeting if not pre-downloaded

### In-Meeting Notes
- During an active recording, the user can press a global hotkey (default Ctrl+Shift+N, configurable in Settings → General → Meeting Notes) to open a small floating composer panel.
- Composer is an `NSPanel` subclass overriding `canBecomeKey` so the text editor takes focus immediately; first keystroke goes into the field. Return saves, Cmd+Return inserts a newline, Esc cancels. The text field is a custom `NSViewRepresentable` (`NoteTextEditor`/`NoteNSTextView`) that intercepts key events at the AppKit level — SwiftUI's `onKeyPress` is not used because `TextEditor`'s underlying `NSTextView` consumes Return before SwiftUI sees it.
- The note's recording-relative timestamp is captured at panel-open time (not submit time), so a slow typer's note still anchors to when they reacted.
- Notes are stored on `RecordingSession.notes` while the meeting is in progress; carried into the `PipelineJob` when recording stops; persisted in `pipeline_queue.json` (with backwards-compat decoding for pre-feature queue files).
- If the user submits *after* the meeting has ended, `PipelineProcessor.attachNoteToFinishedJob(at:text:)` finds the matching enqueued/processing job by wall-clock time and attaches there instead.
- `TranscriptWriter.renderBody` interleaves notes with spoken segments by timestamp and renders them as `[mm:ss] _**Note from <userName>:** ...text..._` (italicized, distinct from `**Speaker:**` blocks). Empty `userName` falls back to `Me` — same convention as the mic-track speaker label.
- `HotkeyManager` was refactored to support multiple hotkeys: each manager owns a unique `id` (1 = dictation, 2 = notes), all sharing one Carbon event handler that dispatches by `EventHotKeyID`.
- Hotkey-pressed with no active recording: opens a standalone composer (no elapsed-time offset shown). On save, writes a Markdown file named `yyyy-MM-dd_HH-mm-ss_note.md` to the user's configured output folder. Write failures surface as `errorMessage` + a beep.

### Meeting Chat Scraping (opt-in, built but not yet verified against a real meeting)
- Off by default (`AppSettings.includeMeetingChat`, Settings → Recording → Meeting Chat). Deliberately not automatic like the roster/notes — see the dated status entry above for why.
- `ChatReader.readChatMessages(pid:)` walks the same woken Teams AX tree as `RosterReader`, polled from the existing 15 s roster-poll tick (`MeetingDetector.startRosterPolling`) only when the setting is on.
- `RecordingManager.updateChatMessages(_:)` dedups incoming (sender, text) pairs against everything already captured for the session and stamps `offsetSeconds` as "now" relative to the recording start.
- `TranscriptWriter.renderBody` interleaves chat chronologically alongside segments and notes: `[mm:ss] _**Chat — <Sender>:** ...text..._`.
- **Not yet validated against real Teams output** — `ChatReader`'s identifiers (`chat-pane-list`, `message-list`, etc.) are best-guess placeholders, same starting position `RosterReader` was in before its first real-meeting tree dump. Use `ChatReader.diagnosticTreeDump(pid:)` (reuses `RosterReader`'s dump core) on the next real meeting with the chat panel open to retune them.

### Dictation (Fully Working)

The dictation feature captures mic audio, transcribes in real-time, and injects text into the focused app via CGEvent unicode insertion. Requires Accessibility permission granted to a stable-signed build.

#### What's built:
- **`DictationManager.swift`**: Uses `SlidingWindowAsrManager` (FluidAudio's proper streaming ASR) with the `.streaming` config preset. Audio is passed as `AVAudioPCMBuffer` directly via `streamAudio()`; the manager handles overlapping windows, format conversion, and stable/volatile split internally. Confirmed text is injected incrementally via `injectDelta`; any unconfirmed volatile text is flushed on stop via `finish()`. Standalone `AVAudioEngine` for mic (independent of `RecordingManager`). Model keep-alive of 120s after stop. Custom vocabulary boosting is wired via `configureVocabularyBoosting()` when CTC models are downloaded. Punctuation normalization (ITN) is applied natively to deltas before text injection. We pass `TdtConfig(blankId: modelVersion.blankId)` directly using FluidAudio 0.14.7's `.applying(tdtConfig:)` API to ensure v2/v3 models are configured natively with correct blank tokens.
- **Auto-pause on meeting start**: `AppModel.stopDictationIfActive()` is called from `onMeetingStarted` before recording begins. This prevents the dictation mic engine from picking up remote participants' audio through speakers and injecting it as text into the focused app. Dictation does not auto-resume when the meeting ends — the user must restart it manually.
- **Push-to-talk race condition fixed**: `AppModel` tracks a `pushToTalkKeyHeld` flag (set on press, cleared on release). After `DictationManager.start()` completes (which can take several seconds on first use due to model loading), `toggleDictation()` checks whether the key is still held. If the key was released before loading finished, dictation is stopped immediately, preventing it from becoming stuck on.
- **`TextInjector.swift`**: CGEvent unicode insertion via `keyboardSetUnicodeString` + `postToPid` (same approach as FluidVoice). Falls back to HID tap, then clipboard paste. All methods require Accessibility permission.
- **`HotkeyManager.swift`**: Carbon `RegisterEventHotKey` for global Ctrl+Shift+D hotkey. Does NOT require Accessibility permission. Supports configurable hotkey combos stored in `AppSettings`. Function keys (F1–F20) are allowed as hotkeys without a modifier key — the `HotkeyRecorderView` validator skips the modifier-required check for function key codes.
- **Global hotkey**: Working. Ctrl+Shift+D toggles dictation on/off from any app.
- **Mic capture**: Working. Tap installed at the bus's native format; one `AVAudioConverter` handles both stereo→mono downmix and any-rate→16 kHz resampling in the callback (proper polyphase filter, not linear interpolation).
- **Speech recognition**: Working perfectly. Tested transcriptions: "Alright, did Claude figure it out this time? Beep bop boop.", "Is this working now?", etc.
- **Text diffing**: Working. Only injects new words, not the full retranscription.
- **UI**: Dictation settings tab with enable toggle, hotkey display, model download card, Accessibility warning, live status. Menu bar shows dictation state.

### UI
- **Paper design system** — full visual reskin applied. 20-token warm "Paper" palette (`bg #F5EFE4`, `surface #FBF7EF`, `surfaceAlt #EFE7D7`, `sidebar #EBE2CE`, `accent #3F5C8C`, `good/warn/bad` soft tints, dark recording strip `recordingBg #2E3338`). All windows and sheets force light-only appearance via `preferredColorScheme(.light)`.
- **Custom sidebar** — `NavigationSplitView` replaced with a manual `HStack` (188 px sidebar + detail pane) for full color control. `HeardMark` squircle glyph (Canvas-drawn: warm gradient bg, dark bubble, three-dot motif) in sidebar header and About tab.
- **Card-based settings layout** — `SettingsCard`/`CardRow`/`ToggleRow` primitives replace `Form`/`.formStyle(.grouped)`. `HeardToggleStyle` (30×18 px pill, accent on / muteSoft off). `StatusDot` with 13 px glow-ring pulse animation.
- Menu bar dropdown (268 px wide) with status card (dark `#2E3338` bg while recording/dictating, Paper bg otherwise), recording timer, and quick actions
- Menu bar icons are SF Symbols with symbol effects (`recordingtape`, `record.circle` + `.breathe`, `waveform` + `.variableColor`, `exclamationmark.circle.fill`, `person.crop.circle.badge.exclamationmark`)
- **Menu bar reactivity fix**: `MenuBarView` holds direct `@ObservedObject` subscriptions to `queueStore`, `recordingManager`, `pipelineProcessor`, and `meetingDetector` — required because `MenuBarExtra(.window)` does not reliably re-render from forwarded child-store `objectWillChange` events. `MeetingDetector` is now an `ObservableObject` with `@Published isWatching`; `MenuBarIcon` subscribes directly so the paused/dimmed state reflects toggles immediately. `PipelineProcessor.runNextIfNeeded` also recovers orphaned non-terminal jobs (left in mid-stage when the processor is idle) by re-queuing them, charging a retry against the lifetime cap.
- Settings window (880×600, opened via `@Environment(\.openWindow)`) with 6 tabs: **General** (launch at login, auto-watch, developer mode, custom vocabulary, output folder, permissions, meeting notes hotkey), **Transcription** (model download status, pipeline keep-alive, force-unload), **Dictation** (enable, push-to-talk, hotkey recorder, model keep-alive, custom formatting commands, live status), **Speakers** (your name, inline rename, merge, delete, search/sort), **Advanced** (diarization clustering threshold slider with "More speakers" ↔ "Fewer speakers" labels, voice match strictness slider with "Stricter" ↔ "Looser" labels, live numeric readouts, reset-to-default), **About**
- Standalone "Name Speakers" window scene (id `speaker-naming`, 560×520) with per-candidate audio playback, roster suggestions, and per-candidate Split voices / Discard actions — user-paced, no countdown
- Keyboard input works in Settings — `WindowActivationCoordinator` reference-counts `.accessory`/`.regular` transitions across the Settings and Name Speakers windows so closing one while the other is still open never steals keyboard focus
- Output folder picker via `NSOpenPanel`
- Custom vocabulary management lives in the General tab (add/remove terms, 3-char min, 50-term cap) — terms applied to both transcription and dictation via CTC boosting
- Custom formatting commands live in the Dictation tab (map spoken phrases like "new paragraph" to written text like `\n\n`) — applied to both transcription and dictation via ITN rules
- Speaker table with inline rename, N-way merge, delete (context menu), search, and sort (Name / Meetings / Time in Meetings / Speaking Time / Last Seen); a leading **Voice** column has a play/stop button that replays the speaker's saved voice clip via a shared `SpeakerClipController` so only one clip plays at a time
- Model download status with progress bars and per-card download buttons, plus a "Download All Models" shortcut
- Permission status with grant buttons and System Settings deep-links (Microphone + Screen Recording + Accessibility), surfaced inside the General tab
- Launch at login via `SMAppService`
- Quit button in menu bar dropdown

### Accessibility Roster Scraping
- `RosterReader.swift` reads Teams participant names via macOS Accessibility APIs (`AXUIElement`)
- Three fallback strategies: identifier-based search → container search → window title parsing (all via AX API)
- Filters out UI control strings (mute, unmute, raise hand, etc.)
- Polled every 15 seconds during active meetings to accumulate participant names
- Used for automatic speaker name assignment when diarization detects unmatched speakers

### Speaker Naming Prompt (Fully Working)
- Dedicated "Name Speakers" window, **user-initiated** — opened from the menu bar dropdown ("Name Speakers…" row, orange badge) or the Speakers settings tab banner; it does not auto-open and there is no countdown. Candidates stay pending until the user saves, skips, splits, or discards them; closing the window keeps them pending, and pending candidates persist across app restarts (`naming_candidates.json`).
- Each unmatched speaker shows **playable audio clips** (up to 3 × ~10s of their clearest speech from diarization). Speakers with no extractable clip never reach the prompt — a voice the user can't hear can't be identified.
- Audio playback via `AVAudioPlayer` with play/stop toggle per speaker
- Suggested names from the Teams roster when available: every unmatched roster name is offered on every candidate as tappable chips that fill the name field (no arbitrary name↔voice pre-pairing); the field is pre-populated only when exactly one roster name is unmatched
- **"Save & Close"** commits all entered names and dismisses the window via `dismissWindow(id: "speaker-naming")`; **"Skip All"** saves remaining unnamed speakers with `Speaker N` labels and dismisses
- **"Split voices"**: when a candidate's samples are different people (diarization merged two voices into one cluster), a per-row button splits it into one sub-candidate per clip, each carrying a clip-local embedding, so each voice can be named separately. **"Discard"** drops a candidate without creating a `SpeakerProfile` (clips deleted immediately; transcript keeps the placeholder label).
- Speaker profiles created with voice embeddings from diarization, enabling future recognition. Naming a candidate with an existing profile's name merges into that profile instead of duplicating it.
- **No duplicate "Speaker N" profiles**: `SpeakerMatcher.updateDatabase` only refreshes already-matched profiles. Roster-auto-assigned new speakers get a profile with the resolved name in `runSpeakerAssignment`. Unresolved new speakers are persisted exactly once — by `saveSpeakerName` (real name) or `skipNaming` (`Speaker N`, only when a clip persisted).
- **Globally unique "Speaker N" numbering**: `SpeakerStore` previously used a monotonic counter, but now assigns unique `UUID`-based placeholders (e.g. `Speaker_1AB23C`). This avoids collisions entirely across installations and ensures renaming safely affects only the right transcripts.
- **Transcript files are rewritten with real names**: `NamingCandidate` carries the meeting's `transcriptPath`. `saveSpeakerName` calls `TranscriptWriter.renameSpeakerInDirectory(_:from:to:)` to scan every `.md` in the configured output directory and rewrite both `**Speaker N:**` body tags and the `**Participants:**` header line. With UUID-based placeholder numbers this safely catches and updates old transcripts.
- **Cumulative transcription stats**: Every time the pipeline successfully assigns speakers to speech segments, `SpeakerStore` accurately accumulates that speaker's `totalSpeechDuration` and `totalWordCount`, visible in the Settings tab.
- **Clips persist for replay**: clips are extracted to `recordings/` during the prompt, then moved to the persistent `speaker_clips/` directory by `AudioClipExtractor.persistClip` when the user saves (or skips) and stored on `SpeakerProfile.audioClipURLs`. They survive the 48-hour stale-recording cleanup and power the play button in the Speakers settings tab. Deleting a speaker also deletes its persisted clips.
- `AudioClipExtractor.swift` handles WAV segment extraction from original 48kHz recordings
- Menu bar shows "Name Speakers..." button and orange badge icon during `.userAction` phase
- Window also accessible from menu bar dropdown if dismissed

### App Bundle
- `Info.plist` with `LSUIElement` (menu bar app), `NSMicrophoneUsageDescription`, bundle ID `com.execsumo.heard`, `CFBundleIconFile = AppIcon`
- `Heard.entitlements` with audio-input only (no sandbox per spec)
- `Resources/AppIcon.iconset/` ships 16/32/128/256/512 PNG pairs; `bundle.sh` runs `iconutil -c icns` to compile `AppIcon.icns` into the bundle. Settings → About displays the real bundle icon via `NSApp.applicationIconImage`
- `scripts/bundle.sh` builds via SPM, creates `.app` bundle, auto-signs with the `Developer ID Application` cert if available, else `Dev Cert`, else ad-hoc. When the identity is a `Developer ID Application:` cert, automatically adds `--options runtime --timestamp` (required for notarization); self-signed local certs are left unchanged.
- Flags: `--release`, `--sign IDENTITY`, `--output DIR`, `--install` (quit running app, replace `/Applications/Heard.app`, relaunch — anchors TCC grants to a stable path), `--reset` (also `tccutil reset` Microphone/ScreenCapture/Accessibility before install — implies `--install`)
- `scripts/dmg.sh` — distribution pipeline: release build → zip → notarize `.app` via `xcrun notarytool` → staple → create DMG with `/Applications` symlink → sign DMG → notarize DMG → staple DMG → print SHA256. Uses `--keychain-profile heard-notary` (stored via `notarytool store-credentials`). Pass `--skip-notarize` for local testing.
- **v0.1.0 released**: `dist/Heard-0.1.0.dmg` (notarized, stapled). GitHub Release at `github.com/execsumo/Heard/releases/tag/v0.1.0`. Homebrew tap at `github.com/execsumo/homebrew-tap` (`brew tap execsumo/tap && brew install --cask heard`).

### Testing
- `HeardTests` executable target with 196 tests across: VadSegmentMap, cosine distance, SpeakerMatcher (incl. threshold/margin edge cases), SegmentMerger, AudioPreprocessor, TranscriptWriter (incl. chat/note interleaving), SpeakerStore, PipelineQueueStore, pipeline resume/recovery (`prepareForResume`), meeting detection state machine (`MeetingDetectionState`), retry executor (`PipelineProcessor.executeWithRetry`) incl. lifetime cap, Teams identification, MeetingDetector lifecycle, RosterReader (window-title parser + filter + AX traversal), and ChatReader (AX traversal)
- Custom lightweight test harness (no XCTest/Xcode dependency). `test(...)` for sync, `testAsync(...)` for async bodies
- Run with `swift run HeardTests`

### Persistence
- `SettingsStore`: UserDefaults-backed app settings (includes `dictationEnabled`, `dictationHotkey`, `speakerRetentionDays`)
- `SpeakerStore`: JSON file at `~/Library/Application Support/Heard/speakers.json` — `SpeakerProfile` now carries an optional `audioClipURL` pointing into `speaker_clips/`
- `PipelineQueueStore`: JSON file at `~/Library/Application Support/Heard/queue.json`
- `~/Library/Application Support/Heard/speaker_clips/`: persistent voice samples for replay (kept beyond the 48-hour `recordings/` cleanup)

### Speaker Archive
- `SpeakerStore.archiveInactiveSpeakers(retentionDays:)` deletes profiles whose `lastSeen` is older than N days (and their audio clips). Called at app launch via `AppModel.bootstrap()`.
- Default is 90 days; configurable via `AppSettings.speakerRetentionDays` (0 = never). UI in Advanced → Speaker Archive (Picker: Never / 30 / 60 / 90 / 180 / 365 days).
- Also fixed a pre-existing extraneous `}` in `Views.swift` that was causing the file to fail to compile (struct `SettingsView` was closing one brace too early, pushing pane-helper functions out of scope).

## Architecture

| Target | Purpose |
|--------|---------|
| `HeardCore` (library) | All models, services, views, stores |
| `Heard` (executable) | App entry point, imports HeardCore |
| `HeardTests` (executable) | Test runner, imports HeardCore |

| File | Purpose |
|------|---------|
| `Package.swift` | SPM config, macOS 15.0+, FluidAudio dependency |
| `Sources/Heard/MTApp.swift` | `@main` entry, MenuBarExtra + Window scenes |
| `Sources/HeardCore/AppModel.swift` | Central state, action handlers, lifecycle, dictation wiring |
| `Sources/HeardCore/CoreModels.swift` | AppPhase, PipelineJob, SpeakerProfile, AppSettings, HotkeyCombo, etc. |
| `Sources/HeardCore/Services.swift` | MeetingDetector, RecordingManager, PipelineProcessor, PermissionCenter, TranscriptWriter, TempFileCleanup, AudioDeviceCleanup, LaunchAtLogin, WindowActivationCoordinator |
| `Sources/HeardCore/Stores.swift` | SettingsStore, SpeakerStore, PipelineQueueStore, FileManager extensions |
| `Sources/HeardCore/DesignSystem.swift` | Paper palette tokens, `SettingsCard`/`CardRow`/`ToggleRow`/`StatusDot`/`HeardMark` and shared layout primitives |
| `Sources/HeardCore/MenuBarView.swift` | MenuBarView, dropdown rows/headers, menu-bar icon |
| `Sources/HeardCore/SpeakerNamingView.swift` | "Name Speakers" window + per-candidate audio playback cells |
| `Sources/HeardCore/SettingsView.swift` | Settings window shell + sidebar navigation |
| `Sources/HeardCore/SettingsTabs.swift` | General/Recording/Dictation/Speakers/Advanced/About tab bodies |
| `Sources/HeardCore/SettingsComponents.swift` | Reusable settings rows (`MicrophonePickerRow`, `HotkeyRecorderView`, …) |
| `Sources/HeardCore/AudioProcessing.swift` | AudioPreprocessor, VadSegmentMap, PreprocessedTrack |
| `Sources/HeardCore/SpeakerAssignment.swift` | SpeakerMatcher, SegmentMerger, cosineDistance |
| `Sources/HeardCore/AudioClipExtractor.swift` | Extract speaker audio clips from WAV for naming prompt |
| `Sources/HeardCore/ChatReader.swift` | Opt-in AX scrape of the meeting app's chat panel (`ChatMessage`, interleaved into transcripts) |
| `Sources/HeardCore/ModelDownloadManager.swift` | Pre-download manager for FluidAudio models |
| `Sources/HeardCore/DictationManager.swift` | Real-time dictation engine (batch ASR + polling loop) |
| `Sources/HeardCore/TextInjector.swift` | Text injection via CGEvent unicode insertion |
| `Sources/HeardCore/HotkeyManager.swift` | Global hotkey via Carbon RegisterEventHotKey (multi-hotkey registry, dispatched by `EventHotKeyID`) |
| `Sources/HeardCore/MeetingNoteComposer.swift` | Floating `NSPanel` composer for in-meeting notes |
| `Info.plist` | App bundle metadata |
| `Heard.entitlements` | Audio input entitlement |
| `scripts/bundle.sh` | Build + bundle script (auto-enables hardened runtime for Developer ID certs) |
| `scripts/dmg.sh` | Release DMG pipeline: build, sign, notarize, staple, package |

## Next Steps

See [`ROADMAP.md`](./ROADMAP.md) for the full list of planned improvements, organized by near-term polish, mid-term features, long-term bets, and technical debt. The highlights:

### 1. Distribution (done for v0.1.0)
- ✅ DMG packaging — `scripts/dmg.sh` (build, sign, notarize, staple, package)
- ✅ GitHub Release — `github.com/execsumo/Heard/releases/tag/v0.1.0`
- ✅ Homebrew Cask — `brew tap execsumo/tap && brew install --cask heard`
- ✅ CI pipeline — `.github/workflows/ci.yml` builds + tests on all pushes; on tag push, builds a release bundle, zips with `ditto`, and uploads to GitHub Releases via `softprops/action-gh-release`. Notarization is stubbed (commented) pending Apple Developer secrets (`APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`).
- ✅ Update checker — `UpdateChecker` polls `api.github.com/repos/execsumo/Heard/releases/latest` at startup (rate-limited to once per 24 hours). When a newer version is detected, a banner appears in the menu bar dropdown and in Settings → About with a link to the GitHub release. No new dependencies; no auto-install (user re-runs the DMG or `brew upgrade --cask heard`).

### 2. Known rough edges
- Menu bar dropdown uses `.window` style and has a fixed max height — jobs list can clip when many jobs accumulate
- Dictation does not auto-resume after a meeting ends (auto-pauses on meeting start; user must restart manually)
- Teams detection only matches localized app names — non-English macOS locales may miss Teams

## Attempted Approaches for Dictation (Historical)

These approaches were tried and failed, documented here to prevent re-attempting:

### Hotkey implementations (settled on Carbon)
1. **NSEvent global/local monitors**: Can observe but not suppress key events — causes macOS error sound on every hotkey press. Abandoned.
2. **CGEvent tap (`CGEvent.tapCreate`)**: Requires Accessibility permission which gets invalidated on every ad-hoc rebuild. Abandoned.
3. **Carbon `RegisterEventHotKey`**: No Accessibility permission needed. Working perfectly. This is the current implementation.

### Text injection attempts (all require Accessibility)
1. **CGEvent Cmd+V paste** (`post(tap: .cghidEventTap)`): Requires Accessibility
2. **CGEvent Cmd+V paste** (`post(tap: .cgSessionEventTap)`): Requires Accessibility
3. **AppleScript System Events**: Requires Automation permission, blocked for ad-hoc apps (error -1743)
4. **CGEvent unicode insertion** (`keyboardSetUnicodeString` + `postToPid`): Requires Accessibility — current implementation, will work once AX permission is granted

## Known Issues

- ~~**Custom vocabulary is a no-op**~~: Resolved — dictation uses `SlidingWindowAsrManager.configureVocabularyBoosting`; batch transcription uses post-processing CTC rescoring (`CtcKeywordSpotter` + `VocabularyRescorer.ctcTokenRescore` + `ASRResult.withRescoring`) inside `PipelineProcessor.applyVocabularyBoosting`. Both require the CTC 110M model to be downloaded.
- **TCC permissions on rebuild**: macOS ties Screen Recording / Accessibility grants to the code signature *and* the bundle path. Each rebuild changes the CDHash, and a copy in `build/` is treated as a different app from one in `/Applications/`. Use `./scripts/bundle.sh --install` to anchor to `/Applications/Heard.app`, or `--reset` to also wipe TCC grants first. After granting, **fully Quit Heard from the menu bar and relaunch** — Screen Recording grants do not propagate to a process that was already running.
- Running via `swift run` in a terminal causes macOS to attribute microphone permission to the terminal app (e.g., Ghostty) rather than Heard. Use `./scripts/bundle.sh && open build/Heard.app` instead.
- The `.window` style MenuBarExtra panel has a fixed max height; if many jobs accumulate, the bottom of the panel may clip.
- Simulated meetings produce very short recordings that fail in the pipeline (expected — they exist for UI testing, not audio testing).
