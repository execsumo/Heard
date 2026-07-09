# Heard Settings — Reorganization v2 (deletion-first)

Supersedes [settings-reorg-proposal.md](settings-reorg-proposal.md). v1 rearranged furniture; this pass asks whether each piece should exist, anchors on user flows, pulls non-settings out of Settings, and commits to the calls v1 left open.

> **Addendum (post-v0.2.6, unreleased):** a new "Include Meeting Chat in Transcript" toggle (`AppSettings.includeMeetingChat`, default **off**) was added to the live Recording tab as its own "Meeting Chat" section, alongside "Meeting Notes." This proposal predates that addition — when executing this reorg, give chat scraping the same "shared engine, opt-in" treatment as Custom Vocabulary (visible, not gated) and update the ~17-setting count accordingly. See `handoff.md`'s dated status entry for the feature's full design and its known limitations.



---

## What changed from v1, and why

| Roast | Fix in v2 |
|---|---|
| "You reduced nothing." | Every setting now has an explicit verdict: **Cut / Default / Keep / Gate / Move.** 38 → ~17 visible. |
| "Progressive disclosure as a filing cabinet." | Split **status** (model health, permissions) from **advanced** (tuning). Status is never gated; only true expert knobs are. |
| "You split General to fix overcrowding — added surface." | Re-anchored on flows, not nouns. Net **4 visible tabs** (was 6), + a separate Library window. |
| "Mic contradiction." | One rule, applied consistently (below). Mic, language, and vocabulary — all shared-engine — now live together. |
| "Speakers is data, not settings." | Promoted to a **Library window**, out of Settings entirely. |
| "No metric." | Concrete targets stated up front. |
| "Where's the user?" | Structure follows *set up once → use daily → review → tune rarely*. Daily use needs zero Settings trips. |

**The rule that resolves the mic question:** *anything that shapes audio-in or speech-to-text for the whole app is one group, placed in the flow where people think about transcript quality.* Mic, language, and custom vocabulary are all shared by meetings and dictation, so they sit together in **Recording** — not scattered, and not split between General and a feature tab. Hotkeys and feature toggles stay with their feature. No more "same principle, opposite conclusion."

---

## Success metrics (so this is falsifiable)

- **Visible settings: 38 → ~17.** The rest are cut, folded into defaults, gated, or moved out of Settings.
- **Default-visible tabs: 6 → 4** (General, Recording, Dictation, About). Advanced is gated; Speakers becomes a Library window.
- **A first-run user reaches "my meetings are being recorded" touching ≤1 tab.**
- **A daily user never opens Settings** — start/stop/pause and the active hotkeys all live in the menu-bar dropdown, which already exists.
- **≤7 decisions visible per screen-glance** (per section group, not per tab).

---

## The cut list (the headline)

| # | Setting | Verdict | Rationale |
|---|---|---|---|
| 1 | **Theme (System/Light/Dark)** | **CUT** | A menu-bar utility should follow the system. Manual theme is vanity surface. Keep the code path (`.system`), drop the picker. |
| 2 | **Filename Format (5 options)** | **DEFAULT + gate** | Five date permutations = a decision nobody made. Ship one default (`YYYY-MM-DD_MeetingName`); move the picker to Advanced for the rare user who cares. |
| 3 | **Low Memory Mode** | **AUTO + gate** | Don't ask the user about RAM. Auto-enable when detected memory ≤ 8 GB; expose a manual override only in Advanced. "Decide, don't gate." |
| 4 | **Models on Disk + Download/Unload** | **MOVE to Status** | This is app *health*, not a preference, and not "advanced" — the app is broken without it. Auto-download on first run; surface a missing/corrupt model via the existing banner pattern with a one-click fix. A manual "Manage models" view stays, gated, for re-download/unload. |
| 5 | **Permissions (×4)** | **MOVE to Status** | Grants aren't settings. Handle them in first-run onboarding and surface revocations via the dropdown/banners (already done for tap, mic, AX). Keep a read-only status strip in General that deep-links to System Settings. |
| 6 | **Speaker Archive retention** | **MOVE to Library** | Data-lifecycle control belongs with the speaker data it governs. |
| 7 | **Speakers tab** | **MOVE to Library window** | It's a management/data view; you admitted as much. Out of Settings. |
| 8 | **Developer Mode** | **GATE** | Can't fully cut — "Simulate Meeting" is intentional test tooling per project rules — but it has no business in the default surface. Bottom of Advanced. |
| 9 | **Diarization sensitivity slider** | **GATE** | Genuine expert knob (cosine-similarity threshold). Stays for fine-tuning, hidden by default. |
| 10 | **Model Keep-Alive (minutes)** | **GATE** | Performance tuning. Sensible default (2 min), hidden. |
| 11 | **Show Dock Icon** | **KEEP** | Cheap, one-time, legitimately wanted by some. Stays in General. |
| 12 | **Custom Vocabulary** | **KEEP (visible)** | Directly improves accuracy on jargon/names — high user value, earns its place in Recording. |
| 13 | **Custom Formatting Commands** | **KEEP** | Ships with good defaults already; the editor is the substance of the Dictation tab. Leave visible there. |
| 14 | Name, detection, auto-watch, mic, language, save location, hotkeys, dictation toggles | **KEEP** | Core. Regrouped by flow below. |

**Result:** ~17 settings visible by default; ~6 gated for fine-tuning; permissions + model health moved to status surfaces; speakers + retention moved to a Library window; 1 cut outright.

---

## New structure (by flow)

### Tab 1 — General *(app-level, set once)*
**Profile**
1. Your Name *(speaker label + note author)*

**Startup**
2. Launch at Login
3. Show Dock Icon

**Status** *(read-only, not settings)*
4. Permissions strip — Microphone / Audio Capture / Screen Recording / Accessibility, each showing granted-state with a "Fix in System Settings…" link when not. No grant flow lives here; onboarding owns that.

---

### Tab 2 — Recording *(the capture + engine flow — the heart of the app)*
**Detect meetings from**
1. Microsoft Teams
2. Zoom
3. Webex
4. Auto-Watch & Record *(the master switch; mirrors the dropdown's Watching/Paused)*

**Audio & Language** *(shared by meetings and dictation)*
5. Microphone — input device
6. Language — speech model (rename the misleading "Supported Languages"); note: *applies to dictation too*
7. Custom Vocabulary

**Output**
8. Save Location
9. Meeting Note Hotkey

---

### Tab 3 — Dictation *(the feature)*
1. Enable Dictation
2. Show Dictation Indicator *(disabled when off)*
3. Push to Talk *(disabled when off)*
4. Dictation Hotkey *(disabled when off)*
5. Custom Formatting Commands

---

### Tab 4 — About
Version • update check / link • on-device badges. Unchanged.

---

### Advanced *(GATED — appears only when "Show Advanced Settings" in General is on)*
1. Manage Models — status + re-download + Unload All
2. Model Keep-Alive
3. Low Memory Mode override
4. Diarization sensitivity + Reset
5. Filename Format picker
6. Developer Mode

---

### Library *(separate window — NOT Settings)*
Opened from the menu-bar dropdown ("Speakers…" / "Library").
1. Speaker search, table, merge, rename, delete, voice playback *(all current Speakers UI)*
2. **Archive speakers after** — retention dropdown, lives with the data it governs

> Rationale: Settings is for preferences; a list of people with playable voice clips is a data view. Conflating them is what forced the awkward "Speakers has no settings" tab in the first place.

---

## The gate, refined

v1's mistake was one undifferentiated drawer. v2 separates two things v1 conflated:

- **Status** (model health, permissions) — *never gated.* If the app can't transcribe, that's not "advanced," it's a problem the user must see. Surfaced in the dropdown via banners + a General status strip.
- **Advanced** (tuning, dev) — gated behind a visible **"Show Advanced Settings"** toggle in General. Discoverable, reversible, and safe to hide because nothing here is required for the app to work.

This keeps the "decide, don't gate" discipline where it's cheap (theme cut, RAM auto-detected, filename defaulted) while still letting you **keep and fine-tune** the genuine expert knobs behind the gate — which is what you asked for during this tuning phase.

---

## Migration map

| Setting | From | To |
|---|---|---|
| Your Name | General | General |
| Launch at Login / Show Dock Icon | General | General |
| Permissions ×4 | General (grant flow) | General (**status strip**) + onboarding/banners |
| Theme | General | **Cut** |
| Teams / Zoom / Webex / Auto-Watch | General | **Recording** |
| Input Device | General | **Recording** (Audio & Language) |
| Language / Model | General ("Language") | **Recording** (renamed) |
| Custom Vocabulary | Transcription | **Recording** |
| Save Location | General | **Recording** |
| Meeting Note Hotkey | Transcription | **Recording** |
| Filename Format | General | **Advanced** (picker) / default otherwise |
| Dictation (all) | Dictation | Dictation |
| Speaker table + management | Speakers tab | **Library window** |
| Speaker Archive retention | Advanced | **Library window** |
| Models on Disk / download | Advanced | **Status** (banner + General strip) + gated Manage Models |
| Model Keep-Alive | Advanced | Advanced (gated) |
| Diarization sensitivity | Advanced | Advanced (gated) |
| Low Memory Mode | Advanced | **Auto-detected** + gated override |
| Developer Mode | Advanced | Advanced (gated) |
| About | About | About |
| — | — | **New:** Show Advanced Settings toggle (General) |

---

## The few genuine open calls

These are real product decisions, not me dodging:

1. **Filename Format — default-and-gate, or keep the picker visible?** I recommend default-and-gate, but if your users are filing-system-minded it could earn a visible spot in Recording's Output section.
2. **Low Memory Mode — auto-detect threshold.** ≤8 GB is my recommended trigger; confirm against your actual peak-RAM numbers.
3. **Library — new window vs. a section in the existing transcripts view.** If a transcripts/history window is on the roadmap, Speakers should live there rather than spawning a second window.

Everything else above is a committed recommendation.
