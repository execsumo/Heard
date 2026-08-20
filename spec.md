# Meeting Transcriber v2 — Full Implementation Specification

## Overview

Build a macOS menu bar application that automatically detects native meetings (Microsoft Teams, Zoom, Webex), records dual-source audio (app + microphone), transcribes speech on-device using CoreML models on the Apple Neural Engine, identifies speakers via diarization and persistent voice profiles, and outputs clean Markdown transcripts.

Everything runs on-device. There is no cloud dependency, no LLM integration, no external API. The app is invisible by design — it launches at login, sits in the menu bar, and handles meeting documentation silently.

---

## Architecture

### Process Model

Single-process architecture. The menu bar app hosts everything: UI, meeting detection, recording, and the processing pipeline. CoreML inference runs on background `Task`s off the main actor.

**Why not XPC:** XPC adds significant engineering cost (protocol definitions, connection lifecycle, cross-process debugging) for marginal benefit. CoreML crashes are rare on Apple's stable frameworks. Memory spikes during processing are brief (models load, run, unload) and tolerable on modern Macs. The pipeline queue JSON already provides crash recovery — if the app crashes mid-processing, it resumes from the last completed stage on relaunch.

**Concurrency model:**
- `@MainActor`: UI state, menu bar, settings, meeting detection polling
- Background `Task`: All pipeline stages (VAD, transcription, diarization), and dictation batch transcription
- Pipeline runs sequentially (one job at a time) to avoid ANE contention
- Progress updates posted back to `@MainActor` via `AsyncStream` or `@Observable` properties

### Model Lifecycle

The app manages three CoreML models with different lifecycles:

**During meetings: no models loaded.** Recording is audio-only. The Mac runs cool and quiet — no ANE contention with Teams, no memory pressure. Models load only after the meeting ends, when the user isn't actively working.

**Parakeet TDT (transcription) — load on demand, unload after use.**
- Load when a pipeline job's transcription stage begins, unload when transcription completes
- Loading takes 3–5 seconds on M1 — acceptable for post-meeting processing
- Never loaded during meeting recording

**Silero VAD v6 — load with Parakeet, unload with Parakeet.**
- Tiny model (~2 MB), negligible memory footprint
- Always co-loaded with Parakeet
- Could be kept always-loaded due to tiny size, but co-loading keeps the lifecycle simple

**LS-EEND + WeSpeaker (diarization) — load on demand, unload after use.**
- Load when a pipeline job's diarization stage begins, unload when diarization completes
- These models are larger and only used in batch mode, so don't keep them resident

**Model download:** All models download automatically on first use. Show download progress in the menu bar dropdown. Downloads are idempotent — if interrupted, resume on next attempt. Store downloaded models in `~/Library/Application Support/Heard/Models/`.

**Memory timeline for a typical meeting:**
```
Meeting starts  ──────── Recording ────────  Meeting ends  ── Processing ──  Idle
Models:  none            none                 none           Parakeet+VAD    none
                                                             then LS-EEND
                                                             then unload
RAM:     ~80 MB          ~80 MB               ~80 MB         ~800 MB peak    ~80 MB
```

### Transcription Modes

**Batch mode:** Process a complete audio file, return all segments at once. Higher accuracy — the model sees full context. This is the only mode used for meeting transcription in v1. The model loads after the meeting ends, processes the full recording, and unloads.

---

## Meeting Detection

### Detection Strategy

**Power assertion monitoring** is the sole detection method. Poll `IOPMCopyAssertionsByProcess()` every second. Look for `PreventUserIdleDisplaySleep` assertions from any of the supported meeting apps:

- **Microsoft Teams** — bundle IDs `com.microsoft.teams` (classic), `com.microsoft.teams2` (new Teams), with localized-name fallbacks
- **Zoom** — bundle ID `us.zoom.xos`, with case-insensitive localized-name and process-family fallbacks
- **Webex** — bundle IDs `Cisco-Systems.Spark`, `com.cisco.webexmeetingsapp`

Each source can be enabled/disabled independently in General settings. All three are on by default. This works without Screen Recording permission and is sandbox-safe.

When Developer Mode is enabled, each detection poll records assertion and app-match diagnostics in `dict-debug.log`.

- **Start recording** when 2 consecutive polls (2 seconds) detect a matching power assertion
- **Stop recording** when the power assertion disappears. Stop immediately (no grace period). Apply a 5-second cooldown before allowing re-detection.

### Meeting Title Extraction

When a meeting is detected, read the meeting-app window title via Accessibility / `CGWindowListCopyWindowInfo()` to extract the meeting name for use in the output filename. Strip the trailing app-name suffix (` | Microsoft Teams`, ` - Zoom`, ` - Webex`).

- If Accessibility permission is not granted, the window title will be unavailable — fall back to the timestamp as the filename
- Bare placeholder titles for Zoom (`Zoom Meeting`, `Zoom Workplace`) and Webex (`Webex Meetings`) are treated as missing — fall back to the timestamp
- This is a best-effort metadata read, not a detection signal — the power assertion is authoritative for start/stop

---

## Recording

### Dual-Source Capture

Always record two independent audio streams:

1. **App audio**: Use `CATapDescription` (macOS 15.0+) to tap the Teams process audio output. Record at 48 kHz stereo. This captures all meeting audio (remote participants, shared audio). Shows the purple dot in Control Center but requires no Screen Recording permission.

2. **Microphone audio**: Use `AVAudioEngine` to capture the system default microphone. Record at 48 kHz mono. This captures the local user's voice.

**Track alignment:** Measure the start-time offset between both capture paths during `start()`. Store as `micDelaySeconds`. The audio tracks are **never mixed**. Instead, apply this offset mathematically to the mic track's segment timestamps during the Stage 3 merge phase to align them with the app track. Wall-clock timing is accurate within 10–20ms, which is sufficient for transcript timestamps at second-level granularity.

**Intermediate format:** Record to raw WAV at native sample rates. Files are ~330 MB/hour per track, which is acceptable for temporary storage on modern Macs. WAV is simpler — no encode/decode steps, easy to inspect with any audio tool.

**No mix step during recording.** Each track is recorded independently and stays separate. The 48 kHz → 16 kHz conversion happens in the preprocessing pipeline stage, not during recording stop. This keeps the recording stop path fast (just close the files).

**File naming convention:**
```
<YYYYMMDD_HHmmss>_app.wav    # App audio (48 kHz stereo)
<YYYYMMDD_HHmmss>_mic.wav    # Mic audio (48 kHz mono)
```

**Temp file retention:** All intermediate audio files (app, mic, mix WAVs) are stored in a temp directory and automatically deleted after 48 hours. This window allows retry of failed pipeline jobs without keeping audio indefinitely. On app launch, scan the temp directory and delete files older than 48 hours. Also delete orphaned files from previous crashes (any `.wav` in the temp dir not referenced by an active pipeline job). If the user manually deletes/dismisses a pending or failed job from the UI, its corresponding `.wav` files are deleted immediately.

**Maximum recording duration:** 4 hours. If reached, stop recording, enqueue the job, and immediately start a new recording if the meeting is still active. This prevents unbounded file sizes and ensures processing starts within a reasonable time.

### Local User Identification

The mic track is always the local user. The app track is always remote participants. This is inherent to dual-source recording — no configuration needed. In the final transcript, the local user is labeled "Me" (or their name if known from the speaker database). Remote participants are identified via diarization of the app track.

---

## Processing Pipeline

### Pipeline Queue

Jobs are processed asynchronously and sequentially (one at a time to avoid ANE contention). Each job progresses through these stages:

```
queued → preprocessing → transcribing → diarizing → assigning → complete
```

**Job persistence:** Serialize the job queue to `pipeline_queue.json` on every state change. On app launch, restore incomplete jobs and resume from the last completed stage. Each stage is idempotent — safe to re-run if interrupted.

**Job model:**
```swift
struct PipelineJob: Codable, Identifiable {
    let id: UUID
    let meetingTitle: String       // from Teams window title
    let startTime: Date            // recording start
    let endTime: Date              // recording end
    let appAudioPath: URL          // 48 kHz stereo WAV (raw recording)
    let micAudioPath: URL          // 48 kHz mono WAV (raw recording)
    var stage: PipelineStage
    var stageStartTime: Date?      // for elapsed time tracking
    var error: String?
}
```

### Stage 1: Preprocessing (In-Memory)

Avoid saving explicit 16 kHz WAV intermediate files to disk to preserve disk space and reduce I/O. Read the raw 48 kHz tracks directly into RAM and process them.

**Data at each step:**
Only the original `app.wav` and `mic.wav` reside on disk. The rest of the pipeline operates strictly on in-memory buffers.

Processing steps:
1. **Load and Downmix:** Read `app.wav` into an `AVAudioPCMBuffer` and downmix its stereo channels to mono by **averaging the left and right channels** to prevent losing spatial audio participants. Read `mic.wav` into a separate buffer.
2. **Resample (In-Memory):** Use `AVAudioConverter` to convert both 48 kHz buffers into new 16 kHz mono buffers entirely in RAM.
3. **VAD Trimming (In-Memory):** Run Silero VAD on the 16 kHz buffers. Drop silent chunks to produce new, condensed `[Float]` arrays representing speech segments. This leaves the original on-disk `.wav` files untouched, keeping the stage safe to retry.
3. Build a `VadSegmentMap` per track for timestamp remapping

VAD is always on. Threshold fixed at 0.85 (hardcoded).

**VAD segment map:** When VAD removes silence, downstream timestamps are relative to trimmed audio. The segment map stores the mapping:
```
Original:  [0s ---- 5s][silence 5s-12s][12s ---- 20s]
Trimmed:   [0s ---- 5s][5s ---- 13s]
Map:       trimmed 0-5 → original 0-5, trimmed 5-13 → original 12-20
```
Use binary search for O(log n) lookups when remapping. Apply remapping to both transcription segments and diarization segments.

### Stage 2: Transcription

Transcribe each 16 kHz track separately in batch mode (passing the in-memory `[Float]` arrays for the app track, then the mic track). Transcribing per-track rather than a mix avoids crosstalk artifacts and produces cleaner text per source.

**Model:** Parakeet TDT V2/V3 (English speech recognition; V2 is the default). The selected model is used for both meeting transcription and dictation.

**Custom vocabulary:** Pass user-defined terms to the CTC keyword spotter. Terms must be at least 2 characters, maximum 50 terms. Stored in UserDefaults. Applied during transcription to boost recognition of domain-specific jargon, project names, and acronyms.

**Output:** Array of `TimestampedSegment` (start seconds, end seconds, text). Timestamps are in trimmed-audio space — remap via VadSegmentMap before proceeding.

### Stage 3: Diarization

Two-stage pipeline running on the separate tracks:

**Stage 3a: LS-EEND speaker segmentation.**
- Run on the app track (remote participants) and mic track (local user) independently
- Auto-detect speaker count (no user override)
- Produces segments: `[(speakerID, startTime, endTime)]`
- Handles overlapping speech
- Remap timestamps via VadSegmentMap

**Stage 3b: WeSpeaker embedding extraction.**
- Extract voice embeddings for each detected speaker on each track
- Embeddings are 256-dimensional float vectors
- Used for cross-meeting speaker identification
- The mic track typically has one speaker (the local user) — extract their embedding for the speaker database
- The mic track is diarized to extract a duration-weighted voice centroid for the user's self-profile; the local user remains identified by construction as the mic-track speaker.

**Dual-track merge:**
- Prefix app-track speaker IDs with `R_` (remote)
- Prefix mic-track speaker IDs with `M_` (mic/local)
- Merge all segments into a single timeline sorted by start time

### Stage 4: Speaker Assignment

Map transcription segments to speakers:

1. For each transcript segment, find the diarization segment with maximum temporal overlap
2. If no overlap, find the nearest diarization segment by time gap
3. Assign the speaker label from the matched diarization segment
4. Merge consecutive segments from the same speaker (join text, span timestamps)

**Speaker identification (cross-meeting):**
- Load the speaker database (`speakers.json`)
- For each detected speaker's embedding, compute cosine distance to all stored speakers
- Match threshold: 0.30 (cosine distance; configurable in Advanced)
- Confidence margin: 0.10 (minimum gap between best and second-best match to accept)
- If matched: use the stored speaker's name
- If unmatched: assign a globally unique placeholder label (for example, `Speaker_1AB23C`) and store the embedding as a new speaker entry

**Local user identification:**
- The user configures their own name once in Settings (General tab → "Your Name")
- This name is permanently bound to the mic track — no diarization needed to identify the local user
- A duration-weighted mic-track voice centroid is stored in the speaker database under this name and updated silently each meeting

**Auto-learning behavior (known speakers):**
- Every meeting updates embeddings for recognized speakers in the database
- Store up to 5 embeddings per speaker (most recent, diverse conditions)
- When a speaker is confidently matched (margin > 0.15), silently update their embedding set — no prompt, no interruption
- After 3–5 meetings with the same participants, the app names everyone correctly without intervention

**New speaker handling:**
- When an unmatched speaker is detected, prompt the user after the meeting ends to name them
- The prompt is a lightweight dialog listing only the new/unmatched speakers (not the ones already identified)
- Each unmatched speaker shows a **playable audio clip** (~10 seconds of their clearest speech segment, extracted from the diarization results). The user clicks play to hear the voice, then types the name. This is essential — without hearing the voice, the user has no way to identify who "Speaker 2" is.
- Naming is user-paced: the "Name Speakers" window is opened from the menu bar or Speakers settings banner, and pending candidates remain until the user saves, skips, splits, or discards them. Pending candidates persist across app restarts.
- The menu bar icon shows a subtle indicator (user action badge) when naming is pending

**Smart inference from Teams roster:**
- When Accessibility permission is granted, read participant names from the Teams roster during the meeting
- Three strategies in priority order:
  1. Look for known roster panel identifiers (roster-list, people-pane)
  2. Find AXList/AXTable/AXOutline containers with multiple text rows
  3. Parse the window title pattern "Name1, Name2 | Microsoft Teams"
- Filter out UI control strings (mute, unmute, raise hand, etc.)
- **Automatic name assignment:** If N speakers are detected via diarization and N-1 are already identified in the speaker database, and the Teams roster contains exactly one name that doesn't match any known speaker, automatically assign that roster name to the unmatched speaker — no prompt needed
- This covers the most common case: recurring team meetings where one participant is new
- For 1:1 calls where the local user is known, the sole remote speaker is automatically assigned the other roster participant's name
- When inference is applied, still store the embedding so the speaker is recognized in future meetings without roster help

### Stage 5: Output

Generate a single Markdown file:

**Path:** `<configurable output dir>/<YYMMDD>_<meeting_title>.md`

**Filename rules:**
- Date prefix uses 2-digit year: `260324_Sprint_Planning.md`
- Sanitize title: replace illegal characters (`/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`) with underscores, collapse whitespace to single underscore, truncate to 80 characters
- If the meeting title is empty, use "meeting"
- If a file with the same name already exists on the same date, append a number: `260324_Sprint_Planning_2.md`, `260324_Sprint_Planning_3.md`

**Format:**
```markdown
# <Meeting Title>

**Date:** YYYY-MM-DD HH:MM – HH:MM
**Duration:** Xh Ym
**Participants:** Name1, Name2, Name3

---

[00:00] **Me:** Hello everyone, thanks for joining.

[00:05] **Sarah:** Hi, thanks for having us.

[00:12] **Me:** Let's start with the Q1 review.

[00:15] **Speaker 3:** Sure, I've prepared some slides.
```

**Formatting rules:**
- Timestamps in `[MM:SS]` format (or `[H:MM:SS]` for meetings over 1 hour)
- Speaker names in bold
- One blank line between speaker changes
- **Continuous speaker blocks:** All consecutive segments from the same speaker are merged into a single unbroken block of text. A new speaker block only starts when a different speaker begins talking. Never split one speaker's continuous speech into multiple blocks. The timestamp on each block is the start time of the speaker's first segment in that block.

**After output:**
- Write the `.md` transcript to the output directory
- Mark the pipeline job as `complete`
- Temp audio files (WAVs in the temp directory) remain for 48 hours to enable retry, then are auto-cleaned. If a user manually deletes/dismisses a job, its files are deleted immediately.

**Retry logic:**
- If any pipeline stage fails, automatically retry up to 3 times with exponential backoff (5s, 30s, 5min)
- On each retry, resume from the failed stage (not from the beginning) — stages are idempotent
- If all retries are exhausted, mark the job as `failed` and set the error menu bar badge (persists until acknowledged)
- Failed jobs are preserved in `pipeline_queue.json`. On app relaunch, failed jobs are retried once more — this handles failures caused by transient issues or resource pressure during the previous session
- The dropdown menu shows the error message and a manual "Retry" button for failed jobs

---



---

## Speaker Management UI

### Speaker Database

Stored as `speakers.json` in the app data directory:

```json
[
  {
    "id": "uuid",
    "name": "Sarah Chen",
    "embeddings": [[0.12, -0.34, ...], [0.11, -0.33, ...]],
    "firstSeen": "2026-01-15T10:30:00Z",
    "lastSeen": "2026-03-20T14:00:00Z",
    "meetingCount": 12
  }
]
```

### Management View

A dedicated tab in the Settings window. Features:

- **List view:** All known speakers with name, meeting count, first/last seen date
- **Rename:** Click on a speaker name to edit it inline
- **Delete:** Remove a speaker profile entirely (with confirmation)
- **Merge:** Select two speakers and merge them (combines embeddings, keeps the first name). Useful when the same person was detected as two different speakers across meetings.
- **Search/filter:** Text filter on speaker names
- **Sort:** By name, meetings, time in meetings, speaking time, or last seen
- **Voice clips:** Play or stop the saved voice clip for a speaker when one is available


---

## Transcript Library UI

A "Meetings" tab in the Settings window listing prior meeting transcripts. Transcripts do **not** render in-app — activating a row opens the `.md` file in the user's default Markdown editor (`NSWorkspace.open`).

- **Data source:** on-demand scan of the configured output directory (no index file, no new persistence). Metadata is parsed from the first ~1 KB of each transcript's header (`# Title`, `**Date:**`, `**Duration:**`, `**Participants:**`), falling back to the filename-derived title and file modification date for malformed or pre-format files. Standalone note files (`*_note.md`) are excluded.
- **List view:** sortable table (Title, Date, Duration, Participants), newest-first by default; text filter on title + participants.
- **Actions:** double-click or per-row Open button opens the file; context menu adds Reveal in Finder and Move to Trash (with confirmation).
- **States:** empty state when no transcripts exist; missing-folder state when the output directory is gone.
- **Refresh:** on tab appearance, on output-directory change, and via a manual refresh button. No live file watching.
- **Menu bar:** the dropdown's "Transcripts…" row opens Settings pre-selected to this tab.

---

## Menu Bar UI

### Menu Bar Icon

The icon is the primary feedback channel — it must communicate state at a glance since there are no notifications.

**Icon design:** Stylized microphone or waveform, rendered as a macOS template image (automatically adapts to light/dark mode).

**States — each must be visually distinct:**

| State | Icon | Description |
|-------|------|-------------|
| **Dormant** | Static outline icon (muted/gray appearance) | Auto-watch is on, waiting for a meeting. The "everything is fine, nothing happening" state. |
| **Recording** | Filled icon with animated red dot | Meeting detected, actively recording. The red dot pulses subtly (0.8s period) to indicate liveness. Unmistakable "something is happening" signal. |
| **Processing** | Filled icon with spinning indicator | Meeting ended, pipeline is running (transcription → diarization → output). Brief state — typically 1–3 minutes. |
| **Error** | Icon with red exclamation badge | A pipeline job failed after retries. **Persists until acknowledged** (user clicks the menu and sees the error). Eye-catching — red badge overlaid on the icon, similar to an app notification badge. |
| **User action** | Icon with orange dot badge | Waiting for speaker naming input. Less urgent than error, but visible. |

The error state is deliberately attention-grabbing. Since there are no notifications, a failed transcription could go unnoticed for hours if the icon blends in. The red exclamation badge should be visible even at menu bar icon size (16×16 pt).

### Dropdown Menu

Standard `MenuBarExtra` dropdown. Contents:

**Status section:**
- Current state text (Watching, Recording [meeting title + duration], Processing [stage + elapsed], Error [message])
- If error: red-highlighted error description + "Retry" button

**Queue section (when jobs exist):**
- Last 3 completed jobs with status (checkmark or X) — click to open transcript
- Active job (if processing) with stage indicator

**Actions:**
- Start/Stop Watching (⌘S)
- Name Speakers... — only shown when naming is pending
- Transcripts... — opens the Meetings settings tab
- Settings... (⌘,)
- Quit (⌘Q)

---

## Settings

Minimal settings surface. Organized in a standard macOS Settings window with tabs.

The implementation exposes these tabs: **General**, **Recording**, **Dictation**, **Speakers**, **Meetings**, **Advanced**, and **About**. Advanced is hidden until **Show Advanced Settings** is enabled in General.

### General Tab
- **Your Name:** Text field for the local user's display name (used for the mic-track speaker label in transcripts).
- **Launch at Login** and **Show Dock Icon** toggles.
- **Show Advanced Settings** toggle.
- Permission status and grant controls for Microphone, System Audio, Screen Recording, and Accessibility.

### Recording Tab
- Meeting-app detection toggles for Microsoft Teams, Zoom, and Webex, plus Auto-Watch.
- Microphone picker, transcription model picker, custom vocabulary, meeting-note hotkey, opt-in meeting-chat capture, and output-folder controls.

### Dictation Tab
- Working dictation controls: enable, HUD, push-to-talk, configurable global hotkey, custom formatting commands, and live status.

### Speakers Tab
- Inline speaker management, including search, sorting, voice-clip playback, rename, merge, and delete.

### Meetings Tab
- On-demand transcript library with search, sorting, external open, Finder reveal, and trash actions.

### Advanced Tab
- Model download/unload controls, model keep-alive, memory mode, diarization and voice-matching tuning, speaker retention, and Developer Mode.

### About Tab
- Version, update status, and application information.

---

## Permissions

| Permission | Required? | Used for |
|-----------|-----------|----------|
| Microphone | Yes | Recording local user's voice |
| System Audio | Recommended | Capturing the meeting app's audio track |
| Screen Recording | Recommended | Capturing the meeting app's audio track |
| Accessibility | Recommended | Teams title/roster reading and dictation text injection |

The app must function with only Microphone permission. Screen Recording and Accessibility enhance functionality but are not required for core meeting recording and transcription.

On first launch, request Microphone permission. Prompt for Screen Recording and Accessibility only when the user attempts to use a feature that requires them.

---

## Build & Distribution

### Single Universal Build

One build target, one binary. Without App Store distribution requirements, the app does not need to enforce the App Sandbox. The minimal entitlements include:

- `com.apple.security.device.audio-input` (microphone)

**Sandbox Removed:** Building without the App Sandbox simplifies file-system access and the Accessibility APIs used for roster reading and dictation text injection.

**No `#if` flags.** No compile-time feature switches. No conditional compilation. One code path.

### Distribution

- **Direct Download:** Notarize the build, package as DMG, distribute via GitHub Releases.
- **Homebrew:** Distribute via Homebrew Cask.
- **CI:** Single CI pipeline builds one artifact, signs it, notarizes it, and publishes it automatically.

---

## Data Model Summary

### Files on Disk

```
~/Library/Application Support/Heard/
├── Models/                        # Downloaded CoreML models (managed by FluidAudio)
│   ├── parakeet-tdt-0.6b-v2/
│   ├── silero-vad-v6/
│   ├── ls-eend/
│   └── wespeaker/
├── speakers.json                  # Speaker embedding database
├── pipeline_queue.json            # Persistent job queue (crash recovery)
└── recordings/                    # Temp directory for in-progress recordings
    ├── 20260324_140000_app.wav      # 48 kHz stereo, deleted after 48h
    └── 20260324_140000_mic.wav      # 48 kHz mono, deleted after 48h
    # (All 16 kHz conversion and VAD trimming happens in-memory)

~/Documents/Heard/    # Default output (user-configurable)
└── 260324_Sprint_Planning.md
```

### Settings (UserDefaults)

| Key | Type | Default |
|-----|------|---------|
| `userName` | String | "" (falls back to "Me") |
| `launchAtLogin` | Bool | false |
| `autoWatch` | Bool | true |
| `outputDirectory` | String | "~/Documents/Heard/" |
| `customVocabulary` | [String] | [] |

These are the core persisted settings. Additional controls for recording, dictation, permissions, model management, speaker management, and tuning are exposed in the settings tabs above.

---

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 5.9+ |
| UI framework | SwiftUI + AppKit (NSPanel, NSStatusItem) |
| Build system | Swift Package Manager |
| Audio capture (app) | CATapDescription (AudioToolbox, macOS 15.0+) |
| Audio capture (mic) | AVAudioEngine |
| Audio format | WAV (48 kHz native for recording, 16 kHz mono for processing) |
| Transcription | FluidAudio Parakeet TDT V2/V3 (CoreML/ANE) |
| VAD | FluidAudio Silero VAD v6 (CoreML) |
| Diarization | FluidAudio LS-EEND + WeSpeaker (CoreML) |
| Concurrency | Swift structured concurrency (async/await, Task, AsyncStream) |
| Persistence | UserDefaults (settings), JSON files (speakers, queue) |
| Global hotkey | Carbon `RegisterEventHotKey` |
| Text injection | Clipboard paste via CGEvent Cmd+V (requires Accessibility) |
| Distribution | GitHub Releases + Homebrew Cask |
| CI | GitHub Actions |
| Minimum OS | macOS 15.0 |

---

## What's Explicitly NOT in Scope

- LLM integration (no Claude, no OpenAI, no local LLM)
- File import / batch processing of existing recordings
- macOS notifications
- Google Meet support (browser-tab; no per-meeting power assertion to detect)
- Manual app recording (pick any app)
- Mute detection
- Multiple output formats (Markdown only)
- Multiple transcription languages (English only)
- Configurable VAD threshold
- Configurable speaker count
- Live captions during meetings (models stay unloaded during recording)
- Arbitrary dictation voice actions such as "scratch that" (dictation does support configurable formatting commands and text normalization)
- Grace period after meeting ends
- System-wide audio capture
- Pre-release update channels
