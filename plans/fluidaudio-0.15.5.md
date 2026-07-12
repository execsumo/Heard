# FluidAudio 0.15.5 Upgrade, Parakeet Unified Migration & Streaming Dictation

Owner: orchestrator (Claude) · Delegates: agy (Antigravity) · Started 2026-07-11

## OUTCOME (2026-07-12) — plan closed

- **Phase A shipped** (merged `d1c9faf`): 0.15.5 bump, per-term vocab thresholds
  (`minSimilarity`, length-scaled), `AsrModels.modelsExist` cache check. Fused decoder /
  deterministic clustering / compute units turned out to be N/A or already-default.
- **Phase C shipped reduced** (merged `9a716ba`): user self-profile from mic-track
  embeddings (best-effort, 10-min bound). Offline pre-enrollment impossible — 0.15.5's
  `enrollSpeaker` is streaming-diarizer-only.
- **Phase B cancelled by user decision**: Unified batch returns no token timings
  (pipeline migration would break speaker attribution) and Unified streaming has no
  vocab boosting or confirmed/volatile split. Dictation stays batch TDT — one model
  family for meetings + dictation with custom vocab working in both. See handoff.md
  ("Parakeet Unified / streaming dictation evaluated and rejected") for revisit
  conditions.

## Goal

Upgrade FluidAudio 0.15.2 → 0.15.5 and adopt everything notable except word-level
timestamps; unify meetings + dictation on the Parakeet Unified 0.6B backend; enable
live-streaming dictation (v2 scope, previously failed — see Risk); leverage diarizer
speaker pre-enrollment against the existing SpeakerStore + the user's own profile.

## Why phased

Phase A is a prerequisite: every later change compiles against 0.15.5 APIs, and the
ModelHub download migration is the one breaking change. Phases B and C are independent
of each other and run as parallel delegates once A is merged.

```
Phase A (foundation, agy-fa155)  →  Phase B (unified+streaming, agy-unified)
                                 →  Phase C (pre-enrollment,   agy-enroll)
```

## Phase A — 0.15.5 foundation (delegate: agy-fa155)

1. **Bump** `Package.swift` to `from: "0.15.5"`; resolve; fix all compile breaks.
   Free pickups: long-form chunk-merge fixes, Silero VAD v6.2.1.
2. **ModelHub migration** (the breaking change): rework `ModelDownloadManager` from
   manual cache-dir peeking (`Repo.folderName`) to the new ModelHub API — resumable
   downloads, byte-level progress, artifact validation. Keep the per-model progress UI
   and "Download All Models" contract intact. Existing on-disk model caches must remain
   usable (no forced re-download) or the migration behavior must be documented.
3. **Fused decoder**: enable the optional fused decoder path (~7–9% RTFx) for batch ASR
   (pipeline + dictation's batch engine).
4. **Deterministic diarization**: enable deterministic K-Means clustering in
   `OfflineDiarizerConfig` (Services.swift:2934); adopt compute-unit configuration with a
   sensible automatic default (no new UI unless trivial).
5. **Per-term CTC vocabulary thresholds**: adopt the new custom-vocabulary controls in
   both paths (batch rescoring in `PipelineProcessor.applyVocabularyBoosting`, dictation's
   `configureVocabularyBoosting`) to cut false positives. Data model may gain an optional
   per-term threshold; UI stays the existing term-chip list (no per-term UI this phase).
6. **No dictation-engine changes** beyond what compiling against 0.15.5 requires — the
   streaming migration is Phase B.

## Phase B — Parakeet Unified + streaming dictation (delegate: agy-unified, after A)

1. Migrate batch transcription (pipeline) and dictation to the **Parakeet Unified 0.6B**
   backend so one model serves both offline batch and chunked-attention streaming.
   Rework `TranscriptionModel` / `ModelKind` / Models-tab accordingly (v2/v3 TDT choice
   collapses or maps onto Unified; migration for the persisted setting).
2. Re-enable **live streaming dictation**: subscribe the streaming manager to the existing
   mic `AsyncStream<AVAudioPCMBuffer>`; inject confirmed/stable text incrementally, flush
   volatile text on stop.
3. **Risk (this failed before)**: the earlier SlidingWindowAsrManager attempt produced
   decoder loops and hallucinated repetitions, worse than batch (`DictationManager.swift`
   header). Mitigations required:
   - Keep the batch burst-mode engine as a user-visible fallback
     (`AppSettings.dictationMode`: streaming | batch; default streaming only if the
     quality gate below passes, else default batch).
   - Quality gate (machine-checkable): synthesize fixture speech via `say -o` → wav,
     run the same audio through streaming and batch paths; streaming output must contain
     the expected key words and contain no token repeated >3× consecutively; assert in a
     test target that can run with models present (skip cleanly when models absent).
   - Preserve all dictation reliability machinery: mic-stall detect + rebuild,
     empty-capture guard, hotkey debounce, push-to-talk race guard, 4 h cap, keep-alive.
4. Lower-latency streaming tier: pick the latency tier appropriate for dictation;
   document the choice.

## Phase C — Speaker pre-enrollment (delegate: agy-enroll, after A, parallel with B)

1. Pre-enroll known voices into the diarizer run: feed `SpeakerStore` profile embeddings
   (and the user's own profile) into 0.15.5's speaker pre-enrollment so app-track clusters
   come out pre-identified, reducing Name-Speakers prompts.
2. Build/maintain a **user profile automatically from mic-track embeddings** (mic = the
   user by construction; `settings.userName` already labels the mic track —
   SpeakerAssignment.swift:102). This gives the diarizer a high-quality enrollment of the
   user for the app track (echo/bleed cases) and cross-meeting stability.
3. Existing post-hoc `SpeakerMatcher` flow remains the fallback for un-enrolled voices;
   thresholds/margins unchanged.

## Definition of Done (per phase; orchestrator re-runs these in the worktree)

- `swift build` clean (no errors; no new warnings).
- `swift run HeardTests` — all tests pass (baseline 212+; new logic gets new tests).
- Phase A: `Package.resolved` shows 0.15.5; ModelDownloadManager has no manual
  `Repo.folderName` cache-peeking left where ModelHub provides status; docs of any
  cache-migration behavior.
- Phase B: quality-gate fixture test present and green (or cleanly skipped w/o models,
  with a recorded local run showing green); dictation mode setting + fallback wired.
- Phase C: unit tests for the enrollment mapping (profile → diarizer input, cluster →
  name resolution); graceful behavior with an empty SpeakerStore.
- `handoff.md` updated by each delegate for its phase.

## Out of scope

Word-level timestamps (explicitly excluded); TTS backends; any UI redesign; cloud APIs.
