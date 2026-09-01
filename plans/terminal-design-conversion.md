# Plan: Convert Heard's UI to the DESIGN.md terminal design system

## Goal

Replace the current "Paper" design language (warm cream, rounded corners, SF Pro,
soft shadows) with the **Modern Terminal Brutalism** system defined in `DESIGN.md`:
ink-black surfaces, warm amber primary, JetBrains Mono everywhere, 0px corner radius,
borders instead of shadows, high information density.

## Decisions (confirmed with the user)

1. **Light mode is kept.** `DESIGN.md` ships a dark-only palette. A light "paper
   terminal" counterpart is derived here (light values are a judgment call, not spec)
   so the existing `AppAppearance` preference (System/Light/Dark) keeps working.
   An Appearance picker is added to Settings → General, which previously had no UI
   control even though `settings.appearance` existed and was applied in `MTApp.swift`.
2. **JetBrains Mono is bundled.** OFL TTFs (Regular/Medium/SemiBold/Bold, ~1.05 MB)
   live in `Resources/Fonts/`, registered via `ATSApplicationFontsPath` in `Info.plist`
   and copied by `scripts/bundle.sh`. `HeardFont` falls back to the system monospaced
   face when the family is unavailable (e.g. under `swift run`, which has no bundle).
3. **All surfaces convert in one pass.** A partial conversion leaves the app looking
   half-broken.

## Strategy

The token surface is small and heavily reused — 200+ call sites resolve to ~25 token
names. So the conversion is:

- **Repoint the tokens, keep the names.** `HeardTheme.Paper.*` is renamed to
  `HeardTheme.Terminal.*` (one mechanical sed) and every member keeps its existing
  name with a new value. `HeardTheme.Radius.*` keeps its members but all resolve to
  `0`. This means most files need *no* color edits at all.
- **Freeze the shared layer first.** `DesignSystem.swift` (tokens, `HeardFont`,
  `SettingsCard`, `CardRow`, `ToggleRow`, `StatusPill`, `SectionLabel`, `StatusDot`,
  `HeardToggleStyle`, `HeardMark`, plus new `TerminalButtonStyle` /
  `TerminalTextFieldStyle` / `CardHeader`) is written by hand before any delegation,
  so parallel agents all target a fixed API.
- **Fan out per surface.** Each agent owns a disjoint set of view files and applies
  the same checklist against the frozen API.

## Palette

Dark values are taken verbatim from `DESIGN.md`. Light values are derived.

| Token          | Light     | Dark      | Source                          |
|----------------|-----------|-----------|---------------------------------|
| `bg`           | `#F4F3F0` | `#131316` | surface / background            |
| `surface`      | `#FFFFFF` | `#1B1B1F` | surface-container-low           |
| `surfaceAlt`   | `#EAE8E3` | `#201F23` | surface-container               |
| `surfaceHigh`  | `#DFDCD6` | `#2A292D` | surface-container-high          |
| `sidebar`      | `#EDEBE7` | `#0E0E11` | surface-container-lowest        |
| `border`       | `#CFCBC4` | `#2A292D` | container border                |
| `borderSoft`   | `#E3E0DA` | `#1C1C22` | border-subtle                   |
| `ink`          | `#131316` | `#E5E1E6` | on-surface                      |
| `ink2`         | `#3A3A3F` | `#D7C3B4` | on-surface-variant              |
| `mute`         | `#6E6A63` | `#9F8D80` | outline                         |
| `muteSoft`     | `#C4C0B8` | `#524439` | outline-variant                 |
| `accent`       | `#8A4B00` | `#FFB46E` | primary-container / on-p-c      |
| `accentInk`    | `#4B2800` | `#FFD9BA` | on-primary / primary            |
| `accentSoft`   | `#FFEBD6` | `#3A2A16` | derived container tint          |
| `good`         | `#4F7A0F` | `#A6E22E` | terminal-green                  |
| `goodSoft`     | `#EDF4DA` | `#25300F` | derived                         |
| `warn`         | `#8A5A00` | `#FFB876` | primary-fixed-dim               |
| `warnSoft`     | `#FBEBD6` | `#3A2A16` | derived                         |
| `bad`          | `#93000A` | `#FFB4AB` | error-container / error         |
| `badSoft`      | `#FFDAD6` | `#4A1417` | on-error-container / derived    |
| `info`         | `#00596B` | `#66D9EF` | terminal-blue / on-tertiary-c   |
| `infoSoft`     | `#DCF3FA` | `#0E2A32` | derived                         |
| `recordingBg`  | `#131316` | `#93000A` | error-container                 |
| `recordingInk` | `#F4F3F0` | `#FFDAD6` | on-error-container              |
| `terminalGreen`| `#4F7A0F` | `#A6E22E` | terminal-green                  |
| `terminalBlue` | `#00596B` | `#66D9EF` | terminal-blue                   |

## Type scale

`DESIGN.md`'s sizes are web-scaled (48/32/16/14/12). They are mapped down to the
app's existing macOS scale so layouts don't blow up, keeping the same hierarchy and
switching the family to JetBrains Mono throughout.

| Role         | Size   | Weight   | Notes                        |
|--------------|--------|----------|------------------------------|
| `headlineXL` | 26     | bold     | About sheet app name         |
| `headlineLG` | 19     | semibold | pane H1                      |
| `title`      | 13     | semibold | window title, card titles    |
| `body`       | 12     | regular  | row labels                   |
| `bodyMedium` | 12     | medium   | emphasised row labels        |
| `caption`    | 11     | regular  | subtitles                    |
| `label`      | 10.5   | bold     | UPPERCASE, kerning 0.6       |
| `mono`       | 11     | regular  | tabular values, paths, sizes |
| `pill`       | 10     | semibold | status pills                 |

## Shape, depth, spacing

- **Radius: 0 everywhere.** `Radius.inline/card/hero` all become `0`. `Capsule()` in
  `HeardToggleStyle` and `StatusPill` becomes `Rectangle()`.
- **No shadows.** `SettingsCard`'s shadow is dropped; depth comes from a 1px
  `border` stroke over a `surface` fill. The window/panel drop shadow stays (it is
  an OS-level affordance, not a card treatment).
- **Borders are 1px, not 0.5px** — the spec calls for structural, visible borders.
- **Spacing** stays on the 4px baseline and moves to the spec's increments:
  `xs 4, sm 8, md 12, lg 24, xl 32` (was `4/8/12/20/28`).
- **Modal backdrop** goes to 80% black (was `rgba(28,32,36,0.32)`).

## Work breakdown

### Phase 0 — done before delegation (by hand)

- `Resources/Fonts/` — JetBrains Mono TTFs + `OFL.txt`. *(done)*
- `Sources/HeardCore/DesignSystem.swift` — rewritten token layer, `HeardFont`,
  restyled shared components, new button/text-field styles.
- Global `HeardTheme.Paper.` → `HeardTheme.Terminal.` rename.
- `Info.plist` — `ATSApplicationFontsPath`.
- `scripts/bundle.sh` — copy `Resources/Fonts` into `Contents/Resources/Fonts`.

### Phase 1 — delegated in parallel (disjoint files, frozen shared API)

| Agent | Files |
|-------|-------|
| A | `MenuBarView.swift` — dropdown, 5 states, status header, job rows, timer, pulse |
| B | `SettingsView.swift`, `SettingsComponents.swift` — window chrome, sidebar nav, permission/model/mic rows, hotkey recorder, about badge |
| C | `SettingsTabs.swift` — General / Dictation / Models / Speakers panes, plus the new Appearance picker |
| D | `SpeakerNamingView.swift`, `TranscriptLibraryView.swift`, `DictationHUD.swift`, `MeetingNoteComposer.swift` |

Shared checklist for every agent:

1. Every `.font(.system(...))` → the matching `HeardFont` role.
2. Every `RoundedRectangle(cornerRadius:)` / `Capsule()` used as a *container* →
   `Rectangle()`; strokes go to 1px.
3. Every `.shadow(...)` on a card/row/button → removed, replaced by a 1px border.
4. Ad-hoc `Color(hex:)` / `Color.blue` etc. → `HeardTheme.Terminal.*`.
5. Buttons → `TerminalButtonStyle(.primary/.secondary/.ghost/.danger)`.
6. List bullets → `> ` / `- ` mono prefixes where lists are rendered.
7. No public signature changes; no behavioural changes.

### Phase 2 — integration (by hand)

- Review every diff for API drift and token misuse.
- Update `handoff.md` and `CLAUDE.md` (design-system section, `Resources/Fonts`).

## Verification gap — read this

**This machine is Linux.** `swift build` fails here at the first dependency
(`FluidAudio` → `mach/mach.h` not found), so nothing in this conversion can be
compile-checked or visually verified locally. The delivered work is reviewed by
reading, not by building. The user needs to run, on macOS:

```bash
swift build && swift run HeardTests
./scripts/bundle.sh && open build/Heard.app
```

Expect a round of compile-error fixes after that first build.

## Out of scope

- The app icon asset (`Resources/AppIcon.iconset`) and `MenuBarIconTemplate.svg` are
  not regenerated. Only the in-app `HeardMark` view is restyled (square, amber).
- The 4 user-selectable accent variants from the old handoff are not added; the
  terminal system has a single amber primary.
- No behavioural, layout-structure, or feature changes — this is a skin.
