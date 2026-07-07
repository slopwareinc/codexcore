# CodexCore Visual Audit — Color & Typography Token System

## Summary Verdict

A **well-architected** `CodexAgentTheme` (CodexTheme.swift) carrying ~23 semantic colors, a `Fonts` scale with `SidebarTokens` for sidebar sizes, and spacing/radii/effects/animations buckets. The sidebar is the cleanest, most thoroughly tokenized part of the codebase. Everywhere outside the sidebar, the theme is **bypassed wholesale** in habit-panel/sheet/overlay views via ad-hoc `.font(.system(size:))` calls and a few raw `Color.white`/`Color.black` literals. **There is no typography "scale" outside the sidebar** — every panel picks its own size at 18/22/22/24-ish with no shared token. Theme structure itself mixes five concerns in one struct.

---

## A. Color literals (raw colors not flowing through tokens)

These escape `theme.colors.*` and therefore do NOT respond to user-customized accent/background/foreground, contrast, or most preset themes.

| # | File:Line | Literal | Problem | Fix |
|---|---|---|---|---|
| A1 | `CodexSettingsAboutRouteView.swift:701` | `Rectangle().fill(Color.white.opacity(0.92))` | Appearance-mode preview swatch. Bypasses `theme.colors.surface`/`textPrimary`. Hardcodes "white" | Pull from `theme.colors.surface` / `lightTheme.background.color` |
| A2 | `CodexSettingsAboutRouteView.swift:702` | `Color.black.opacity(0.56)` | Same preview dark half | Pull from `darkTheme.background.color` / `theme.colors.canvas` |
| A3 | `CodexSettingsAboutRouteView.swift:729` | `.white.opacity(0.9)` | `previewBackground` for `.light` | `CodexEditableTheme.officialLight.background.color` |
| A4 | `CodexSettingsAboutRouteView.swift:730` | `.black.opacity(0.58)` | `previewBackground` for `.dark` | `CodexEditableTheme.officialDark.background.color` |
| A5 | `CodexSettingsAboutRouteView.swift:735` | `mode == .dark ? .white.opacity(0.88) : .white.opacity(0.94)` | `previewCard` — hardcoded white for BOTH modes | `theme.colors.surfaceElevated` |
| A6 | `CodexSettingsAboutRouteView.swift:739` | `mode == .dark ? .black.opacity(0.20) : .black.opacity(0.12)` | `previewLine` placeholder strokes | `theme.colors.textTertiary` or `theme.colors.border` |
| A7 | `CodexCommandPaletteOverlay.swift:45` | `Color.black.opacity(0.42)` | Modal scrim. Same opacity in light and dark; ignores contrast setting. Bypasses `codexAdaptive` helper defined in CodexTheme.swift:251 but UNUSED anywhere | Use `codexAdaptive(light: theme.colors.canvas.opacity(0.42), dark: .black.opacity(0.42))` or new `theme.colors.scrim` |
| A8 | `CodexCommandPaletteOverlay.swift:79` | `.shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 18)` | Hardcoded shadow color/opacity; identical in light mode | Add `theme.effects.shadowColor`/`shadowOpacity` or reuse `glowOpacity`-style |
| A9 | `CodexPromptPanels.swift:95, 168, 310` | `.shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)` ×3 | Same hardcoded shadow, copy-pasted in 3 sibling panels | Hoist to `theme.effects.panelShadow` |
| A10 | `CodexTranscriptView.swift:151` | `.shadow(color: .black.opacity(0.16), radius: 12, y: 4)` | Third ad-hoc shadow recipe | Tokenize as `theme.effects.cardShadow` |
| A11 | `CodexAgentPanels.swift:260` | `.shadow(color: .black.opacity(theme.effects.glowOpacity), radius: 24, x: -8)` | Uses theme opacity but hardcoded `radius: 24, x: -8` AND color is `.black` | `theme.effects.shadowColor` (adaptive) + shadow-radius token |
| A12 | `CodexTheme.swift:1058` | `.foregroundStyle(.white)` | Brand mark glyph hardcoded white — `warmMinimal.onAccent = 0x20130B` (dark brown) means white-on-accent is WRONG for custom light accents | Use `theme.colors.onAccent` |
| A13 | `CodexSubagentRunView.swift:99, 118` | `.tint(theme.colors.running)` | OK — but no `theme.colors.accentTint` semantic; non-accent tints may override accent ambiguously | Consider `theme.colors.runningTint` documented intent |
| A14 | `ANSITerminalStyle.swift:18-23, 40-45` | `Color(red: 1.0, green: 0.3, blue: 0.3)` ×12 | Hardcoded bright-ANSI palette RGB — bypasses theme so contrast/high-contrast presets have no effect | If intentional, document. Otherwise derive from `theme.colors.success/danger/warning/...` |
| A15 | `CodexBlockView.swift:100` | `Font.system(size: baseNSFont.pointSize - 1, design: .monospaced)` | Falls back to system mono when no `codeNSFont`. Bypasses `theme.fonts.code` | Use `theme.fonts.code` resolved size |

Repeated **per-view opacity magic numbers** for elevation tiers should be designer tokens: `surfaceElevated.opacity(0.96)` in `CodexPromptPanels.swift:90, 163, 305`; `surfaceElevated.opacity(0.82)` in MCPStatusSheet/Mobile; `surface.opacity(0.72)`, `0.58`, `0.45`, `0.42`, `0.34`, `0.18`, `0.12`, `0.10` scattered. These are "elevation tiers" deserving tokens like `theme.colors.surfaceElevatedTier1/2/3`.

---

## B. Typography literals (font calls bypassing `theme.fonts.*`)

Non-sidebar UI uses **NO scale** — each panel hand-picks a size. Recurring magic sizes: `11, 11.5, 12, 13, 14, 15, 16, 17, 18, 22, 24, 26` with weights `.medium/.semibold/.bold`. The sidebar has a real parameterized scale and the rest of the app does not.

| # | File:Line | Literal | Problem | Fix |
|---|---|---|---|---|
| B1 | `CodexSettingsAboutRouteView.swift:191` | `.font(.system(size: 18, weight: .semibold))` | "Settings" page title — inconsistent with sibling route titles (22) | `theme.fonts.routeTitle` |
| B2 | `CodexSettingsAboutRouteView.swift:360` | `.font(.system(size: 22, weight: .semibold))` | Section/page title in settings detail | Same `routeTitle` token |
| B3 | `CodexSettingsAboutRouteView.swift:948` | `.font(.system(size: 13, weight: .medium, design: .monospaced))` | Hex color textfield | `theme.fonts.code` |
| B4-B13 | `CodexPromptPanels.swift:28, 31, 51, 67, 79, 146, 149, 189, 194, 207, 283, 286, 339, 344, 361, 414, 474, 477` | `.font(.system(size: 10..14, weight: .semibold))` (18×) | Headers/step icons/diff icons/copy buttons — header 14s, step icon 11s, diff icon 10s; three near-equivalent "panel header" sizes: 13, 14 | Introduce `panelTitle` (14s), `panelIcon` (11s), `panelMicro` (10s) |
| B14 | `CodexPromptPanels.swift:207, 361` | `.font(.system(size: 11.5, design: .monospaced))` | Mono inline code label — another mono size distinct from `theme.fonts.code` | `theme.fonts.code` |
| B15-B16 | `CodexCommandPaletteOverlay.swift:86, 95` | `.font(.system(size: 18, weight: .semibold))`, `.font(.system(size: 11, weight: .bold))` | Command palette header / close button — won't follow `uiFontSize` | `theme.fonts.overlayTitle` + `theme.fonts.label` |
| B17-B18 | `CodexCommandPaletteOverlay.swift:108, 193` | `13 medium`, `12 medium` | Search icon / matched-command icon — two different sizes for same concept | One `searchIcon` token |
| B19 | `CodexCommandPaletteOverlay.swift:199` | `13 semibold` | Result title | `theme.fonts.label.weight(.semibold)` |
| B20-B27 | `CodexMCPStatusSheet.swift:30, 33, 38, 46, 97, 101` | `15/18 semibold`, `12/11 bold/sb`, `13/14 sb` | Sheet header / refresh / close / row title — six ad-hoc sizes | `theme.fonts.sheetTitle` + `theme.fonts.label/caption` |
| B28-B33 | `CodexMobileRouteView.swift:30, 33, 121, 125, 141, 151, 157, 187, 190` | `22/14/13/13/13/13/13/18/15 semibold` | Nine hand-rolled sizes for one route | `routeTitle` / `body` / `caption.weight(.semibold)` |
| B34-B39 | `CodexPluginRouteView.swift:87, 111, 155, 304, 360, 364, 428, 465` | `22/13/13/18/13/14/14/24 semibold/medium` | Three "route title" sizes coexist: 22 (`:87`), 18 (`:304`), 24 (`:465`) — 24 is the only one at that size in codebase | Single `routeTitle` token; `body` for subtitles |
| B40-B42 | `CodexAutomationRouteView.swift:40, 46, 103, 163, 166` | `17/22/17/16/13 semibold` | Route icon 17s, title 22s, empty-state title 17s (different from route title 22!), template icon 16s, template title 13s | `routeTitle`; document tier-below for empty-state |
| B43-B44 | `CodexAgentPanels.swift:350, 568` | `.font(.title2)` | Empty-state icon and send button icon — Apple semantic that doesn't scale with `uiFontSize` | `theme.fonts.actionIcon` |
| B45 | `CodexTranscriptView.swift:898` | `.font(.caption2)` | Inline lifecycle-event icon — Apple semantic | `theme.fonts.micro` |
| B46 | `CodexTranscriptView.swift:1073` | `.font(.system(size: 22, weight: .semibold))` | Empty-state "What should we work on?" prompt — same 22 as route titles, different code path | `heroTitle` token |
| B47 | `CodexTheme.swift:1057` | `.font(.system(size: size * 0.46, weight: .medium))` | Brand-mark glyph font. Hardcoded `.medium` weight ignores `FontWeightToken` defined 30 lines above. Magic `0.46` ratio | Use `FontWeightToken.medium.fontWeight`; expose brand-mark glyph weight as theme value |
| B48 | `CodexBlockView.swift:68` | `Font.custom(resolvedName, size: size)` | Resolves custom prose fonts. Bypasses `FontDesignToken` (`CodexTheme.swift:385`) which appears unused by anything custom | Wire `uiFontName` + `FontDesignToken` together or document parallel intent |

### Weight & modifier consistency
- `.font(theme.fonts.caption.weight(.semibold))` heavily used (30+ matches across ComposerBar/AgentPanels/GitReviewPanel) — good pattern. Extend this idiom to introduce `panelTitle`, `routeTitle`, `sheetTitle`, `micro`, `actionIcon`.
- `.font(theme.fonts.caption.monospacedDigit())` (CodexInlineChatStatus:33) — solid.
- No hardcoded `.fontWeight(...)` literal escapes found — good.

---

## C. Theme structure (`CodexTheme.swift` itself)

| # | Issue | Evidence |
|---|---|---|
| C1 | Theme struct mixes 5 concerns in one pile | `CodexAgentTheme` holds `colors`, `fonts`, `spacing`, `radii`, `effects`, `animations` (`:269-291`) |
| C2 | Inconsistent naming: "padding" vs "pad" vs "spacing" vs "gap" | `Spacing` struct uses `rowGap`, `chipPadding`, `chatLineSpacing`, `iconSmall/Medium/Large`, `transcriptMaxWidth` — mixing width/padding/gap/icon-size/line spacing |
| C3 | `Spacing` (lines 623-685) contains `transcriptMaxWidth`, `composerMaxWidth`, `sidePanelWidth`, `summaryPanelWidth`, `toolbarHeight`, `cardMaxWidth`, `transcriptOuterMaxWidth`, `userBubbleMaxWidth` — layout widths, not "spacing". Plus `iconSmall/Medium/Large` (sizing). Plus `chatLineSpacing` (typography). |
| C4 | **Duplicate defaults** | `Spacing.official` (671-684) redeclares `chipPadding: EdgeInsets(4,8,4,8)` even though init default at `:649` is identical — silent drift risk |
| C5 | Same duplication for radii defaults — Effects.init defaults `glassOpacity`, `textFaintOpacity`, `textDimOpacity` (`:739-741`); Animations.init defaults everything (`:763-766`). Inconsistent default policy across sibling structs |
| C6 | Animations defaults disagree with `.official` | `Animations.init` default `defaultDuration: 0.15`, but `Animations.official` `defaultDuration: 0.25` (`:776`). `Effects.official` ignores `glassOpacity` (uses init default 0.72), but `officialDark` explicitly sets 0.72 (`:811`) — redundant |
| C7 | **`onAccent` always `.white`** | `CodexTheme.swift:213`: `theme.colors.onAccent = isDark ? .white : .white`. Ternary is meaningless. For custom light accent (pastel yellow), white-on-accent is a contrast violation |
| C8 | **Unused infrastructure** | `codexAdaptive(_:_:)` (`:251`) referenced ZERO times. `FontDesignToken` / `FontWeightToken` (`:369-399`) only used inside `SidebarTypography`, not main `Fonts` or any view. `CodexDiffMarkerStyle`, `CodexDockIconVariant` declared with `displayName` plumbing but rendered in no audited view |
| C9 | **Missing tokens** for things actually used | No `shadow`/`scrim`/`overlay`/`pressed`/`hover` tokens — yet `isHovered` states drive `.opacity(0.50/0.36/0.22/0.18)` literals scattered across sidebar (`CodexProjectSidebar.swift:411-416, 540-545, 640-647`). Selection/hover are copy-pasted across 3 row types |
| C10 | `highContrast` preset (`:898-924`) hardcoded black/white/yellow — fine as preset but not derived from user accent. Switching drops user's custom accent |
| C11 | `CodexBrandMark` shadow uses theme but glyph uses white (`:1061` accent shadow, `:1058` hardcoded `.white`) |
| C12 | **Two parallel font-scaling systems** | `Fonts.scaled(baseTextSize:)` (`:229`) scales body/chat/caption/label/code/micro but explicitly preserves `sidebar` (`:238`). `CodexCoreAppModel.swift:44` overrides `theme.fonts.sidebar = .official(baseTextSize: sidebarFontSize)` separately. Both ranges identical (11-18). UI surfaces both as separate sliders; conceptually parallel "size the typography by N pts=" with different code paths |

---

## D. Dark mode handling

| # | Issue | Evidence |
|---|---|---|
| D1 | Dark mode is handled via **`appearance.bestMatch`** in `codexAdaptive` (`CodexTheme.swift:254`) — but helper is NEVER USED, so per-view code falls back to fixed `.white`/`.black` switches (A1-A6, A7-A11) |
| D2 | `mode == .dark ? ... : ...` ternaries in `CodexSettingsAboutRouteView.swift:735, 739` re-implement dark mode per-view using `.white`/`.black` — ignores active theme preset |
| D3 | `CodexAppearanceSettings.effectiveTheme(systemIsDark:)` (`:157`) is the SINGLE correct switch — yet views re-derive `isDark` themselves for preview cards |
| D4 | Shadow colors hardcoded `.black` (A8-A11) render near-invisible on dark mode canvas — should adapt to `theme.colors.border` or lighter tone |
| D5 | ANSI terminal palette (`ANSITerminalStyle.swift`) has separate light/dark tables (`:7-26` vs `:28-47`) — GOOD pattern, but per-color `Color(red:)` bypasses theme so high-contrast preset has no effect on terminal render |

---

## E. Sidebar font-size feature — plumbing audit

The sidebar font feature is the cleanest part of the entire codebase, fully tokenized and consistently applied. Plumbing trace:

1. **Token source**: `CodexAgentTheme.Fonts.SidebarTypography` (`CodexTheme.swift:473-620`) — `baseTextSizeRange: 11...18` (`:475`), `official(baseTextSize:)` factory (`:590`), full per-element offset table at `:597-618`.
2. **Storage**: `CodexSidebarFontSizeStorage` (`CodexCoreAppModel.swift:1790-1806`), key `"CodexCoreApp.sidebarFontSize.v2"`, `clamped()` enforces range.
3. **App model binding**: `CodexCoreAppModel.sidebarFontSize: Double` (`CodexCoreAppModel.swift:32`) with didSet re-clamp (`:34-37`).
4. **Theme injection**: `CodexCoreAppModel.swift:44` — `theme.fonts.sidebar = .official(baseTextSize: sidebarFontSize)` — applied AFTER `effectiveTheme` (which already scaled OTHER fonts via `uiFontSize`). Sidebar is scaled separately from body.
5. **Settings UI**: `CodexSettingsAboutRouteView` lines 127, 142, 158, 275-276, 595-625 — exposes BOTH a UI font size slider (`:618-619`) and sidebar font slider (`:623-624`).
6. **Shell wiring**: `CodexCoreAppShell.swift:162-163` and `CodexCoreApp.swift:197-198` inject `$model.sidebarFontSize` and `CodexSidebarFontSizeStorage.fontSizeRange`.
7. **Row heights**: `SidebarTypography` computes `commandRowHeight`, `projectRowHeight`, `collapsedProjectRowHeight`, `chatRowHeight`, `sectionHeaderHeight`, `disclosureRowHeight`, `hiddenRowsPromptHeight`, `accountFooterHeight`, `collapsedAccountFooterHeight` from same base size (`:546-580`) — row heights scale with font, no clipping at large sizes.
8. **Application in CodexProjectSidebar.swift**: every `Text` uses `sidebarFonts.<token>.font` (lines 98, 113, 117, 123, 184, 266, 288, 291, 293, 378, 383, 389, 428, 463, 468, 507, 523, 563, 587, 626). **NO `Text`/`Image.font` in `CodexProjectSidebar.swift` escapes the sidebar token system.**

### Sidebar feature inconsistencies

| # | Issue | Evidence |
|---|---|---|
| E1 | `SidebarTypography.accountInitialsCollapsed` is `token(-3)` (size 9 at base 12); `accountInitialsExpanded` is `token(-1)` (size 11). `chatActionIcon` uses non-token formula `FontToken(size: max(8, baseTextSize - 5.5))` (`:617`) — only sidebar element that doesn't go through `token(offset)`. Magic `-5.5` |
| E2 | `rowHeight(for:padding:)` (`:582`) uses `max(24, token.size + padding)`. Padding magic numbers per-element: 20/19/17/18/16/18/17 (`:547-572`) — six different paddings for what is conceptually "row vertical padding" |
| E3 | **Two parallel scaling systems**: body-text scale (`Fonts.scaled`) driven by `uiFontSize` (range 11-18), sidebar scale by `sidebarFontSize` (range 11-18) — separate sliders, separate storage, separate code paths, IDENTICAL ranges. User who bumps `uiFontSize` to 18 sees huge chat text but tiny sidebar unless they also bump the sidebar slider |
| E4 | Sidebar has two parallel metric systems: theme `Spacing.sidePanelWidth=320` vs `SidebarMetrics.expandedWidth=288` (`CodexProjectSidebar.swift:675-680`). **They disagree.** `expandedWidth/collapsedWidth/titlebarHeight/trafficLightReserveWidth` ALL bypass `theme.spacing` |
| E5 | `CodexSidebarNavigation.swift` (snapshot/session file) has NO theme/font references — pure model. Correct layering, but means no test for "does sidebar respect font size" in that file |

---

## Cross-cutting observations

1. `CodexChatFormat.swift` is a 1-line `typealias` to `CodexChatUtilitySession`, which contains ZERO typography/styling — plain-text transcript assembly. Chat typography lives in `CodexTranscriptView`, `CodexBlockView`, `CodexMessageContentView`, `CodexComposerBar`. There is no single chat-format file; chat styling is scattered.

2. `.lineSpacing` audit:
   - GOOD — chat prose uses `theme.spacing.chatLineSpacing` consistently (`CodexTranscriptView.swift:380, 935, 962`; `CodexBlockView.swift:241`).
   - BAD — `CodexPluginRouteView.swift:478` uses `.lineSpacing(3)` literal. Only line-spacing escape in the UI.

3. `.tracking` / `.kern`: zero uses anywhere. No tracking tokens exist; not a current problem.

4. `cornerRadius:` literals (vs `theme.radii`): 21 escapes:
   - `cornerRadius: 10` in `CodexProjectSidebar.swift` (6×), `CodexSettingsAboutRouteView.swift` (3×) — sidebar's "row corner radius" 10 disagrees with `theme.radii.small = 6`.
   - `cornerRadius: 24` in `CodexMobileRouteView.swift:163, 165` for the phone mock — fine as physical mock, but not tokenized.
   - `cornerRadius: 8` in `CodexSettingsAboutRouteView.swift:706` — also not in `theme.radii`.
   Fix: add `theme.radii.row = 10`, reconcile 8 vs `radii.small` (6).

5. `.opacity(...)` literals for elevation tiers — see end of section A. Convert to `Effects.surfaceElevatedTier1/2/3`.

6. Accent usage: `.foregroundStyle(theme.colors.accent)` consistently used; `.tint(...)` only on `CodexStatusChip:16` (themed), `CodexSubagentRunView:99,118` (themed). No raw `.accentColor(...)`. Accent bypassing is NOT a current problem.

7. Wrong semantic colors:
   - `CodexProjectSidebar.swift:469` — project title uses `textSecondary` even when `group.isSelected` (line 464 ternary only flips the icon). Selected project title stays grey — inconsistent with selected chat row (`:564`) which flips to `textPrimary`. **Sister components diverge.**
   - `CodexProjectSidebar.swift:384` — `SidebarCommandRow` selected title uses `textPrimary`. `SidebarChatRow:564` uses same pattern. `ProjectSidebarGroupView:469` does NOT — only the icon flips.

8. Tests: `CodexAgentPanelThemeTests.swift:144, 158, 171` covers `uiFontSize` decoding and `SidebarTypography.official(baseTextSize: 16)` round-trip — good coverage of scaling factory; no tests for bypassed views reverting to system sizes.

---

## Priority ranking for fixing

1. **A12 / C7** — `onAccent` hardcoded `.white` (brand mark) + meaningless ternary. Active contrast bug for custom light accents.
2. **A5, A6, D2** — `previewCard`/`previewLine` white-black hardcoded ignoring presets. Visible to users customizing themes in Settings.
3. **A7-A11** — shadow/scrim hardcoded `.black.opacity(...)`. Inconsistent light/dark rendering across panels.
4. **E4** — `Spacing.sidePanelWidth=320` vs `SidebarMetrics.expandedWidth=288` disagreement. Delete one.
5. **B1-B47 (whole cluster)** — ad-hoc typography outside sidebar. Single biggest "taste" issue; sidebar shows the codebase already knows how to do this right.
6. **C8** — `codexAdaptive` helper unused; would solve half of A7-A11 if wired in.
7. **C2/C3** — `Spacing` struct mixes widths/sizes/gaps; rename/split.
8. **E1** — `chatActionIcon` magic `-5.5` in otherwise-clean token table.
9. **E2** — six different `rowHeight` padding magic numbers.
10. **Inconsistency #7 above** — selected-project-row doesn't flip title color, sister rows do.