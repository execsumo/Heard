# Heard Settings Inventory

A complete audit of every setting exposed in the app, in the order they currently appear. Intended as a working document for a reorganization pass.

---

## Tab 1: General

### Profile
1. **Your Name** — text field; used as speaker label in transcripts

### Appearance
2. **Theme** — picker: System / Light / Dark

### Behavior
3. **Launch at Login** — toggle
4. **Auto-Watch & Record Meetings** — toggle
5. **Show Dock Icon** — toggle

### Meeting Detection
6. **Microsoft Teams** — toggle (enables detection)
7. **Zoom** — toggle
8. **Webex** — toggle

### Language
9. **Supported Languages** — picker: English (Optimized) / European Languages (Beta)
   *(labeled "Language" section but controls which transcription model is loaded)*

### Microphone
10. **Input Device** — picker: System Default (current device name) + list of connected input devices + last-used unavailable device if applicable

### Output
11. **Save Location** — displays current path; Choose… button (folder picker) + Open button
12. **Filename Format** — picker:
    1. YYYY-MM-DD_MeetingName
    2. YYYY-MM-DD_HH-mm_MeetingName
    3. MM-DD_HH-mm_MeetingName
    4. MeetingName_YYYY-MM-DD
    5. MeetingName

### Permissions
13. **Microphone** — status pill (Granted / Not Granted); Grant… button when not granted *(marked Required)*
14. **Audio Capture** — status pill; Grant… button when not granted
15. **Screen Recording** — status pill; Grant… button → opens System Settings *(marked Required)*
16. **Accessibility** — status pill; Grant… button → opens System Settings *(needed for dictation text injection)*

---

## Tab 2: Transcription

### Custom Vocabulary
1. **Add term** — text field + Add button (min 2 chars to enable)
2. **Vocabulary list** — chip display of all terms, each with an × delete button
3. **Count** — read-only label: "N / 50 entries"

### Meeting Notes
4. **Meeting Note Hotkey** — displays current combo; Set Hotkey button (opens recorder sheet)
   *(hotkey is only active while a meeting is recording)*

---

## Tab 3: Dictation

### Dictation
1. **Enable Dictation** — toggle; subtitle: "Press the hotkey to start/stop dictating into any text field"
2. **Show Dictation Indicator** — toggle; subtitle: "A floating pill appears on screen when dictation is active"; disabled when dictation is off

### Hotkey
3. **Push to Talk** — toggle; subtitle: "Hold the hotkey to dictate, release to stop"; disabled when dictation is off
4. **Dictation Hotkey** — displays current combo; Set Hotkey button (opens recorder sheet); disabled when dictation is off

### Custom Formatting Commands
5. **Command list** — each row: Spoken phrase → written output, × delete button; "No custom formatting commands" placeholder when empty
6. **Add command** — two text fields (Spoken / Written) + Add button; `\n` in Written field is converted to a real newline

---

## Tab 4: Speakers

*(This tab is a management view, not a settings panel — there are no persisted preferences here.)*

1. **Search** — filter field for the speaker table
2. **Merge Selected** — button; enabled only when exactly 2 rows are selected
3. **Speaker table** — columns: Voice (playable clip), Name (inline editable), Meetings, Time in Meetings, Last Seen; sortable by any column
4. **Context menu** — per-row: Delete Speaker (destructive) for single selection

---

## Tab 5: Advanced

### Models on Disk
*(Informational + action rows, one per model)*
1. **Parakeet TDT (transcription)** — status (Ready / Not Downloaded / Downloading); Download button when not present
2. **Silero VAD v6** — status; Download button
3. **LS-EEND + WeSpeaker (diarization)** — status; Download button
4. **Parakeet CTC 110M** — status; Download button
5. **Download Missing** button — in hero card header; only shown when any model is absent
6. **Unload All** button — in hero card header; disabled while processing or dictating

### Model Keep-Alive
7. **Keep models loaded for** — number field (minutes); 0 = unload immediately; hint text notes ~800 MB RAM cost

### Diarization
8. **Speaker separation** — slider from 0.40 (Fewer speakers) to 0.85 (More speakers), step 0.05; current value displayed numerically
9. **Reset to Default** — button; resets slider to 0.65

### Memory
10. **Low Memory Mode** — toggle; subtitle explains sequential vs. concurrent preprocessing (~400 MB vs. ~800 MB peak RAM); recommended note for 8 GB machines

### Speaker Archive
11. **Archive speakers after** — picker:
    1. Never
    2. 30 days
    3. 60 days
    4. 90 days *(default)*
    5. 180 days
    6. 1 year

### Debugging
12. **Developer Mode** — toggle; subtitle: "Shows simulate meeting buttons for testing"

---

## Tab 6: About

*(Informational only — no persisted settings)*

1. **Version** — displayed as monospaced string
2. **Update available** — link to release URL when a newer version is detected; shown in place of the check button
3. **Check for updates** — button; shows spinner while checking; hidden when update is available

---

## Summary counts

| Tab | Editable settings | Informational/action-only |
|---|---|---|
| General | 16 | 0 |
| Transcription | 4 | 0 |
| Dictation | 6 | 0 |
| Speakers | 0 | 4 (management UI) |
| Advanced | 12 | 6 (model status rows + buttons) |
| About | 0 | 3 |
| **Total** | **38** | **13** |
