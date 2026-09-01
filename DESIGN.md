---
name: High-Performance Terminal
colors:
  surface: '#131316'
  surface-dim: '#131316'
  surface-bright: '#39393c'
  surface-container-lowest: '#0e0e11'
  surface-container-low: '#1b1b1f'
  surface-container: '#201f23'
  surface-container-high: '#2a292d'
  surface-container-highest: '#353438'
  on-surface: '#e5e1e6'
  on-surface-variant: '#d7c3b4'
  inverse-surface: '#e5e1e6'
  inverse-on-surface: '#303034'
  outline: '#9f8d80'
  outline-variant: '#524439'
  surface-tint: '#ffb876'
  primary: '#ffd9ba'
  on-primary: '#4b2800'
  primary-container: '#ffb46e'
  on-primary-container: '#794403'
  inverse-primary: '#895113'
  secondary: '#cfc5b7'
  on-secondary: '#353026'
  secondary-container: '#4e483d'
  on-secondary-container: '#c0b7a9'
  tertiary: '#aaeaff'
  on-tertiary: '#003642'
  tertiary-container: '#7ad0ea'
  on-tertiary-container: '#00596b'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#ffdcc0'
  primary-fixed-dim: '#ffb876'
  on-primary-fixed: '#2d1600'
  on-primary-fixed-variant: '#6b3b00'
  secondary-fixed: '#ebe1d2'
  secondary-fixed-dim: '#cfc5b7'
  on-secondary-fixed: '#201b12'
  on-secondary-fixed-variant: '#4c463b'
  tertiary-fixed: '#b1ecff'
  tertiary-fixed-dim: '#7cd2ec'
  on-tertiary-fixed: '#001f27'
  on-tertiary-fixed-variant: '#004e5e'
  background: '#08080B'
  on-background: '#e5e1e6'
  surface-variant: '#353438'
  surface-elevated: '#121217'
  border-subtle: '#1C1C22'
  terminal-green: '#A6E22E'
  terminal-blue: '#66D9EF'
typography:
  headline-xl:
    fontFamily: JetBrains Mono
    fontSize: 48px
    fontWeight: '700'
    lineHeight: '1.1'
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: JetBrains Mono
    fontSize: 32px
    fontWeight: '600'
    lineHeight: '1.2'
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: JetBrains Mono
    fontSize: 24px
    fontWeight: '600'
    lineHeight: '1.2'
  body-md:
    fontFamily: JetBrains Mono
    fontSize: 16px
    fontWeight: '400'
    lineHeight: '1.6'
  body-sm:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: '400'
    lineHeight: '1.5'
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '500'
    lineHeight: '1.0'
    letterSpacing: 0.05em
  code-block:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: '400'
    lineHeight: '1.7'
spacing:
  unit: 4px
  gutter: 24px
  margin-safe: 32px
  container-max: 1200px
---

## Brand & Style

The design system is built for performance, precision, and technical rigor. It targets a developer-centric audience that values low-latency tools and high information density. The aesthetic is "Modern Terminal Brutalism"—a fusion of classic command-line interfaces with contemporary high-contrast web design.

The style is characterized by:
- **High-Contrast Minimalist:** Deep, ink-black backgrounds paired with warm, legible text and sharp accent highlights.
- **Developer-Centric Utilitarianism:** Every element serves a functional purpose; decorative fluff is replaced by structural borders and monospaced precision.
- **Technical Sophistication:** The interface feels like a sophisticated piece of hardware, emphasizing stability and speed.

## Colors

The palette is anchored in a deep, near-black neutral (`#08080B`) to provide maximum contrast for technical text. **This is the literal value of the `background` token above — not a rounded description of it.** Two independent implementations of this spec (Heard, Seen) previously diverged because an implementer could read `background: '#131316'` in the token block and `#08080B` in this prose and pick either; the token block is now `#08080B` and this paragraph is the same number restated, not a separate design decision.

- **Primary:** A warm, high-visibility amber (`#FFB46E`) used for primary actions, critical status indicators, and branding.
- **Secondary:** A soft, high-legibility parchment (`#E2D8C9`) used for primary body text and significant labels to reduce eye strain compared to pure white.
- **Accents:** Neon-inspired greens and blues are reserved for syntax highlighting, terminal outputs, and success/info states, maintaining the "IDE" aesthetic.
- **Surface Strategy:** Use slight tonal shifts for depth. Backgrounds remain flat, while containers use a slightly lighter grey (`#121217`) with sharp borders.
- **Status colors are reserved for status.** `error-container` (`#93000A`) and its family exist to flag something that needs attention or intervention — a failed job, a destructive action, an active recording. Never reach for it to add visual weight to a neutral or positive state (e.g. "N of N ready", "all clear"): those get the same flat elevated surface as any other card. A red card the user has to double-take on is a bug, not an accent choice.

### Elevation ladder

Five tonal steps, each one token step lighter than the last. Implement exactly these five — do not invent an intermediate value, and do not collapse two adjacent steps into the same hex to "simplify":

| Step | Token | Hex | Use |
|---|---|---|---|
| Ground | `background` | `#08080B` | Window/app background. The base every card must visibly lift off of. |
| Sunken | `surface-container-lowest` | `#0E0E11` | Recessed wells — code blocks, sunken text fields. |
| Elevated | `surface-elevated` | `#121217` | Cards, panels, sidebars — the default "raised" container. |
| Raised | `surface-container-low` | `#1B1B1F` | Hover state on an elevated container; one step up from Elevated. |
| High | `surface-container` | `#201F23` | Pressed state, active wells — one step up from Raised. |

The gap between Ground and Elevated (`#08080B` → `#121217`) is the one that must stay large: it's what makes a card read as "lifted" at all. Nudging `background` toward `surface-elevated` to "soften" the app — even by a token step or two — collapses that read and every card on top of it looks flat again, regardless of how correct the border and type treatment are.

## Typography

The typography system relies exclusively on **JetBrains Mono**. This reinforces the terminal identity and ensures that alignment, indentation, and technical data are rendered with mathematical precision.

- **Headlines:** Use tight tracking and heavy weights. They should feel impactful and structural.
- **Body:** Generous line heights are used for long-form technical documentation to maintain readability against the dark background.
- **Labels:** Small caps or all-caps styling should be used for secondary navigation and metadata to distinguish them from executable content.
- **`lineHeight` is not documentation-only.** Every type role above ships a `lineHeight`; the implementation must apply it as real leading (SwiftUI `.lineSpacing()`, CSS `line-height`, etc.) on every use of that role, not just record the number in a token table. A screen with technically-correct fonts and zero leading reads as cramped and busy even though every font size and weight matches the spec exactly — this was the single largest gap between two implementations that used identical hex values and font sizes.
- **Every settings/preferences-style screen gets a real page title.** Use `headline-lg-mobile` (or the platform's nearest step) as an actual heading at the top of the pane — not only the small all-caps `label-md` section headers within it. A screen built entirely out of `label-md` section headers with no larger heading above them has no typographic hierarchy, even if every individual label is spec-correct.

## Layout & Spacing

This design system utilizes a **Fixed Grid** approach for desktop to mirror the structured environment of a terminal window, while transitioning to a fluid layout for mobile.

- **Grid:** A 12-column grid with 24px gutters. Elements should snap to grid lines to maintain a "blocky," engineered feel.
- **Spacing Rhythm:** Based on a 4px baseline. Use 8px, 16px, 24px, 32px, 48px, and 64px increments for all padding and margins. This is a closed set, not a suggestion — a convenient off-scale value (`12px`, `18px`, `7px`) is still a violation even if it "looks fine," because it's exactly the kind of small, undocumented drift that makes two implementations of this spec stop matching each other pixel-for-pixel.
- **Density:** High information density is encouraged. Group related technical data closely, using structural borders rather than whitespace to define sections.

## Elevation & Depth

In keeping with the terminal aesthetic, this system avoids traditional shadows. Depth is conveyed through **Tonal Layers** and **Bold Borders**.

- **Layers:** Use `#121217` for cards or elevated sections. This subtle lift creates hierarchy without breaking the flat, technical feel.
- **Borders:** Use 1px solid borders (`#1C1C22`) for all containers. For active or focused states, the border should switch to the Primary Amber or Terminal Green.
- **Backdrop:** For modals or overlays, use a heavy background dim (80% opacity black) to maintain focus on the technical task at hand.

## Shapes

The shape language is strictly **Sharp (0px)**. 

Every UI element—buttons, input fields, cards, and tags—must have square corners. This reinforces the brutalist, "unrefined" hardware aesthetic. The only exception is for circular icon buttons if strictly necessary for platform conventions, though square enclosures are preferred.

**All fills are flat, single-color.** No gradients anywhere — not on brand marks, not on icon backgrounds, not as a "subtle" depth cue on a card. Depth comes exclusively from the elevation ladder and 1px borders above. A gradient on the app's own logo glyph is still a gradient.

**Exception — OS-rendered window chrome.** A native platform surface the app doesn't draw itself (e.g. a macOS menu-bar-extra dropdown panel, a browser's own popover chrome) gets its corner radius from the OS, not from app code, and that radius is normally out of reach: neither reducing it via public APIs nor mutating the private AppKit view hierarchy that appears to own it (confirmed by direct experiment — setting `cornerRadius` on the window's content view and its superview took effect on the layer but produced no visible change) will move it. Where the platform genuinely does render this chrome smaller by default (observed: a native dropdown panel at roughly **5px** radius vs. a near-identical one rendering closer to **14px** under the same OS and API, cause not identified), treat the smaller value as the target for that surface and don't spend further effort chasing the difference through private-API means — it isn't a lever either implementation actually controls.

## Components

- **Buttons:** Large, sharp rectangles. Primary buttons use a solid Amber background with black text. Secondary buttons use a 1px Secondary-colored border with no fill. Hover states should "invert" the colors or increase border thickness.
- **Input Fields:** Styled like a command line. A 1px border on the bottom or all sides, using a blinking block cursor `_` metaphor for focus states.
- **Chips/Tags:** Small, sharp-edged boxes with monochromatic fills or subtle borders. Used for categorizing languages (e.g., "Rust", "C++") or status.
- **Code Blocks:** Encapsulated in a slightly lighter background (`#121217`) with a specific syntax highlighting theme that utilizes the named terminal colors.
- **Lists:** Use monospaced bullet points (e.g., `> ` or `- `) instead of standard circular bullets to maintain the CLI persona.
- **Navigation & selection state:** A selected item in a sidebar, tab list, or menu gets a **2px solid leading (left-edge) rule in Primary Amber, plus a one-step-lighter tonal fill** from the elevation ladder (e.g. Elevated → Raised) behind the whole row. It does **not** get a full 1px border boxed around the row — a box around a selected nav item reads as a focus ring or a rendering glitch, not a selection state, and was a real regression in one implementation of this spec.
- **No unstyled native controls.** Segmented pickers, toggles, dropdowns, sliders — every interactive control the user touches is a custom flat/sharp component built from this system's own tokens. Falling back to a platform's default control (e.g. a native macOS segmented `Picker`, an unstyled `<select>`) is not a shortcut, it's a visible seam: the platform's own rounded chrome and system accent color will not match Primary Amber or the 0px shape language, and it becomes the single most visually jarring element on the screen precisely because everything around it is correct.
- **Cards:** Minimalist containers defined by 1px borders. Titles should be separated from content by a 1px horizontal rule.