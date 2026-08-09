# Accessibility contrast audit — glucose band colors (P16 F4 / N12)

**Status (updated 2026-08-09): Option 1 IMPLEMENTED — non-color band channel added; colors unchanged.**
Per the owner decision (2026-08-09, item 12: "add a glyph/text redundancy channel; keep the clinical band
colors"), the recommended **Option 1** below is now built on the primary surface. The §13-locked band
color tokens (`AppTheme`, `MacTheme`, `WatchApp`, the widgets) are **unchanged** — no recolor (Option 2)
was done, so the light-mode 1.4.3 contrast ratios below still stand as measured; the channel addresses the
color-*only* dependency (1.4.1).

**What shipped (A5).** `GlucoseRange` (faBolusCore) now exposes a pure, color-independent
`shortLabel` ("Low" / "In range" / "High" / "Very high") + `symbolName` (down/check/up-circle,
warning-triangle) — pinned by `GlucoseThresholdsTests.everyBandHasADistinctNonColorLabelAndSymbol`. The
iOS status ring (`StatusRingView` — the primary band-colored surface, shared by the phone HUD and the
remote-control view) renders that icon+word under the reading whenever the number is shown in its band
COLOR (a fresh reading; a stale reading is grey, with no band color to duplicate), and the VoiceOver label
speaks the band word in the same case. So the band no longer depends on color alone there.

**Not yet covered (recorded, lower priority).** The system-color surfaces — `MacTheme.glucoseColor`,
`watchGlucoseColor`, and the widgets' `WidgetUI.glucoseColor` — still convey the band by color alone. They
use Apple **system** colors (generally tuned for contrast) and live in space-constrained glanceable
layouts, so a channel there is a follow-up (and, for the widgets, a shared-target concern since they can't
link faBolusCore). Tracked as a residual F4 item.

This accompanies the N12 accessibility work (VoiceOver labels + Dynamic Type). It answers one WCAG
question the VoiceOver/Dynamic-Type work does not: **does the color used to convey a glucose band have
enough contrast, and is color the *only* channel carrying that meaning?**

## What was measured

The app colors the glucose *number* by band (low / in-range / high / urgent-high). The primary surface
is the iOS dashboard ring (`StatusRingView`), where a large number is drawn in the band color directly
on the system background. Only the iOS `AppTheme` bands are explicit sRGB values that can be pinned:

| token | role | sRGB (R, G, B) | approx hex |
|---|---|---|---|
| `AppTheme.inRange` | in range (70–180) | 0.30, 0.78, 0.36 | `#4DC75C` |
| `AppTheme.high` | high (181–250) | 0.98, 0.76, 0.18 | `#FAC22E` |
| `AppTheme.urgentHigh` | urgent high (> 250) | 0.95, 0.55, 0.15 | `#F28C26` |
| `AppTheme.low` | low (< 70) | 0.90, 0.25, 0.22 | `#E64038` |

The other surfaces — `MacTheme.glucoseColor`, `watchGlucoseColor` (`WatchApp`), and the widgets'
`WidgetUI.glucoseColor` — use **system** colors (`.red` / `.green` / `.yellow` / `.orange`). System
colors are resolved per appearance/vibrancy/increase-contrast at render time and are **not pinnable** the
same way, so they are not tabulated with fixed ratios here. (Apple's system colors are generally tuned to
meet contrast on their matching system backgrounds; they are noted as a separate, non-audited surface.)

## Method

WCAG 2.1 §1.4.3 relative luminance and the `(L1 + 0.05) / (L2 + 0.05)` contrast ratio, computed against
the system background: pure **white (#FFFFFF)** in light mode and pure **black (#000000)** in dark mode.
The math lives in `faBolusCore/WCAGContrast.swift`; the ratios below are pinned by
`WCAGContrastTests` (faBolusCore) and re-derived from the **live** `AppTheme` colors by
`AppThemeContrastAuditTests` (app target), so this table cannot silently drift.

Thresholds: **3:1** for large text (the ring number is large — ≥ 18 pt bold) and non-text UI (1.4.11);
**4.5:1** for normal-size text (the smaller band-colored labels/pills).

## Findings — 1.4.3 contrast

| band | vs white (light) | 3:1 large | 4.5:1 normal | vs black (dark) | 3:1 large | 4.5:1 normal |
|---|---|---|---|---|---|---|
| in-range (green) | **2.18** | ❌ FAIL | ❌ FAIL | 9.63 | ✅ | ✅ |
| high (yellow) | **1.64** | ❌ FAIL | ❌ FAIL | 12.80 | ✅ | ✅ |
| urgent-high (orange) | **2.45** | ❌ FAIL | ❌ FAIL | 8.58 | ✅ | ✅ |
| low (red) | **4.09** | ✅ PASS | ❌ FAIL | 5.13 | ✅ | ✅ |

**Summary.**
- **Light mode is the problem.** Three of four bands (green, yellow, orange) fall below even the lenient
  3:1 large-text floor for the colored number on white; yellow (1.64) is the worst. Red passes 3:1 large
  but not 4.5:1, so any *normal-size* red band text (e.g. the stale-IOB row, over-max label) also fails.
- **Dark mode passes** for all four bands at both thresholds.
- The band color on the smaller pill icons is a graphical/non-text indicator (1.4.11, 3:1): in light mode
  green (2.18) and yellow (1.64) fall short there too. (The pill *value* text is drawn in the primary
  label color, not the band color, so it is unaffected.)

## Finding — 1.4.1 use of color

**Band membership is conveyed by color alone on every surface.** A low-vision or color-blind user, or
anyone in bright light where the light-mode contrast above fails, cannot reliably tell in-range from high
from low from the number's color. Staleness has a redundant text cue (the age label, and — added by this
N12 work — the spoken word "stale"), but the **band itself does not**: there is no shape, glyph, or text
label that names the band next to the value. This is a 1.4.1 gap independent of the 1.4.3 ratios above.

## Recommendations (owner/designer decision — NOT taken here)

These are options, not changes. Each is a design decision with §13 (locked band tokens) implications.

1. **Add a non-color band channel (addresses 1.4.1, preferred).** A small band glyph or a short text tag
   next to the number (e.g. ▲ high / ● in-range / ▼ low, or "HIGH"/"LOW"). This keeps the current colors
   and removes the color-only dependency for everyone — including the light-mode-contrast failures — and
   would be the lowest-risk fix because it doesn't touch the §13-locked tokens.
2. **Darken the light-mode band colors (addresses 1.4.3).** Green/yellow/orange need to drop to roughly a
   luminance that clears 3:1 on white (and 4.5:1 if the color is ever used for normal-size text). This is
   a recolor of §13-locked tokens and would need the audit + `WCAGContrastTests`/`AppThemeContrastAuditTests`
   updated in lockstep. It does **not** fix 1.4.1 on its own.
3. **Use a band-tinted background chip instead of coloring the number.** A filled chip behind a
   primary-color number can hit contrast more easily and reads as a band indicator, partly addressing both
   findings — but it's a larger visual redesign.

Options 1 and 2 are complementary; 1 alone satisfies 1.4.1 and mitigates the practical impact of the
1.4.3 light-mode failures without a recolor.

## Scope / caveats

- Light/dark backgrounds are modeled as pure white/black. Real surfaces sometimes sit on material or a
  faint fill; the ring number is effectively on the base system background, so the pure-white/black model
  is the honest worst/best case for it.
- System-color surfaces (`MacTheme`, watch, widgets) are not pinned — they resolve at render time. If a
  designer wants them audited too, they'd need to be converted to explicit values first (itself a §13
  decision).
- This audit covers the glucose **band** tokens only, per the F4 mandate. Other palette entries
  (`insulin`, `carbs`, connection ring) are out of scope.
