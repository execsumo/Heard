# Transcript History + Speakers — UI Plan

How to give users a real history of their meetings, and how speakers fit into it.

This document is intended to be **delegation-ready**: the decisions are made (see
*Resolved decisions*), Phase 1 has a concrete data spec and acceptance criteria,
and the sequencing constraints are spelled out. Phases 2–3 remain a sketch.

> **Addendum (post-v0.2.6, unreleased):** `PipelineJob`/`TranscriptDocument` gained a
> `chatMessages: [ChatMessage]` field (opt-in meeting-chat scraping — see `handoff.md`'s
> dated status entry). The Phase 1 `TranscriptRecord` schema below should carry a
> `hasChatMessages: Bool` alongside `hasUnnamedSpeakers`, and Phase 1's metadata-card
> detail view should surface a chat-message count the same way it surfaces notes count —
> both are cheap additions now, while the schema is still being drafted, versus a
> migration later.

---

## The core idea: one **Library**, two linked views

Today there is no history — just `.md` files in a folder and the last 3 in the dropdown. "Open Transcripts" dumps the user into Finder.

Transcripts and speakers are not two separate features; they're two sides of the same data. A meeting *has* participants; a person *appears in* meetings. So the right model is a **single Library window** with two cross-linked entry points — **Meetings** and **People** — not two disconnected lists (and definitely not a speaker list buried in Settings).

This also retires the v2 wart where "Speakers" was a settings tab with no settings. Speakers becomes a *view* in the Library; the one actual setting (archive retention) moves with it.

---

## Resolved decisions

These were the open questions in the prior draft. They are now decided, so a builder does not have to guess:

1. **Unify speakers into the Library** — People becomes a Library view, not a Settings tab. The archive-retention setting moves with it (Phase 2). *(Removes the empty-Settings-tab wart.)*
2. **Three-pane layout** — sidebar | list | detail. Scales better as smart-groups/filters grow.
3. **Persisted index store + folder reconciliation** as the source of truth — not a live folder scan. A pure folder scan is simpler but fragile to out-of-band edits.
4. **Open transcripts externally in Phase 1** — in-app rendering is **deferred entirely** to a later phase. The transcript `.md` format is custom (`**Speaker:**` blocks, `[mm:ss]` notes, participants header) and does not lay out cleanly via `AttributedString(markdown:)`; a faithful renderer is a multi-day task that should not block the headline value. Phase 1 "Open" launches the `.md` in the default app; "Reveal in Finder" stays as a secondary action.
5. **Index starts empty; only new meetings are indexed** — no backfill parsing of pre-existing `.md` files. Records are written by the pipeline going forward. Existing `.md` remain in the folder and stay reachable via Finder. *(Implication: the Library is empty on first launch after upgrade — Phase 1 must ship a real empty state, see below.)*

---

## Where it lives

A dedicated **`Window` scene (id `"library"`)**, opened from the menu-bar dropdown — *not* Settings. Settings is for preferences; the Library is content. This matches macOS convention (Music/Photos library vs. Settings).

Menu-bar changes:
- "Open Transcripts" (opens Finder) → **"Library…"** (opens the window). Keep "Reveal in Finder" as a per-item action inside.
- "Recent Transcripts" stays in the dropdown for quick access. Today it reads completed jobs from the ephemeral `PipelineQueueStore`; **Phase 1 rewires it to read from the new `TranscriptStore`**, and clicking an item opens the Library window focused on that meeting (detail = metadata; "Open" launches the file).

---

## Layout — three-pane `NavigationSplitView` (macOS-idiomatic)

```
┌──────────────────────────────────────────────────────────────┐
│ Heard Library                                        [ search ]│
├────────────┬─────────────────────────┬───────────────────────┤
│ MEETINGS   │ Q1 Planning             │ # Q1 Planning          │
│ ▸ All      │ Today · 48m · 4 people  │ Jun 13 · 48m           │
│ ▸ This Week│─────────────────────────│ Alice · Bob · Carol·Me │
│ ▸ Flagged  │ Standup                 │ ────────────────────── │
│            │ Yesterday · 15m · 3     │ 2 notes · 1 unnamed    │
│ PEOPLE     │─────────────────────────│ [Open] [Reveal] [Name…]│
│ ▸ All      │ 1:1 with Bob            │ [Rename] [Delete]      │
│   Alice    │ Mon · 32m · 2           │                        │
│   Bob      │                         │ (transcript opens in   │
│   Carol    │                         │  the default app)      │
└────────────┴─────────────────────────┴───────────────────────┘
```

- **Sidebar** — source switch: Meetings (with smart groups: All / This Week / Flagged) and People (All + individuals). *Flagged/smart-groups beyond All + This Week are Phase 3.*
- **List** — meetings or people, sorted newest-first, searchable.
- **Detail** — in **Phase 1** the meeting detail is a **metadata card + actions** (not the rendered transcript). In-app rendering is a later phase.

### Meeting detail (Phase 1)
A metadata card: title, date, duration, participant chips (from `rosterNames`), notes count, and an "unnamed speakers" indicator. Actions: **Open** (launch `.md` externally) · **Reveal in Finder** · **Rename** · **Delete** · (**Retry**, if the job failed) · **Name speakers…** when unnamed speakers remain (opens the existing `speaker-naming` window scene — no new naming UI is built). Export/Share is Phase 3.

A missing-file record (see reconciliation) renders disabled with a "File missing" badge and only a **Remove from Library** action.

### Person detail — Phase 2 (the cross-link payoff)
```
┌────────────┬─────────────────────────┬───────────────────────┐
│ PEOPLE     │ Bob                     │ ▶ ━━━━━━ voice sample  │
│   Alice    │ 12 meetings · 6h 20m    │ 12 meetings · 6h 20m   │
│ ▸ Bob      │ Last seen: yesterday    │ First seen: Mar 3      │
│            │                         │ ────────────────────── │
│            │                         │ MEETINGS WITH BOB      │
│            │                         │ • Standup — yesterday →│
│            │                         │ • 1:1 with Bob — Mon  →│
│            │                         │ • Q1 Planning — Jun 13→│
│            │                         │ [Rename] [Merge] [Del] │
└────────────┴─────────────────────────┴───────────────────────┘
```
Reuses all current Speakers-table data (voice playback, name, meeting count, time, last seen) plus **the list of meetings the person appears in**, each linking back to the meeting's detail. Merge/rename/delete carry over from the existing Speakers tab. This requires the persisted speaker-ID join (below) and is therefore Phase 2.

---

## Data model — `TranscriptStore`

Cross-linking ("Bob's meetings", "this meeting's people") needs a persisted archive that doesn't exist yet. `PipelineQueueStore` is a *processing* queue, not an archive — jobs are dismissed via `PipelineQueueStore.remove()`, and it stores participant **names** (`rosterNames: [String]`), not speaker **IDs**.

Introduce a lightweight **`TranscriptStore`** — a persisted JSON index, one record per completed meeting, **decoupled from the ephemeral queue** so dismissing a job from the queue never removes it from the Library.

### Phase 1 record schema

```swift
struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID                 // == PipelineJob.id, for traceability
    var title: String
    let start: Date
    let end: Date
    var duration: TimeInterval   // stored, not recomputed at read time
    var transcriptPath: URL
    var rosterNames: [String]    // for participant chips; already on the job
    var notesCount: Int
    var hasUnnamedSpeakers: Bool
    var fileMissing: Bool        // set by reconciliation; default false
    // participantSpeakerIDs: [UUID]  ← added in Phase 2 (see below)
}
```

- **Storage**: JSON at `~/Library/Application Support/Heard/transcripts.json`. Follow the existing store conventions: corrupt-file quarantine to `<name>.corrupt` (as `SpeakerStore`/`PipelineQueueStore` already do), single-pass writes.
- **Record identity**: `id == PipelineJob.id`. Upsert by `id` so a retry/rewrite updates the existing record rather than duplicating it.

### Write trigger

A record is written/updated when a pipeline job reaches **`.complete`** (transcript file written) — at the same point the job would otherwise just sit in the queue. The write is independent of the queue: it must survive `PipelineQueueStore.remove()` and app restart. `Rename`/`Delete` actions in the Library update or remove the corresponding record (and, for Delete, the `.md` file).

### Folder reconciliation (Phase 1 minimum)

On launch, for each record check `FileManager.default.fileExists(atPath: transcriptPath.path)`:
- **Present** → `fileMissing = false`.
- **Missing** (user moved/renamed/deleted the `.md` outside the app) → set `fileMissing = true`; the row renders disabled with a "File missing" badge and a **Remove from Library** action. Do **not** crash or show dead rows.

Out of scope for Phase 1: relinking a moved file, and *importing* `.md` files the app never wrote (consistent with the empty-start decision — the app only tracks what it produced). These are Phase 3 candidates.

### Phase 2 addition — the speaker-ID join

Persisting `participantSpeakerIDs: [UUID]` per record powers both directions of the cross-link ("this meeting's people" ↔ "this person's meetings"). The speaker IDs are known at speaker-assignment time but currently discarded; Phase 2 threads them into the record. `SpeakerProfile` gains no back-reference — the join lives entirely in `TranscriptRecord.participantSpeakerIDs`, queried both ways.

---

## Empty & onboarding state (Phase 1, required)

Because the index starts empty and is not backfilled, **the Library is empty on first launch after upgrade.** Phase 1 must therefore ship a genuine empty state in the Meetings list: a short explainer ("Meetings you record from now on will appear here") plus a **Reveal Transcripts Folder in Finder** button, so existing users can still reach their old `.md` files. Without this, the feature looks broken on day one.

---

## Acceptance criteria & testing

This repo has a strong pure-logic + unit-test culture (`PipelineQueueStore`, `SpeakerStore`, `MeetingDetectionState` are all pure and tested via the in-house `HeardTests` harness). The new logic must match it:

- **`TranscriptStore` is pure and unit-tested**: load, save, upsert-by-id (idempotent on retry), remove, and corrupt-file quarantine — mirroring `PipelineQueueStore`'s tests.
- **Reconciliation is pure and unit-tested**: present → not missing; absent → `fileMissing = true`; reconciliation never deletes records.
- **List logic is pure and unit-tested**: search filtering and newest-first sort over a record array, independent of any view.
- **Phase 1 done = green**: `swift build` clean and `swift run HeardTests` all-pass, with new tests covering the three areas above.
- **Manual smoke**: record (or simulate) a meeting → it appears in the Library → Open launches the `.md` → Rename/Delete reflect in both the index and the folder → move the `.md` in Finder, relaunch → row shows "File missing" with Remove.

---

## Build coordination / sequencing

- **Rebase on the `Views.swift` split.** The UI was just split by view area (`DesignSystem.swift`, `MenuBarView.swift`, `SettingsView.swift`, `SettingsTabs.swift`, `SettingsComponents.swift`, `SpeakerNamingView.swift`). Library views go in **new files** (e.g. `LibraryView.swift`, `LibraryMeetingDetail.swift`), reusing `DesignSystem.swift` primitives — do not reintroduce a monolith.
- **Settings-reorg collision (Phase 2).** There is a settings reorganization in flight (`settings-reorg-v2.md`) that also touches the **Speakers** settings tab that Phase 2 removes. Resolve the sequencing between that reorg and Phase 2 before starting Phase 2, or they will conflict over the same tab.
- **Menu-bar "Recent" rewire (Phase 1).** "Recent" currently reads ephemeral completed jobs from `PipelineQueueStore`; Phase 1 repoints it at `TranscriptStore` and changes its click action to open the Library.

---

## Suggested phasing

1. **Phase 1 — Meetings history (metadata + open externally).** `TranscriptStore` + write-on-complete + launch reconciliation; `library` Window scene with three-pane layout; Meetings list (search, newest-first) + metadata detail; actions (Open externally / Reveal / Rename / Delete / Retry-if-failed / Name speakers…); empty state; rewire dropdown "Recent" + "Library…". Pure logic unit-tested. *Ships the headline value without the rendering or speaker-join risk.*
2. **Phase 2 — People + cross-link.** Add the People view, persist `participantSpeakerIDs`, build both-direction links, migrate the Speakers settings tab (and retention setting) into the Library. *Retires the Speakers settings tab — coordinate with `settings-reorg-v2.md`.*
3. **Phase 3 — Polish.** In-app transcript rendering (custom speaker-block renderer), filters (date/participant), Flagged/smart groups, export/share, relink-moved-file, optional import of external `.md`.
