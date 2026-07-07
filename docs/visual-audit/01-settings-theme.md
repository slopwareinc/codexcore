# CodexCore Visual Audit — Settings/Theme

Scope: `Sources/CodexCoreUI/CodexSettingsAboutRouteView.swift` and `Sources/CodexCoreUI/CodexTheme.swift`.

## Tier 1 — Theme picker (most egregious)

### 1.1 Five polished theme presets exist but Settings never shows them
`CodexTheme.swift:944` defines `CodexAgentThemePreset` with five complete themes (`Official Dark`, `Native Light`, `Midnight`, `Warm Minimal`, `High Contrast`). Exercised in `CodexAgentPanelThemeTests.swift:83` and `CodexCardRenderingTests.swift:8`. The Settings UI exposes zero of them — `CodexSettingsAboutRouteView.swift:611-613` only renders the mode picker + two raw color-editor panels. Users are forced to hand-type hex triplets to recreate themes the designers already built.

**Fix:** Add a theme preset chooser (grid or list of `CodexAgentThemePreset.allCases`) that seeds `lightTheme`/`darkTheme` from the preset, then expose the editable colors as "Customize…" beneath it.

### 1.2 Theme previews are 92pt abstract swatches, not real UI
`CodexSettingsAboutRouteView.swift:684-741` — `CodexThemeModePreview` is a 92pt rounded rectangle with two short capsules "representing text." Previews none of: chat bubbles, accent color, font, density, code blocks, sidebar translucency, spacing.

**Fix:** Replace with miniaturized real chat row (user bubble + assistant bubble + brand mark), driven by `editableTheme.agentTheme(...)` so changing accent/background updates the preview live.

### 1.3 System mode preview is hardcoded white/black, ignoring user edits
`CodexSettingsAboutRouteView.swift:726-740`:
```
case .system: return .clear
case .light: return .white.opacity(0.9)
case .dark:  return .black.opacity(0.58)
previewCard = mode == .dark ? .white.opacity(0.88) : .white.opacity(0.94)
previewLine = mode == .dark ? .black.opacity(0.20) : .black.opacity(0.12)
```
Light and Dark previews look near-identical (both white card on slightly different backdrop). User sets accent = `#FF0000` in the Light theme panel below, but the System preview stays plain white.

**Fix:** Drive `previewBackground`/`previewCard`/`previewLine` from `settings.lightTheme`/`settings.darkTheme`, not from `Color.white`/`Color.black`.

### 1.4 Selection state is 1px→2px stroke — no fill, no scale, no animation
`CodexSettingsAboutRouteView.swift:720-723`:
```
.stroke(isSelected ? theme.colors.accent : theme.colors.border,
        lineWidth: isSelected ? 2 : 1)
```
No filled highlight, no checkmark, no scale-up, no transition. Combined with abstract preview, selected tile is genuinely hard to identify.

**Fix:** Accent-tinted fill behind selected tile + checkmark corner badge + `.spring` scale ~1.04.

### 1.5 No haptics, no animations, no transitions anywhere in theme selection
`:664-666`, `:802`, `:843`, `:944` — bare mutations, no `.sensoryFeedback`, no `withAnimation`. Selecting a theme is the most "tactile" moment in settings and feels inert.

**Fix:** `.sensoryFeedback(.selection, trigger: mode)` on the picker; wrap mutations in `withAnimation(.snappy)` using `theme.animations`.

### 1.6 Two full redundant theme editor panels stacked on one screen
`:612-613` renders `CodexEditableThemePanel` for both Light and Dark themes — 10 nearly-identical rows stacked, no visual way to know which applies right now.

**Fix:** Show only the active theme editor (driven by `settings.mode`), with "Customize the other appearance…" disclosure. Or `TabView`/`Picker` to switch.

### 1.7 Only 3 colors exposed; the actual theme has 22
`CodexEditableTheme` (CodexTheme.swift:92-115) carries `accent`, `background`, `foreground` + boolean + slider. `CodexAgentTheme.Colors` (:293-367) has `codeBackground`, `codeHeader`, `codeText`, `success`, `warning`, `danger`, `running`, `tool`, `userBubble`, `userBubbleStroke`, `borderStrong`, `surfaceSunken`, `surfaceElevated`.

**Fix:** Either commit to "themes are presets, no per-channel editing" (remove the editors) or expose additional channels (bubbles, code, status) in "Advanced" disclosure.

### 1.8 Hex color rows use custom 18pt circle + raw TextField instead of `ColorPicker`
`:920-958` — `CodexHexColorRow`: 18pt Circle + `TextField("#RRGGBB")`. SwiftUI ships a native `ColorPicker` with eyedropper, opacity support, and a11y. Custom one: 18pt swatch (below 44pt hit target), no opacity, no eyedropper, invalid hex silent fallback to `#000000`, `#RRGGBB` placeholder bleeds behind 6-char value, textfield overflow.

**Fix:** Replace with `ColorPicker(selection: ..., supportsOpacity: false)` bound to `value.color`. Keep hex textfield as secondary `monospaced` detail.

### 1.9 `uiFontName` is a CSS-style string shown but not editable
`CodexTheme.swift:104` default: `"-apple-system, BlinkMacSystemFont"` — a CSS font stack, not a SwiftUI name. Rendered verbatim at `:763-769` inside a 176pt pill — width hand-fit to the CSS string. No font picker attached. Readers think someone copy-pasted CSS into SwiftUI.

**Fix:** Either remove this display or replace with a real font picker (`Picker` of system designs: System / Rounded / Serif / Monospaced via the existing `FontDesignToken`).

### 1.10 Two dead "Import"/"Copy theme" ghost pills on every panel
`:761-762` — `CodexSettingsDisabledPill("Import")` + `("Copy theme")` from `CodexSettingsDisabledPill` (:1166-1183): a 28pt-high capsule with `.help("Not available in CodexCore yet")`. No button, no action. 4 ghost UI elements littering the screen.

**Fix:** Delete them entirely until import/copy ships.

### 1.11 "Contrast" slider: range 0-100, no unit, no effect description
`:777-783` — `CodexSettingsSliderRow(title: "Contrast", detail: nil, ...)`. Renders as `Contrast [<====>] 45` with no explanation. Connects to border opacity (`CodexTheme.swift:200-201`) invisibly.

**Fix:** Add `detail: "Stronger borders and dividers"` (or rename to "Border strength"); show value as "45%".

### 1.12 No "Reset to default" anywhere
`CodexAppearanceSettings.official` (:153-155), `CodexEditableTheme.officialLight/Dark` (:177-195) exist. Settings UI has no reset control. User stuck with bad paste = retype original values by hand.

**Fix:** Reset button that resets `lightTheme`/`darkTheme`/`uiFontSize` to `.official`.

### 1.13 Three different surface treatments on one Appearance screen
- sidebar search: `surfaceElevated.opacity(0.40)` (:207)
- panels: `surfaceElevated.opacity(glassOpacity=0.72)` (:1208)
- input capsules: `surfaceSunken.opacity(0.64)` (:769, 882, 954, 1063)
- multiline body: `RoundedRectangle(radii.small)` (:1084, the only non-Capsule input)
- disabled pills: `surfaceSunken.opacity(0.34)` (:1180)

Five grades of transparent surface — muddy, washed-out hierarchy.

**Fix:** Pick two surface treatments (panel=0.92, control=0.64) and use them consistently.

### 1.14 Hardcoded corner radii in mode preview disagree with `theme.radii`
`:697, 704, 706, 721` — `cornerRadius: 10` and `8` inline. Tokens are `small=6`, `medium=12`. Previews use 10/8; panels use 12; hex rows use `Capsule()` (∞). Three corner languages on one screen.

**Fix:** Use `theme.radii.medium` (or new `theme.radii.card`) for previews; never hardcode radii.

---

## Section 2 — Layout, spacing, typography inconsistencies on the Appearance page

### 2.1 Three different page-title font mechanisms in one settings file
- `:358-362` — `CodexSettingsPageTitle` uses `.font(.system(size: 22, weight: .semibold))`
- `:190-194` — sidebar "Settings" header uses `.font(.system(size: 18, weight: .semibold))`
- `:218` — group header uses `theme.fonts.caption`
- `:758` — panel title uses `theme.fonts.label`

Five "title-ish" sizes (22 / 18 / label≈13 / caption≈11 / `.system(.body)`) from three different fonts. No typographic system.

**Fix:** Add `theme.fonts.pageTitle`, `theme.fonts.sectionTitle`, `theme.fonts.panelTitle` and use them everywhere.

### 2.2 Eight different HStack spacings in one file
Picker 14 (`:663`), sidebar VStack 14 (:182), card rows 18 (`:866, 1000, 1032, 1055`), ReadOnlyRow 12 (`:1123`), HexColorRow 16 (`:932`), inner swatch+field 8 (`:935`), outer pane 22 (`:246`), inner cards 20 (`:376 etc.`), grouped-route 4/16 (`:214-216`).

**Fix:** Define `theme.spacing.rowGap`, `sectionGap`, `cardPadding` and use them.

### 2.3 Third panel has no header
`:614-648` — bare `VStack(spacing: 0)` opens with `CodexSettingsSliderRow("UI font size",...)` — no header. After two named panels, user lands on a stack of six rows with no label.

**Fix:** Add header — "Display & text" or "Typography & motion".

### 2.4 Two sliders fixed at `frame(width: 150)` on a 900-wide page
`:909-910, :1003-1004`. Cramped-looking mini-sliders on a vast white plane — developer UI tell. Z

**Fix:** `frame(maxWidth: 220)` with leading alignment, or tick marks + a real column.

### 2.5 Reduce motion uses a segmented Off/On picker; every other boolean uses Toggle
`:626-632` — `CodexSettingsEnumRow(offTitle:"On", onTitle:"Off").pickerStyle(.segmented)`. Other booleans use `CodexSettingsToggleRow`.

**Fix:** Replace with `CodexSettingsToggleRow(title: "Reduce motion", detail: "Reduce animations in CodexCore", isOn: $settings.reduceMotion)`.

### 2.6 Six different right-column control widths
menu `142` (:881) / segmented `124` (:1041) / textfield `170×30` (:1062) / hex textfield `82` (:950) / font name `176` (:768) / sidebar font value `52` (:914). Right edges zig-zag down the page.

**Fix:** Standardize "trailing control column" width (e.g. 220pt).

### 2.7 `CodexAppearanceModePicker` floats between page title and first panel with no label
`:609-613` — three abstract tiles with no header. Apple Settings convention puts a section header above segmented controls.

**Fix:** Add section header "Appearance mode"; wrap in a `settingsPanel`.

### 2.8 Three disabled "vapor" rows on Appearance page advertise incompleteness
- `:633` Dock icon — `CodexDockIconVariant` fully implemented in `CodexTheme.swift:76-90`.
- `:636` Diff markers — `CodexDiffMarkerStyle` fully implemented (`:62-74`).
- `:644` Font smoothing — "Handled by macOS" (literally nothing — should be deleted).

Combined with disabled rows on General (`:387`), Profile, Configuration = 6 disabled rows declaring "app is half-built."

**Fix:** Implement the two pickers (data already exists, just unwired) OR remove. Delete Font smoothing entirely.

---

## Section 3 — Sidebar navigation (settings root)

### 3.1 Settings sidebar uses sharp `Rectangle()` glass while children are rounded
`:241` — `.codexGlass(Rectangle(), tint: theme.colors.surface.opacity(0.16))`. Abrupt meeting at rounded settings window.

**Fix:** Use `.codexGlass(RoundedRectangle(cornerRadius: theme.radii.panel, ...))` or material background.

### 3.2 `.padding(.top, 34)` arbitrary inset
`:238`. Not aligned to safe-area top inset, not a spacing token.

**Fix:** Safe-area-aware padding or `theme.spacing.pageTopInset`.

### 3.3 `ScrollView` around 7 static routes
`:213-234`. Exactly 7 routes in 4 groups; none will overflow 250×600. Adds momentum-scroll jank for no benefit.

**Fix:** Drop `ScrollView`; normal VStack with Spacer below.

### 3.4 Route rows have no hover/press state
`:222-228` — `Button { ... } label: { Label(...) }.buttonStyle(.plain).settingsSidebarRow(...)`. Only `isSelected` differentiates background. No `.onHover`.

**Fix:** Hover background via `@State var isHovered` + `.onHover`.

### 3.5 Route icons inconsistent in weight/family
`:27-37` — `person.crop.circle` filled (others line), `point.3.connected.trianglepath.dotted` visually heavy, `sun.max` is macOS Display/Brightness convention. Appearance should use `paintbrush` or `circle.lefthalf.filled`.

**Fix:** Normalize to SF Symbol `.regular` weight single family. Replace `sun.max` with `paintbrush`/`circle.lefthalf.filled`.

### 3.6 Group taxonomy doesn't match shipped
`:39-50` — "Coding" only Git. "Integrations" only "Integrations". "CodexCore" only "About" (just rebrand of About).

**Fix:** Collapse single-item groups. Personal (4 items) + About (1).

### 3.7 Search placeholder ends in `…`
`:201` — "Search settings...". HIG: ellipsis implies opening a dialog.

**Fix:** "Search Settings".

### 3.8 Search detail lines are middot-joined keyword soup
`:300-305` — `"approval · permissions · model"`. Reads like debug tag dump.

**Fix:** Real one-line human descriptions per route.

---

## Section 4 — Other settings pages (inconsistency / dead UI)

### 4.1 General page has disabled "Default to projectless chat" row
`:387-391` — another `CodexSettingsDisabledRow`. 6 disabled rows total across settings = "this app is half-built."

**Fix:** Remove features not close to shipping.

### 4.2 Profile page is essentially useless
`:398-429` — 3 rows: signed-in account, server, "Profile analytics" (disabled). No avatar, no sign-out, no account-switch, no "manage in browser."

**Fix:** Avatar row + "Sign out" + account portal link. Or rename to "Session."

### 4.3 Configuration page duplicates Approval policy editable on General
`:441-446` — read-only vs edit on adjacent page.

**Fix:** Drop duplicate, or label "Approval policy (set in General)" with tap-through.

### 4.4 Integrations page hard-truncates MCP servers to 6
`:540` `ForEach(mcpServers.prefix(6))`. No "show more", no scroll, no indicator.

**Fix:** Show all in `ScrollView`, or add "Show N more…" disclosure.

### 4.5 About page is two rows
`:564-589` — `metadata.appName` + `metadata.serverName`. No app icon, no copyright, no docs link, no "Check for updates".

**Fix:** App icon + version line + copyright + docs/privacy links.

### 4.6 Git multiline fields sandwiched between toggles
`:508-517` via `CodexSettingsMultilineTextRow` (1069-1088): `TextEditor` at `minHeight: 72`, `.font(theme.fonts.caption)` ≈ 11pt. Fat input in a stream of slim toggles.

**Fix:** Move to titled `Section("Commit & PR templates")`, or `TextField(..., axis: .vertical)` with min 3-line height.

### 4.7 `CodexSettingsDisabledPill` text nearly vanishes on glass
`:1166-1183` — `surfaceSunken.opacity(0.34)` + `textTertiary`. Below contrast threshold.

**Fix:** Bump opacity / use `textSecondary`, or better: delete the dead-pill pattern entirely (1.10).

### 4.8 `CodexAppearanceSettingsView.body` ignores `theme` in outer VStack
`:592` declares `@Environment(\.codexAgentTheme)`, but outer VStack at `:608` uses literal `20`. Theme environment plumbed for child views but appearance page itself never uses `theme.spacing.*`.

**Fix:** Pull section spacing from `theme.spacing`.

---

## Section 5 — Accessibility issues in theme section

### 5.1 Color swatches have no accessibility labels
`CodexHexColorRow.swift:936-939` — `Circle().fill(value.color)` no `.accessibilityLabel`. Hex TextField has no label — VoiceOver reads placeholder `#RRGGBB` until user types.

**Fix:** `.accessibilityLabel("Accent color: \(value.hexString)")` on swatch, `.accessibilityLabel(title)` on TextField.

### 5.2 Mode picker tiles lack `.isSelected` trait
`:664-679` — `.accessibilityLabel(option.displayName)` set, but no `.accessibilityAddTraits(.isSelected)` when `mode == option`, no `.accessibilityValue`.

**Fix:** `.accessibilityAddTraits(mode == option ? [.isSelected, .isButton] : [.isButton])`.

### 5.3 Preview decorator capsules are unlabeled
`:712-718` — fake "text line" Capsules — VoiceOver tries to read them silently.

**Fix:** `.accessibilityHidden(true)` once parent Button has a label.

### 5.4 Disabled pills have no a11y trait
`CodexSettingsDisabledPill` (`:1174-1182`) — no `.accessibilityLabel` or trait. VoiceOver announces "Import" with no indication it's disabled.

**Fix:** `.accessibilityAddTraits(.isStaticText)` + `.accessibilityLabel("\(title), not available in CodexCore yet")`, or just remove them (1.10).

### 5.5 Contrast slider without detail has no VoiceOver description
`:777-783` — VoiceOver reads only "Contrast, 45".

**Fix:** Real `detail:` ("Border and divider strength"); announce "45 percent".

---

## Section 6 — Minor / polish

### 6.1 `CodexEditableThemePanel` title font is `.label` (≈13 semibold)
`:756-759` — same weight as inline row labels. Theme "sections" read as inline labels.

**Fix:** `CodexSettingsSectionTitle` at 15-17pt medium.

### 6.2 Settings sidebar "Settings" header (18pt) heavier than route group headers (caption ≈11)
`:190-194` vs `:217-220`. Footer "CodexCore" group reads whisper-quiet.

**Fix:** Bump group headers to `theme.fonts.label` ≈ 13 medium.

### 6.3 `CodexSettingsRowLabel.detail` lineLimit(2) intermittently
`:1160` — most details one line; two-line wrap breaks 48pt row rhythm.

**Fix:** `lineLimit(1)` for inline details; reserve 2-line for a dedicated "description row".

### 6.4 `Divider().overlay(theme.colors.border.opacity(0.7))` at `:175`
70% border opacity vs `settingsPanel` borders at full `theme.colors.border`.

**Fix:** One divider color token.

### 6.5 `CodexSettingsMultilineTextRow` uses `RoundedRectangle(radii.small)` (:1084) vs textfields `Capsule()` (:1063)
Two different shapes for text inputs on one screen.

**Fix:** `Capsule()` for single-line, `RoundedRectangle(radii.medium)` for multi-line consistently — or round everything via `theme.radii.control`.

### 6.6 Page content maxWidth 900 with 72px horizontal padding
`:253-255`. Theme editor panels look stranded on wide windows — narrow strip centered on vast backdrop.

**Fix:** Widen to 1000-1100 for settings content, or `maxWidth: .infinity` with `frame(maxWidth: 720)` inner alignment.

### 6.7 `CodexTheme.swift:104` default `uiFontName` is a CSS stack
Wrong for SwiftUI even if wired.

**Fix:** Default to `"SF Pro Text"` or empty → resolve to `.body` design.

### 6.8 Theme presets are tested but never reachable
`Tests/CodexCoreUITests/CodexAgentPanelThemeTests.swift:83-91`, `CodexCardRenderingTests.swift:8` iterate `CodexAgentThemePreset.allCases`. Engineers built, themed, and unit-tested five themes, then shipped a Settings page that exposes none of them.

**Fix:** Wire `CodexAgentThemePreset` into a chooser above the color editor (1.1).

---

## TL;DR — top 5 reasons the theme section sucks

1. **Five finished, unit-tested theme presets exist but are never surfaced** — user forced to hand-type three hex values per appearance (1.1).
2. **Preview is a 92pt abstract tile with two gray lines (`:684-741`), hardcoded to white/black, decoupled from the actual chat UI, accent, or user edits** (1.2, 1.3).
3. **Two redundant raw color-editor panels, with three dead "Import"/"Copy theme"/font-name pills and two disabled enum rows** for enums already implemented — looks unfinished and decoupled (1.6, 1.10, 2.8).
4. **Hex color controls are custom 18pt circles + raw TextFields instead of SwiftUI `ColorPicker` — no opacity, no eyedropper, no validation, no a11y label, dead placeholder bleed** (1.8, 5.1).
5. **No haptics, no animations, no live preview updates, no "reset to default," inert 1px→2px stroke selection state** — most tactile moment in settings feels inert (1.4, 1.5, 1.12).