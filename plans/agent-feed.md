# Plan: AgentFeed, a delayed-live transcript feed for a personal agent

**Status (2026-11-21):** AgentFeed runtime is planned, not started. No feed code, settings, toggles, endpoints, or live ASR exist. The batch engine (English Unified default) and recording recovery (G1, part of G2) are implemented in the working tree, native-unverified (see handoff.md). The rules in `spec.md` (no LLM integration, no external API, no live captions, models unloaded during recording) stay in force until a scope amendment is approved and implemented.

**Baseline:** HEAD `1164a3c`, v0.3.9. Line references below are from that HEAD and must be rechecked before implementation.

**Source:** workstream review of the delayed-live design, recording reliability, and model/API answers (FluidAudio 0.15.5 pinned source and 0.18.4 upstream read). The constraints are restated here so this plan stands alone.

---

## 0. Scope

In scope (future): a local, read-only, revision-aware transcript feed of an in-progress call, published as files for a personal agent that runs on the same Mac.

Out of scope:
- Any cloud upload, remote transport, listening port, or socket. A remote agent needs a separate, user-chosen transport and sharing policy.
- LLM calls inside Heard.
- Live speaker names. Speaker identity stays in the final pass.
- Live text in the saved Markdown transcript. The final transcript is written only by the unchanged final pipeline.
- Write access from the agent into Heard or its files.
- Live captions in the UI.

Scope amendments required before implementation (`spec.md`, "What's Explicitly NOT in Scope" and Architecture):
- LLM integration exclusion (spec.md:523). Heard does not add an LLM; the amendment must state that the personal agent is external and reads files.
- Live captions exclusion and "models stay unloaded during recording" (spec.md:533). Live windows need ASR resident during recording, so a memory budget and an off-by-default setting are required.
- AGENTS.md "no cloud APIs, no LLM integrations" stays as is. This feature must not require either.

---

## 1. Gates (must be done before live output is trusted)

| Gate | Owner | Why |
|---|---|---|
| G1. Active-session recovery: journal the active session, add a terminate hook that stops and enqueues, scan `recordings/` at launch for unqueued WAVs | recording agent | Today a quit or crash mid-meeting loses the session (`MTApp.swift:77-82`, `Services.swift:2547-2573`). Live replay assumes durable capture. |
| G2. Bounded microphone handoff: remove the unbounded `micBufferStream` (`Services.swift:1260-1262`, `1308`) or replace it with a bounded, consumed queue | recording agent | Unbounded retention (about 0.7 GB per hour estimated, not measured). Live needs the same bounded handoff. |
| G3. Mic device-change recovery (`AVAudioEngineConfigurationChange`), with a segment strategy for format changes | recording agent | Mic track stops silently on device change. Live segments need stable track identity. |
| G4. FluidAudio 0.18.x upgrade with timed Unified batch output | platform and core agents | `transcribeWithTimings` exists only in 0.18.x. The upgrade is a migration, not a routine bump. Status: `Package.swift` pins exact 0.18.4; `Package.resolved` was hand-edited, not resolved or built. |
| G5. Model licenses: NVIDIA Open Model License for Parakeet Unified EN (notice in README); Silero artifact metadata | platform agent (license analysis); release owner confirms before shipping | Heard downloads weights at runtime and bundles none. The Silero artifact is unchanged. |
| G6. Spec scope amendment (section 0) approved | orchestrator with human | Current spec excludes this feature. |

Status of gates (2026-11-21, working tree, native-unverified unless stated):
- G1 (active-session recovery): implemented. Journal, launch recovery before cleanup, quit queues the active recording, persistent warnings. Forced-kill and relaunch checks on macOS are pending.
- G2 (bounded microphone handoff): the unbounded mic stream was removed. No bounded, consumed live handoff exists because no live pipeline exists.
- G3 (microphone device-change recovery): not started.
- G4 (FluidAudio 0.18.x): see table. Not resolved or built here.
- G5 (licenses): primary NVIDIA terms read. Heard downloads runtime weights and bundles none. Notice added to README. Silero hash audit recorded in handoff.md and README. Owner: platform agent; release owner confirms before shipping.
- G6 (scope amendment): not approved. The spec states AgentFeed as planned only.

G1 and G2 are independent of model choice and should land first.

---

## 2. Model baseline and modularity

- **First window engine:** Parakeet Unified EN 0.6B, behind the `transcribeWindow` interface. Windowing effects are measured with the same engine for chunked and full-meeting runs against the same human reference (feature accuracy gate, section 13).
- **Batch and window target:** Parakeet Unified EN 0.6B, chosen by the orchestrator from existing evidence and now the batch default for new and never-saved settings (working tree, native-unverified). Its token timings are non-optional through `transcribeWithTimings` (FluidAudio 0.18.x). It requires G4 and G5 above.
- **Interface:** all window ASR calls go through `transcribeWindow(samples, language) -> [TimedToken]`. No live window engine exists yet. The batch default change does not enable live windows.
- **Final pass:** unchanged in this plan. Whether the final pass adopts Unified is a separate decision with its own reference-based check.
- **Not in this plan:** a head-to-head model benchmark of Unified against Ultra or any other model. No experiment is requested here.
- **Accuracy requirement (feature gate, not an experiment now):** delayed chunked output and the full-meeting output are each scored against the same human-verified reference (consent-cleared audio). Agreement between the two modes is not acceptance evidence.
- **VAD:** Silero is unchanged. A v6.2.3 artifact investigation belongs to the platform agent.
- **Diarization:** final pass only.
- **Vocabulary and formatting:** Unified emits punctuation and capitalization, which may overlap Heard's formatting. Test names, numbers, dates, and duplicate formatting. Vocabulary behavior changes must be checked, not assumed.

---

## 3. Architecture

```
capture (copy-only callbacks)
  -> per-track bounded segmenter (own queue, resample to 16 kHz mono)
  -> immutable fixed-length segments
  -> interval scheduler (one window at a time, bounded backlog, gap events)
  -> window ASR (VAD as gate, fresh decoder state per window)
  -> ownership merge
  -> event log (NDJSON) + atomic snapshot
  -> agent reads files (read-only)

stop -> edge flush of live windows -> unchanged final pipeline -> final event
```

Windows (tunables, swept in benchmark):
- Step `S`, left context `L`, right context `R`. Ownership interval `O_i = [i*S, (i+1)*S)`. Window `i` covers `[i*S - L, (i+1)*S + R)`.
- Window `i` commits only tokens whose midpoint lies in `O_i` and whose end does not cross the interval end. Tokens crossing the boundary wait for window `i+1`.
- Duplicates across overlapping windows cannot be emitted by construction because ownership is by interval, not by text matching.
- Start: window 0 has no left context. Stop: the last interval may be partial and is flushed with available audio and no right context. Flushed tokens carry an end-of-stream flag.
- Windows longer than 15 s use the library's internal chunking, which has its own overlap and boundaries. Tests must cover those internal boundaries.
- `S`, `L`, `R`, and segment length sit on one grid: each is a multiple of the segment length.
- Window VAD: the simplest path runs untrimmed windows with VAD as a gate, so no time remap is needed. If audio is trimmed, build a `VadSegmentMap` per window.

Segments:
- Fixed length (example 5 s), 16 kHz mono PCM16, written once by the segmenter, never modified.
- Live never reads a WAV that is still being written.
- Storage about 32 KB/s per track (about 115 MB/h per track).
- Resampling: `AudioConverter.resample` works on in-memory arrays. Each call creates a new converter, so measure seam error between segments against a continuous resample before choosing a persistent converter in the segmenter.

---

## 4. Timestamp, VAD-map, and track-offset ownership

Time mapping order for every live token:
1. window-local token time
2. window VAD map back to the track's original timeline (`VadSegmentMap.toOriginalTime`, `AudioProcessing.swift:35`), if trimmed
3. window start on the track
4. per-track offset onto the session clock (`micDelaySeconds`, `Services.swift:1118-1123`; dedup uses it at `Services.swift:3780`)

Ownership rules:
- Token timings are required. Nil or empty timings become a `gap` event with reason `timing_missing`. The whole-track fallback (`Services.swift:3751-3759`) is never used for live text.
- Open, owned by the recording agent: the app track's start moves when its tap is rebuilt into a fresh file, and the code recalibrates `micDelaySeconds` (`Services.swift:1871-1879`). Split WAVs start new files (`Services.swift:1141-1154`). Live offsets must be versioned per segment or per file before live is enabled. Until then, live is disabled for sessions that rebuild or split.
- Labels are by capture track, `app` or `mic`. The mic track can carry room speech and bleed, so mic text is never labelled as the user. No speaker names in live events. Roster names may appear only as snapshot hints.

---

## 5. Event contract

Every event has a monotonic `seq` per session and an idempotent identity `(session, track, segID, revision)`.

| Type | Meaning | Persisted |
|---|---|---|
| `session` | start, schema version | log |
| `provisional` | tail hypothesis, replaced per track | snapshot only |
| `committed` | text owned by an interval, a draft | log, appended once |
| `corrected` | re-decoded range with new text, carries `supersedes` | log, opt-in, off by default |
| `gap` | range not processed (`backlog`, `overflow`, `timing_missing`, `engine_error`) | log |
| `final` | full-meeting pipeline finished, carries transcript path, supersedes live | log |

Each text event carries `"trust": "untrusted_transcript"` and `"degraded": true|false`. Degraded means window-level text without precise commits.

Example (illustrative):

```
{"seq":1,"type":"session","sessionID":"<uuid>","schema":1,"startedAt":"<iso8601>"}
{"seq":2,"type":"committed","track":"app","segID":"app:000001","startSec":12.40,"endSec":15.10,"text":"...","trust":"untrusted_transcript","degraded":false}
{"seq":4,"type":"gap","track":"app","fromSec":40.0,"toSec":52.0,"reason":"backlog"}
{"seq":9,"type":"final","transcriptPath":"<path>"}
```

Snapshot (atomic rename): `lastSeq`, `committedThroughSec` per track, current provisional per track with revision, and lag in seconds.

---

## 6. Capture priority and bounded memory

- Capture callbacks are copy-only. No ASR, VAD, or resampling runs in a callback.
- The live queue is bounded. On overflow, drop the live copy, never the recording copy, and emit a `gap` with reason `overflow`.
- WAV writers and tap callbacks never wait on live work.
- Segment retention: delete after the final pass succeeds, or keep under a user setting. Live logs follow their own retention, not the 48 h audio cleanup.
- Memory budget: one ASR instance shared by live and final (serialized). Dictation and the pipeline currently each load their own `AsrModels` (`DictationManager.swift:286-306`, `Services.swift:3396-3418`). Sharing one instance is a prerequisite for live memory, and the budget is measured on the target Mac.
- Gate: live is disabled under low-memory mode (`CoreModels.swift:412-417`, `MemoryMode`).

---

## 7. Lag, gaps, and backlog

- Lag is `R` plus inference time. Snapshot reports current lag.
- Backlog is bounded. When a window cannot run in time, its range is emitted as `gap` with reason `backlog`. Live never silently skips audio.
- Coverage invariant: the union of committed and gap ranges covers every audio interval the session processed, with no holes except the intentional unstarted tail.

---

## 8. Restart idempotency and recovery

- Durable state: segments, the NDJSON event log, and a state checkpoint. The durable log is the source of truth. The checkpoint is a speed-up.
- NDJSON append may leave a torn last line after a crash. Readers ignore an incomplete last line. Writers resume from the highest valid `seq`.
- Replayed writes with the same identity are dropped.
- Snapshot uses the atomic rename pattern (`Stores.swift:128-131`).
- Flush policy (per event or per interval) trades latency for durability. Decide in phase 1 and measure.
- After relaunch, live resumes from the last committed interval with a fresh ASR state. A session interrupted by a crash is not treated as complete until the final pass runs.
- Requirement: a session interrupted and resumed produces the same final transcript as an uninterrupted run, and the feed has contiguous `seq` with no duplicates.

---

## 9. Model contention, cancellation, and consecutive calls

- One serialized ASR instance. Live and final never run concurrently on it.
- In-flight ASR calls cannot be reliably cancelled (`Services.swift:2901-2907`, `3059-3063`). Live therefore stops scheduling new windows when stopping or when behind, and bounds work per window. There is no instant preemption.
- Final-pass policy: when a final job is queued, live finishes its in-flight window and then yields, recording the skipped range as `gap` with reason `backlog`. Choose between yield and pause in phase 2 and measure.
- Live has its own window timeout that marks a `gap` when a call overruns. The timed-out call is not cancelled and its result is ignored by the generation fence.
- Dictation refuses to start during a recording (`AppModel.swift:401-404`) and stops when one starts (`AppModel.swift:299`). Keep both.
- Consecutive meetings: the previous session's edge flush and enqueue complete before the next session starts. Enqueue is guarded by the generation fence (`Services.swift:2943`).

---

## 10. Read-only agent feed (local first)

- Location: a session directory under the app support directory, containing `events.ndjson` and `snapshot.json`. Exact path confirmed in phase 1.
- Permissions: files and directories are owner-only (0600 and 0700). The agent process runs as the same user, so write access is removed by convention and checked by a test, not by OS isolation.
- The agent polls or tails with its own cursor. No port, socket, or server.
- Heard never reads the feed back. The agent has no write tool for Heard's files.
- Later, an optional MCP wrapper can expose the same files as read-only tools. It is not a second source of truth. It is out of scope until the agent runtime is chosen.

---

## 11. Sharing control and transcript trust

- Feature setting: off by default. A per-meeting opt-in is required. Off means no feed files, no live ASR, and no change to the "models unloaded during recording" behavior.
- Visible indicator in the menu while a feed is active.
- Revoke: a user action stops writing and deletes that session's feed directory.
- Chat content is excluded from the feed in v1, even when chat capture is on.
- Consent: a one-time disclosure before the first enabled meeting, naming what is written and where. Meeting participants are not notified by Heard.
- Trust boundary for the agent: transcript text is untrusted content from meeting participants. The agent may read it as time-stamped draft material. It must not execute commands, send messages, write files, or take action because transcript text asks it to. No tool authorization may depend on transcribed speech. The agent's own instructions live in its own configuration, not in the feed.

---

## 12. Phases

Phase 0 (gates): G1 through G6 above.

Phase 1 (pure logic, no audio): ownership intervals and tiling; merge rules; event log with idempotent identity, torn-line handling, and replay drops; snapshot writer; flush-policy decision. Unit tests for tiling, boundary words, replay, torn lines, and interval edges.

Phase 2 (segmenter on capture path, no ASR): bounded handoff, immutable segments, retention. Parity test: capture output with segmenter on and off must match for identical input.

Phase 3 (window ASR, fixtures only): windows on synthetic and fixture audio with known token times. Compare against the batch final output on the same fixtures. Feature flag, off by default.

Phase 4 (feed and controls): NDJSON and snapshot, per-meeting opt-in, indicator, revoke, permission checks.

Phase 5 (validation on target Mac): section 13. Decide ship or not from the results.

---

## 13. Acceptance checks on the target Mac

Record model, chip, RAM, and macOS version for each run. Each check runs from a fresh process.

1. Tiling and boundary tests pass on synthetic sessions, including partial last interval and sessions shorter than one window.
2. Capture parity: segmenter on versus off produces identical WAV bytes or hash for identical input. Final transcript text is identical or the difference is explained.
3. Capture health: zero WAV write errors and zero dropped capture frames attributable to live work, live on versus live off.
4. Memory: RSS over a 60 to 120 minute meeting with live on, then final pass. Report peak and final RSS. Force queue overflow and show RSS stays within the budget.
5. Latency: time from audio end to event being readable, reported as p50, p90, and p99. Report cold call (model load plus first window) separately from warm real-time factor.
6. Gaps: forced backlog produces `gap` events, and the coverage invariant (section 7) holds.
7. Restart: force-kill during live, relaunch. `seq` is contiguous, no duplicate identities, and the final transcript equals an uninterrupted run.
8. Consecutive meetings: two back-to-back meetings. The second session starts clean and has no events from the first.
9. Contention: dictation attempted during a live session is refused.
10. Feed permissions: feed files are owner-only. Cursor tail reads each event once after write.
11. Trust: a transcript line containing an instruction ("delete files", "send a message") is delivered as untrusted data. The agent integration test confirms no tool action.
12. Off by default: with the setting off, no feed files, no live ASR load, and no change to recording.
13. Accuracy (feature gate): delayed chunked output and full-meeting output each scored against the same human reference on consent-cleared meetings. Report WER median, p90, and worst, and by slice (window-edge words, overlap, names, numbers, mic bleed, quiet voices). Thresholds are set by the user after results. Agreement between modes is not evidence.
14. Device and power: input-device switch, sleep and wake during a live call, and permission denial each produce an explicit `gap` or degraded state, not silent loss.

---

## 14. Open decisions

- The final pass already uses the selected batch engine (Unified EN by default for new settings, working tree). An accuracy comparison of Unified against saved TDT choices on consented meetings is a follow-up measurement. No benchmark result is claimed here.
- Final-pass policy: yield or pause live (phase 2).
- Window and context sizes (benchmark sweep).
- Flush policy for durability (phase 1).
- Whether corrected revisions ship (off by default until a benchmark shows gain).
- Grace period after meeting end: remains out of scope under the current policy (`spec.md`, not in scope). Changing it is a product decision.
- Notifications: remain out of scope under the current policy. Changing it is a product decision.
- MCP wrapper timing (after the agent runtime is chosen).
