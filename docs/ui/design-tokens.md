# Design tokens and Liquid Glass

Every visual decision goes through `CodexAgentTheme`. A view that hardcodes a
point size, a padding, a corner radius, or a color does not respond to the
user's theme, appearance, or interface font size.

## Liquid Glass

Glass is applied by *role*, never by hand-configured material:

```swift
content.codexGlass(
    RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
    role: .panel
)
```

| Role | Use | Variant | Interactive |
| --- | --- | --- | --- |
| `.chrome` | Sidebar, toolbar backgrounds | regular | no |
| `.panel` | Panels floating over content, popovers | regular | no |
| `.sheet` | Modal sheets | regular | no |
| `.control` | A single control | regular | yes |
| `.controlGroup` | A capsule grouping multiple controls | regular | no |
| `.chip` | Inline pills, composer chips | regular | yes |
| `.hud` | Transient surface over content, dimmed by us | clear | no |

Rules the roles enforce, and that reviews should check:

- **Never layer anything beneath glass.** It samples what is behind the *window*.
  A `.background(.regularMaterial)` under a glass surface means the glass samples
  that material and the effect is lost.
- **Never add a stroke or a shadow to a glass surface.** Glass draws its own edge
  highlight and its own shadow. Hand-drawn copies are what make glass read as an
  imitation of itself.
- **Tint means emphasis, not dimming.** Pass a tint only to carry meaning
  (selection, a status color). Tinting with a surface color to darken glass turns
  it into smoked plastic; pick a different `role` instead.
- **Interactivity belongs to controls.** `.control` and `.chip` are interactive;
  `.controlGroup` and other containers are not, or the whole group flexes when
  any child is pressed.
- **Group siblings.** Adjacent glass surfaces belong in a `CodexGlassGroup`
  (`GlassEffectContainer`) so the system can merge and morph them and render them
  in one pass. Keep its merge spacing at or below the interior layout spacing
  unless the surfaces are intentionally joined at rest.

Glass degrades to an opaque themed surface when *either* the theme opts out
(`Effects.usesLiquidGlass`, only High Contrast) or the system asks for reduced
transparency (`accessibilityReduceTransparency`). These are independent; a
half-transparent middle ground satisfies neither.

`codexGlassButtonStyle(prominent:)` maps to `.glass` / `.glassProminent`, falling
back to `.bordered` / `.borderedProminent`.

## Typography

All tokens derive from the interface font size and the user's chosen text family,
so the whole app scales with the slider.

| Token | Offset from base | Use |
| --- | --- | --- |
| `heroTitle` | +8 semibold | Empty states, onboarding. The largest token — chrome, not a landing page. |
| `routeTitle` | +5 semibold | Route and page headings |
| `sheetTitle` | +3 semibold | Sheets, overlays, popovers |
| `actionIcon` | +2 medium | Toolbar and action glyphs |
| `panelTitle` | +1 semibold | Panel and card headings |
| `chat` | +1 | Message text |
| `body` | base | Body text |
| `label` / `panelLabel` | −1 semibold | Field labels, section labels |
| `code` | −1 mono | Code, diffs, paths |
| `caption` / `chipLabel` | −2 | Secondary detail, pills |
| `micro` | −3 mono semibold | Counters, badges |

Use `.monospacedDigit()` on anything that counts: diff totals, byte counts, exit
codes, token counts, durations.

Do not use `.font(.system(size:))`, and do not use Apple's semantic fonts
(`.title2`, `.caption`): neither responds to the interface font size.

## Spacing and radii

`theme.spacing` carries a ramp — `xxs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16,
`xl` 24, `xxl` 32 — plus the role insets `rowPadding`, `panelPadding`,
`sheetPadding`, and `sectionGap`. Layout widths (`transcriptMaxWidth`,
`sidePanelWidth`, …) and icon sizes live in the same struct.

Radii come from `theme.radii`: `small` 6, `medium` 12, `large` 16, `panel` 28,
`composer` 28, `bubble` 16, `pill`.

## Themes

A theme is a **hue family**, not an appearance. Each of the eight families
(`slate`, `midnight`, `warmSand`, `sage`, `rose`, `violet`, `highContrast`, and
`slate` again as Paper) defines every color role as a `CodexColorPair` with a
light and a dark value. `CodexAppearanceMode` — system, light, dark — chooses
which side is used, independently of the family.

Color values are `0xRRGGBB`, or `0xAARRGGBB` where a role needs alpha.

Accent roles are distinct on purpose:

- `accent` — fills, selection
- `accentStrong` — pressed and active accent states
- `accentText` — the accent *as text on the page*, which a fill accent bright
  enough to sit under white glyphs usually cannot be
- `onAccent` — foreground drawn on top of an `accent` fill
- `accentSoft` — tinted backgrounds

`CodexThemePaletteTests` holds every family to WCAG AA (4.5:1) for body and
secondary text on canvas, and 3:1 for `accentText` and `onAccent`, in both
appearances. A new family must pass those before it ships.

### AppKit-backed views

`theme.colors.*` are appearance-adaptive. Converting one with `NSColor(_:)`
resolves it against the **process** appearance, not the window's, so an app
pinned to Light under a dark system draws the dark palette.

AppKit views must take a resolved palette instead:

```swift
CodexAgentTheme.Colors(spec: preset.palette, resolvedFor: colorScheme)
// or
preset.theme(resolvedFor: colorScheme)
```

This also matters for caching. A dynamic `NSColor`'s `description` is not stable
across equal values, so fingerprinting one invalidates every cache that depends
on it — in the transcript that meant reconfiguring all rows on every update.
`CodexTranscriptAppKitTheme` flattens to static sRGB for exactly this reason.

## Reviewing a change

Render the gallery:

```bash
just gallery
```

It writes `build/gallery/<scene>-<theme>-<light|dark>.png` for every family in
both appearances. Typography, spacing, color, and layout are faithful.

Liquid Glass is **not** in those images. The window server composites it from
what is behind the window, so it appears in neither `ImageRenderer`,
`NSView.cacheDisplay`, nor `CALayer.render(in:)` — an app cannot capture its own
glass. Scenes render the opaque fallback instead. Checking real glass means
running the app.
