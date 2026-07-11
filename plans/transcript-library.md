# Plan: Transcript Library of Prior Meetings

**Status:** planned, not started
**Execution model:** delegate skill (herdr panes) — two delegates in parallel worktrees:
- **Delegate A (backend):** `agy` (Antigravity), model **Gemini 3.1 Pro (High)** — pinned via `--model` (confirm exact string against `agy models` at launch; minimum "High" reasoning tier).
- **Delegate B (UI):** `cline`, provider **cline-pass**, model **cline-pass/glm-5.2**, `--thinking xhigh` (provider config already defaults to xhigh; pin explicitly anyway).

Both models are external vendors (spreads token load off the Claude quota) and both run at ≥ high reasoning effort.

---

## 1. Feature design (decisions made)

A read-only library of prior meeting transcripts inside Heard. The transcript itself does **not** render in-app — a row click opens the `.md` file in the user's default Markdown app (`NSWorkspace.shared.open`).

**Data source.** The transcripts already on disk in the configured output folder (`AppSettings.outputDirectory`, default `FileManager.default.heardOutputDirectory`). No new persistence, no index file — scan + parse on demand. Metadata comes from the known transcript format written by `TranscriptWriter.write` (Services.swift:2110):

- Filename: `yyyy-MM-dd_<sanitized title>.md`, with `_2`, `_3`… dedup suffixes.
- Header (first ~6 lines):
  ```
  # <Title>

  **Date:** yyyy-MM-dd HH:mm – HH:mm
  **Duration:** Xh Ym
  **Participants:** Name, Name, Name

  ---
  ```
- Standalone note files (`yyyy-MM-dd_HH-mm-ss_note.md`, written by the no-meeting note composer) live in the same folder and have **no** header — v1 excludes them from the library (skip files whose stem ends in `_note`; never crash on any malformed `.md`).

**UI placement.** A new **"Meetings"** tab in the Settings window (between Speakers and Advanced; the sidebar is a custom HStack in SettingsView.swift). Card-based layout using the existing Paper design-system primitives (`SettingsCard`, `CardRow`, DesignSystem.swift). Contents:

- Search field (matches title + participants) and a Refresh button.
- Table sorted newest-first by default; sortable columns: Title, Date, Duration, Participants.
- Row double-click and a per-row "Open" affordance → `NSWorkspace.shared.open(fileURL)`.
- Context menu: **Open**, **Reveal in Finder** (`NSWorkspace.shared.activateFileViewerSelecting`), **Move to Trash** (with confirmation; `FileManager.trashItem`).
- Empty state ("No transcripts yet — they'll appear here after your first recorded meeting") and a missing-folder state.
- Rescan on tab appearance + on Refresh. No live file watcher in v1.
- Menu bar dropdown gets one compact row, "Transcripts…", that opens Settings pre-selected to the Meetings tab (dropdown has a fixed max height — one row only).

**Scope guardrails (from CLAUDE.md / spec.md):** single-process menu bar app, no new dependencies, no cloud APIs, targeted changes only. Orchestrator updates `spec.md` and `handoff.md` at integration time (delegates do not touch docs).

---

## 2. Phase 0 — orchestrator seeds the shared contract (do this before spawning)

To let A and B run in parallel with disjoint files, commit a stub `Sources/HeardCore/TranscriptLibrary.swift` to the branch both worktrees fork from. The public API below is **frozen** — delegates implement/consume it but do not change signatures without escalating.

```swift
import Foundation

/// One prior meeting transcript on disk, parsed from the file header
/// (with filename/mtime fallback when the header is missing or malformed).
public struct TranscriptRecord: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let date: Date            // header **Date:** start, else file mtime
    public let duration: TimeInterval?   // nil when header absent/malformed
    public let participants: [String]     // empty when header absent

    public init(url: URL, title: String, date: Date,
                duration: TimeInterval?, participants: [String]) { … }
}

/// Scans the output directory for meeting transcripts. Pure scan/parse core
/// (static, unit-testable) + a thin ObservableObject wrapper for the UI.
@MainActor
public final class TranscriptLibrary: ObservableObject {
    @Published public private(set) var records: [TranscriptRecord] = []
    public init() {}

    /// Rescan `directory` and publish the result, sorted newest-first.
    public func refresh(directory: URL) { records = Self.scan(directory: directory) }

    /// Pure core: enumerate top-level `.md` files (skip hidden, skip
    /// `*_note.md`), parse each via `parseRecord`, sort newest-first.
    /// Missing/unreadable directory → [].
    public static func scan(directory: URL) -> [TranscriptRecord] { [] } // stub

    /// Parse one transcript's metadata from its first ~1 KB + file attributes.
    /// Never throws for malformed content — falls back to filename/mtime.
    /// Returns nil only for files that should not appear (e.g. `*_note.md`).
    public static func parseRecord(url: URL, header: String,
                                   modificationDate: Date) -> TranscriptRecord? { nil } // stub
}
```

(Exact stub wording is the orchestrator's call at seed time; the shape above is the contract.)

Commit message: `Add TranscriptLibrary contract stub for transcript-library feature`.

---

## 3. Delegate A — backend (agy / Gemini 3.1 Pro (High))

**Launch:**
```bash
BIN="$HOME/.claude/skills/delegate/bin"
# write spec to file first — it's long
PANE_A=$("$BIN/spawn" agy-tlib /Users/hgill/projects/Heard -- \
  agy -i "Read and execute the spec at .delegate/spec.md" \
  --add-dir @WT@ --model "Gemini 3.1 Pro (High)" --dangerously-skip-permissions)
"$BIN/monitor" "$PANE_A" "<WT_A>/.delegate/signal" &
```
Write the spec below to `<WT_A>/.delegate/spec.md` after spawn prints the worktree path (or pre-stage and re-seed).

### Spec A (paste verbatim, fill in `<ORCH_PANE_ID>`)

```
1. OBJECTIVE
Implement the scan/parse backend for Heard's transcript library:
TranscriptLibrary.scan / parseRecord in Sources/HeardCore/TranscriptLibrary.swift,
plus unit tests, so the app can list prior meeting transcripts from disk.

2. CONTEXT
- Repo: a git worktree of /Users/hgill/projects/Heard (you are already in it).
  Swift Package Manager app, macOS 15+, Apple Silicon. Build: `swift build`.
  Tests: `swift run HeardTests` (custom harness — test(...)/testAsync(...) in
  Tests/…; NO XCTest). Read CLAUDE.md and handoff.md first.
- The public API in Sources/HeardCore/TranscriptLibrary.swift is a frozen
  contract — implement the stubbed bodies; do NOT change public signatures.
- Transcript format is produced by TranscriptWriter.write in
  Sources/HeardCore/Services.swift (~line 2110). Read it. Key facts:
  * Filename: `yyyy-MM-dd_<title>.md` with `_2`, `_3`… dedup suffixes.
  * Header: `# Title`, blank, `**Date:** yyyy-MM-dd HH:mm – HH:mm`,
    `**Duration:** Xh Ym`, `**Participants:** A, B, C`, blank, `---`.
  * Date format string: "yyyy-MM-dd HH:mm" (Formatting.transcriptDateFormatter,
    Stores.swift). Parse the start timestamp for TranscriptRecord.date.
- Standalone notes `yyyy-MM-dd_HH-mm-ss_note.md` share the folder and have no
  header: parseRecord must return nil for stems ending in `_note`.
- Robustness requirements: read at most ~1 KB per file for metadata; malformed
  or missing header falls back to filename-derived title (strip date prefix and
  `_N` suffix, underscores → spaces is NOT needed — titles are sanitized, keep
  as-is) and file modification date, duration nil, participants []. Never
  throw/crash on arbitrary file content. Missing/unreadable directory → [].
  Sort newest-first (date desc, then filename desc for stability).
- Do NOT touch: any UI file (SettingsView/SettingsTabs/MenuBarView/
  SpeakerNamingView/DesignSystem), Services.swift, AppModel.swift, spec.md,
  handoff.md, Package.swift. Your changes: TranscriptLibrary.swift,
  the HeardTests target (add runTranscriptLibraryTests + register it in the
  test runner main), nothing else.

3. DEFINITION OF DONE (I will run these myself in your worktree)
- `swift build` exits 0 with no new warnings.
- `swift run HeardTests` exits 0, all tests pass, and the output includes a new
  runTranscriptLibraryTests suite covering at minimum:
  * happy-path header parse (title, date, duration seconds, participants list)
  * `_2` dedup filename still parses; sort stability
  * missing header → filename/mtime fallback, duration nil, participants []
  * `*_note.md` excluded; non-.md and hidden files ignored
  * missing directory → []
  * malformed Duration/Date lines tolerated (fallback, no crash)
  * newest-first ordering
- `git diff --stat` touches only TranscriptLibrary.swift and test files.

4. ESCALATION — stop and ask me (do not guess) if:
- The frozen public API cannot express something you need.
- A DoD check conflicts with what the code shows.
- Same failure ≥2 times, or the fix balloons beyond the files listed above.

5. REVERSE CHANNEL
To reach me, run ONE command from your worktree:
  ./.delegate/notify needs-input "the question or decision you need answered"
  ./.delegate/notify blocked     "what you are stuck on"
  ./.delegate/notify done        "summary of what you finished"
then STOP AND WAIT in your pane — do not exit, do not continue.
I will review and either confirm or send corrections. After I reply, run
  ./.delegate/notify resume
BEFORE continuing. My pane id: <ORCH_PANE_ID>.

6. OUTPUT
On finish: run ./.delegate/notify done "<summary>", then stop and wait at your
prompt. Do not exit.

7. SCOPE BOUNDARY
Stay in your worktree. Do not push, open PRs, commit to other branches, or run
anything outward-facing or irreversible.
```

---

## 4. Delegate B — UI (cline / cline-pass glm-5.2, thinking xhigh)

**Launch:**
```bash
PANE_B=$("$BIN/spawn" cline-tlib /Users/hgill/projects/Heard -- \
  cline -i "Read and execute the spec at .delegate/spec.md" \
  -c @WT@ -P cline-pass -m cline-pass/glm-5.2 --thinking xhigh \
  --auto-approve true --data-dir "$HOME/.cline-delegate-tlib")
"$BIN/monitor" "$PANE_B" "<WT_B>/.delegate/signal" &
```
(`--data-dir` keeps its state isolated from the interactive cline install; `-i` is mandatory so the pane survives completion.)

### Spec B (paste verbatim, fill in `<ORCH_PANE_ID>`)

```
1. OBJECTIVE
Build the "Meetings" tab UI for Heard's transcript library: a searchable,
sortable list of prior meeting transcripts that opens the underlying .md file
on click, plus a menu-bar row that deep-links to the tab.

2. CONTEXT
- Repo: a git worktree of /Users/hgill/projects/Heard (you are already in it).
  SwiftUI menu bar app, SPM, macOS 15+. Build: `swift build`. Tests:
  `swift run HeardTests`. Read CLAUDE.md and handoff.md first.
- Consume — do not modify — the frozen API in
  Sources/HeardCore/TranscriptLibrary.swift: TranscriptRecord and
  @MainActor TranscriptLibrary (ObservableObject; call
  refresh(directory:) and read .records). The backend is being implemented in
  parallel; scan() currently returns [] — build against the contract, not the
  behavior. For visual testing, hand-write 2–3 sample transcript .md files
  into a temp folder and point the app's output directory setting at it.
- The output directory comes from settingsStore.settings.outputDirectory
  (a String path — see how PipelineProcessor builds its URL in Services.swift).
- UI conventions (match them exactly — read DesignSystem.swift first):
  * New tab "Meetings" in the Settings window, sidebar entry between Speakers
    and Advanced. Sidebar/tab plumbing: SettingsView.swift + SettingsTabs.swift.
  * Card layout via SettingsCard/CardRow; Paper palette tokens only; the
    Speakers tab's table (SettingsTabs.swift) is the pattern to follow for
    search/sort/table styling.
- Tab contents:
  * Search field filtering on title + participants (case-insensitive).
  * Table, default sort date-desc; sortable: Title, Date, Duration,
    Participants. Duration renders like "1h 05m" / "14m"; reuse the existing
    durationText-style formatting convention from the Speakers tab.
  * Double-click a row AND a per-row Open control →
    NSWorkspace.shared.open(record.url).
  * Context menu: Open / Reveal in Finder
    (NSWorkspace.shared.activateFileViewerSelecting) / Move to Trash
    (confirmation alert, FileManager.default.trashItem, then refresh).
  * Empty state and missing-folder state with friendly copy.
  * Refresh button; also refresh on tab appear (.onAppear/.task).
- Menu bar: one compact row "Transcripts…" in the MenuBarView dropdown that
  opens the Settings window pre-selected to the Meetings tab (follow how the
  existing dropdown opens Settings; keep the dropdown short — one row only).
- New view code goes in a new file Sources/HeardCore/TranscriptLibraryView.swift.
  Allowed edits: that new file, SettingsView.swift, SettingsTabs.swift,
  MenuBarView.swift, and (only if tab-enum/AppModel wiring demands it) a
  minimal AppModel.swift touch. Do NOT touch: TranscriptLibrary.swift,
  Services.swift, Stores.swift, CoreModels.swift (unless the settings-tab enum
  lives there — then enum case addition only), spec.md, handoff.md,
  Package.swift. No new dependencies.

3. DEFINITION OF DONE (I will run these myself in your worktree)
- `swift build` exits 0 with no new warnings.
- `swift run HeardTests` exits 0 (existing suite stays green).
- `git diff --stat` touches only the files allowed above.
- Code inspection: open action uses NSWorkspace.shared.open; all colors come
  from the Paper token set; no force-unwraps on file operations.
- Manual observation (I run it): ./scripts/bundle.sh, open Settings →
  Meetings; with sample .md files in the configured output folder the list
  shows title/date/duration/participants; double-click opens the file in the
  default editor; Reveal in Finder works; menu-bar "Transcripts…" row opens
  the tab.

4. ESCALATION — stop and ask me (do not guess) if:
- The frozen TranscriptLibrary API is insufficient for the UI.
- The settings-tab enum can't be extended without touching forbidden files.
- Same failure ≥2 times, or the change balloons beyond the files listed above.

5. REVERSE CHANNEL
To reach me, run ONE command from your worktree:
  ./.delegate/notify needs-input "the question or decision you need answered"
  ./.delegate/notify blocked     "what you are stuck on"
  ./.delegate/notify done        "summary of what you finished"
then STOP AND WAIT in your pane — do not exit, do not continue.
I will review and either confirm or send corrections. After I reply, run
  ./.delegate/notify resume
BEFORE continuing. My pane id: <ORCH_PANE_ID>.

6. OUTPUT
On finish: run ./.delegate/notify done "<summary>", then stop and wait at your
prompt. Do not exit.

7. SCOPE BOUNDARY
Stay in your worktree. Do not push, open PRs, commit to other branches, or run
anything outward-facing or irreversible.
```

---

## 5. MONITOR → VERIFY → INTEGRATE (orchestrator)

1. One backgrounded `bin/monitor` per delegate (commands above). React only to ATTENTION lines; remember agy flaps `done` transiently mid-subprocess — trust only sustained quiescence or the signal file.
2. **Verify A** in its worktree: run `swift build`, `swift run HeardTests`, confirm `runTranscriptLibraryTests` present and green, `git diff --stat` scope check.
3. **Verify B** in its worktree: build + tests + scope check + code inspection per DoD. Manual UI pass happens post-merge (B was built against the stub).
4. **Integrate:** merge A's branch first (real scan behavior), then B's on top (disjoint files — conflicts should be nil; if the tab enum collides, resolve by hand). On the integrated tree: `swift build`, `swift run HeardTests`, then `./scripts/bundle.sh` and run the full manual observation list from Spec B's DoD against real transcripts in `~/Library/Application Support/Heard/` output.
5. Update `spec.md` (new Meetings tab + library feature) and `handoff.md` (status entry) — orchestrator does this, not delegates.
6. Teardown: capture final pane summaries, close panes (highest id first), `git worktree remove --force`, delete `delegate/*` branches after merge.

## Risks / notes

- **Contract drift:** if either delegate escalates that the frozen API is wrong, fix the contract once centrally and relay to both — never let them diverge silently.
- **Old transcripts** predating recent format tweaks may lack Participants or have odd Date lines — the fallback path (mtime + filename title) covers them; test explicitly.
- **`_note.md` exclusion** is v1 scope; a "Notes" section in the library is a possible follow-up.
- cline delegate is untested in this setup relative to codex/agy — if it fails to seed properly with a file-based spec, fall back to passing the spec inline as the first prompt argument.
