# Heard Settings — Reorganization Proposal

Companion to [settings-inventory.md](settings-inventory.md). Goal: cut perceived complexity by grouping settings around what the user is *trying to do*, and hide expert/risky controls behind a gate so the default surface stays calm.

---

## Principles applied

1. **Progressive disclosure** — the 90% case is visible; tuning, performance, and debug knobs are gated and out of the default path.
2. **Group by task, not by implementation** — settings live where the user's mental model expects them ("how meetings are recorded"), not where the code happens to put them.
3. **Co-locate related controls** — a feature's hotkey lives with that feature; a device picker lives next to its permission.
4. **Order by frequency, end with the rare/destructive** — common toggles first, retention/reset/debug last.
5. **No junk-drawer tab** — General becomes "setup & basics," not a catch-all.

---

## Before → After at a glance

| Current | Problem | Proposed |
|---|---|---|
| **General** (8 sections, 16 settings) | Junk drawer; holds detection, output, language, mic, permissions | Split into **General** + **Meetings**; slimmed to setup basics |
| **Transcription** (vocabulary + meeting-note hotkey) | Hotkey orphaned from its feature | **Transcription** = language + vocabulary; hotkey → Meetings |
| **Dictation** | Fine | **Dictation** (unchanged) |
| **Speakers** (management only) | No settings, but retention lives elsewhere | **Speakers** gains the archive/retention setting |
| **Advanced** (model mgmt + tuning + debug, always visible) | Expert knobs shown to everyone | **Advanced** gated behind a toggle |
| **About** | Fine | **About** (unchanged) |

Net: still 6 visible tabs, but each is coherent and Advanced only appears when asked for.

---

## Proposed structure

### Tab 1 — General *(setup & basics)*

**Profile**
1. Your Name

**Appearance**
2. Theme (System / Light / Dark)

**Startup**
3. Launch at Login
4. Show Dock Icon

**Microphone**
5. Input Device *(moved up next to its permission — both are "which mic / can we use it")*

**Permissions**
6. Microphone *(Required)*
7. Audio Capture
8. Screen Recording *(Required)*
9. Accessibility *(for dictation)*

**Advanced**
10. **Show Advanced Settings** — the gate (see below)

> *Why mic lives here:* the input device and the microphone permission are the same concern; pairing them is clearer than burying the picker in a transcription tab.

---

### Tab 2 — Meetings *(how meetings get captured & saved)*

**Recording**
1. Auto-Watch & Record Meetings

**Detection** — record from these apps:
2. Microsoft Teams
3. Zoom
4. Webex

**Saving**
5. Save Location (path + Choose… + Open)
6. Filename Format

**In-Meeting Notes**
7. Meeting Note Hotkey *(moved here from Transcription — it's a meeting feature, and now both hotkeys sit with their features)*

---

### Tab 3 — Transcription *(how speech becomes text, everywhere)*

**Language**
1. Language / Model — *rename the misleading "Supported Languages" label.* English (Optimized) / European Languages (Beta). This drives both meeting and dictation transcription, which is why it's its own shared tab.

**Custom Vocabulary**
2. Add term + chip list + "N / 50" count

---

### Tab 4 — Dictation *(unchanged grouping)*

**Dictation**
1. Enable Dictation
2. Show Dictation Indicator *(disabled when off)*

**Hotkey**
3. Push to Talk *(disabled when off)*
4. Dictation Hotkey *(disabled when off)*

**Custom Formatting Commands**
5. Command list (spoken → written, deletable)
6. Add command

---

### Tab 5 — Speakers *(management + data lifecycle)*

1. Search
2. Merge Selected
3. Speaker table (Voice / Name / Meetings / Time / Last Seen)
4. Delete Speaker (context menu)
5. **Archive speakers after** — *moved here from Advanced.* This is speaker-data lifecycle, so it belongs with the speaker list, not with performance tuning. (Never / 30 / 60 / 90 / 180 / 365 days.)

---

### Tab 6 — Advanced *(GATED — hidden until enabled)*

Only appears in the sidebar when **Show Advanced Settings** (General) is on.

**Models on Disk**
1. Per-model status + Download (Parakeet TDT, Silero VAD, Diarization, Parakeet CTC)
2. Download Missing / Unload All

**Performance**
3. Model Keep-Alive (minutes)
4. Low Memory Mode

**Diarization**
5. Speaker separation sensitivity slider + Reset to Default

**Debugging**
6. Developer Mode

---

### Tab 7 — About *(unchanged)*

Version • Update check / available-update link • on-device badges.

---

## The gate

**Recommended: a "Show Advanced Settings" toggle in General.** When off (default), the Advanced tab is absent from the sidebar entirely. When on, it appears. This is discoverable, reversible, and keeps the first-run surface to five focused tabs.

Why a visible toggle over the macOS ⌥-click-to-reveal convention: Heard's audience includes non-technical meeting users, and an invisible gesture is undiscoverable for the people who *do* eventually need to re-download a model or tweak diarization. A labeled switch trades a little elegance for findability — the right call here.

### One safety caveat
Model download/unload is moving behind the gate. Don't let a user with a missing or corrupted model get stranded in the un-gated UI. Mitigations (the app already has the machinery for both):
- **Auto-download on first run** so the default path never requires the Advanced tab.
- **Surface model failures via the existing banner pattern** (you already do this for tap/mic/permission failures) with a one-click "Download" action that works regardless of the gate.

If you'd rather not rely on banners, the fallback is to keep a compact **Models status** strip in Transcription and gate only the *tuning* (keep-alive, low-memory, diarization, developer mode).

---

## Migration map (nothing is lost)

| Setting | From | To |
|---|---|---|
| Your Name | General | General |
| Theme | General | General |
| Launch at Login | General | General |
| Show Dock Icon | General | General |
| Input Device | General | General *(moved next to permissions)* |
| Permissions (×4) | General | General |
| Auto-Watch & Record | General | **Meetings** |
| Teams / Zoom / Webex detection | General | **Meetings** |
| Save Location | General | **Meetings** |
| Filename Format | General | **Meetings** |
| Language / Model | General ("Language") | **Transcription** *(renamed)* |
| Custom Vocabulary | Transcription | Transcription |
| Meeting Note Hotkey | Transcription | **Meetings** |
| Dictation (all) | Dictation | Dictation |
| Speaker Archive retention | Advanced | **Speakers** |
| Models on Disk | Advanced | Advanced *(gated)* |
| Model Keep-Alive | Advanced | Advanced *(gated)* |
| Diarization sensitivity | Advanced | Advanced *(gated)* |
| Low Memory Mode | Advanced | Advanced *(gated)* |
| Developer Mode | Advanced | Advanced *(gated)* |
| About (all) | About | About |
| — | — | **New:** Show Advanced Settings toggle (General) |

---

## Open decisions for you

1. **Gate mechanism** — recommended visible toggle vs. ⌥-click reveal vs. keep Advanced always-on but collapse expert sections. (I recommend the toggle.)
2. **Model management** — fully gated (relying on auto-download + failure banners) vs. a compact status strip left visible in Transcription. (I recommend fully gated *if* auto-download + banners are solid.)
3. **Mic placement** — General (next to permission, recommended) vs. Transcription (next to language/engine). Both defensible.
