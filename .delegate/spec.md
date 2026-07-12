# SPEC: Speaker pre-enrollment (Phase C)

## 1. OBJECTIVE

Leverage FluidAudio 0.15.5's speaker pre-enrollment so app-track diarization clusters
come out pre-identified from Heard's existing `SpeakerStore` profiles — including an
automatically maintained profile for the user themself built from mic-track embeddings —
reducing how often the Name Speakers prompt is needed.

## 2. CONTEXT

- You are in a git worktree of `/Users/hgill/projects/Heard` (Swift Package Manager,
  macOS 15+). Read `CLAUDE.md`, `handoff.md`, `plans/fluidaudio-0.15.5.md` (Phase C)
  first. FluidAudio is already at 0.15.5 on this branch.
- **Do not guess APIs.** Read the real diarizer sources under
  `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/` — verify whether 0.15.5's
  "improved speaker pre-enrollment" applies to the OFFLINE path Heard uses
  (`OfflineDiarizerManager`/`OfflineDiarizerConfig`, `Services.swift` ~line 2934) or only
  to the streaming/Sortformer diarizer. This determines the whole design — check FIRST.
- Current flow (post-hoc matching, keep as fallback): diarizer produces anonymous
  clusters + chunk embeddings → `SpeakerEmbeddingAggregator` builds per-speaker centroids
  → `SpeakerMatcher.matchSpeakers` (cosine distance, `AppSettings.speakerMatchThreshold`
  default 0.30, confidence margin 0.10) against `SpeakerStore` (`speakers.json`) →
  unmatched clusters become Name Speakers candidates.
- Mic track: single known speaker, labeled from `settings.userName` (fallback "Me") in
  `SpeakerAssignment.swift` ~line 102. The mic track is diarization-free by design.
- Key files: `Sources/HeardCore/Services.swift` (runDiarization / runSpeakerAssignment /
  buildSpeakerEmbeddings), `Sources/HeardCore/SpeakerAssignment.swift`,
  `Sources/HeardCore/Stores.swift` (SpeakerStore), `Sources/HeardCore/AppModel.swift`
  (saveSpeakerName / merge flows).
- Design decisions (already made — implement, don't relitigate):
  - **User self-profile**: after a successful pipeline run, build/refresh a profile for
    `settings.userName` from MIC-track embeddings (mic = the user by construction).
    Reuse the existing embedding pipeline (VAD-mapped chunk embeddings +
    `SpeakerEmbeddingAggregator`) and the existing merge path (case-insensitive name
    match folds into the existing profile via `SpeakerMatcher.addEmbedding`; respect
    `maxEmbeddingsPerSpeaker`). Skip when `userName` is empty. The user profile
    participates in app-track matching like any other (identifies echo/bleed of the
    user's voice in app audio).
  - **Pre-enrollment**: if the offline diarizer supports enrolled/known speakers, feed it
    all `SpeakerStore` profiles with non-placeholder names (placeholders `Speaker_*` are
    excluded); clusters the diarizer attributes to an enrolled speaker resolve directly
    to that profile (no Name Speakers candidate). Un-enrolled clusters flow through the
    existing SpeakerMatcher fallback unchanged.
  - Thresholds/margins of the existing matcher stay untouched.

## 3. DEFINITION OF DONE (I will run these exact checks myself)

1. `swift build` exits 0, no new warnings.
2. `swift run HeardTests` — all pass (baseline 213 + new tests).
3. User self-profile: unit tests for the pure logic (profile created when absent; merged
   case-insensitively when present; skipped when userName empty; embedding cap
   respected).
4. Pre-enrollment (if the offline API supports it): unit tests for the mapping logic
   (profiles → enrollment input excludes placeholders; enrolled-cluster → profile
   resolution; empty SpeakerStore is graceful — behavior identical to today).
5. Existing post-hoc matching fallback verifiably unchanged for un-enrolled voices
   (existing tests untouched and green).
6. `handoff.md` dated entry describing what was possible (offline pre-enrollment or not)
   and what shipped.

## 4. ESCALATION — stop and ask me (do not guess) if:

- 0.15.5's pre-enrollment is Sortformer/streaming-only and the offline path Heard uses
  has no equivalent — report what IS available and wait for my call before building any
  workaround. (The user self-profile part proceeds regardless; it doesn't depend on the
  diarizer API.)
- Implementing enrollment would require replacing `OfflineDiarizerManager` with a
  different diarizer backend — that's a scope expansion I must approve.
- Any DoD check fails the same way after 2–3 distinct fix attempts.

## 5. REVERSE CHANNEL

To reach me, run ONE command from your worktree root:

    ./.delegate/notify needs-input "the question or decision you need answered"
    ./.delegate/notify blocked     "what you are stuck on"
    ./.delegate/notify done        "summary of what you finished"

then STOP AND WAIT at your prompt — do not exit, do not continue. I will review and
either confirm or send corrections. After I reply, run `./.delegate/notify resume`
BEFORE continuing — otherwise your status stays stuck.

## 6. OUTPUT

On finish: commit your work in the worktree (logical commits, message style matching
`git log`), re-run the DoD one final time, then
`./.delegate/notify done "<summary + test count + whether offline pre-enrollment was possible>"`
and stop at your prompt.

## 7. SCOPE BOUNDARY

Stay inside your worktree. Do not push, open PRs, tag, or release. Do not touch
`~/Library/Application Support/Heard/` user data. No transcription/dictation-engine work
(a parallel delegate owns it — keep your Services.swift edits confined to the
diarization/speaker-assignment regions). Do not modify `scripts/release.sh` or CI.
