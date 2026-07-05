# CodexCore Visual Audit — Layout, Corners, Spacing

## A. Sidebar (`CodexProjectSidebar.swift`)

### A1 `cornerRadius: 10` hardcoded (also :397, 402, 477, 500, 572, 576)
Sidebar rows hard-code radius **10**. Token scale only has small (6) and medium (12). 10 is an intermediate radius used nowhere else — sidebar looks *almost-but-not-quite* like the 12-radius cards elsewhere.

**Fix:** Pick `theme.radii.small` (6) or `theme.radii.medium` (12), or add an explicit `row` radius token.

### A2 `VStack(spacing: snapshot.isCollapsed ? 8 : 22)` (`:62`)
Body uses 8/22. `routeRows` (`:195`) `VStack(spacing: 2)`, `pinnedSection`/`projectListSection`/`olderProjectsSection` `VStack(spacing: 4)`. Three different vertical group spacings (2 / 4 / 22) in one column with no semantic distinction.

### A3 Horizontal insets mismatch (`:68 / :147 / :169 / :348`)
- Body scrollview inset: `.horizontal, isCollapsed ? 8 : 16`
- Header inset: `.horizontal, isCollapsed ? 8 : 12`
- Utility section inset: `.horizontal, isCollapsed ? 8 : 16`

When expanded, header text sits 4pt further right than body/utility rows below.

**Fix:** Unify to one expanded horizontal inset (16).

### A4 `frame(width: 26, height: 30)` (`:125`) — non-square for SF Symbol
Other sidebar icons use square frames (28×28 at `:185`, 20×20 at `:380/465`, 34×34 at `:100`).

**Fix:** `frame(width: 28, height: 28)`.

### A5 "No chats" rendered twice with different padding (`:268` vs `:509`)
- `:268`: `.padding(.horizontal, 30) / .vertical, 6`
- `:509`: `.padding(.leading, 30) / .vertical, 5`

**Fix:** Shared `emptyState(Inset)` row helper.

### A6 Indented child leading padding 30 vs 38 on same collapsed state (:509 vs :526)
Same nested indent column, two values.

**Fix:** Single indented-child leading token.

### A7 `.frame(width: 21, height: 21)` chat action button (`:627`)
Tap target 21pt (under 44). Stroke opacity `border.opacity(0.7)`. Avatar circle uses `border.opacity(0.6)` (`:107`). Two different hairline opacities for similar circle borders.

**Fix:** 28×28 hit area; unify border opacity token.

### A8 Three "row icon" widths: 20, 20, 21 (`:380/465/627`)
Project row icon 20, command row icon 20, chat action icon 21. 21 is one-off.

**Fix:** `theme.spacing.iconSmall` (13) or explicit `rowIcon` token.

### A9 Header vs row icon→title spacings mismatch
Header HStack `spacing: 0/12` (`:147`); SidebarCommandRow inner `spacing: 14` (`:376`); ProjectSidebarGroupView row `spacing: 14` (`:461`). Icon→title is 14, titlebar gives 12 — visually discontinuous.

### A10 Five border opacities in one sidebar
0.10 (352 fill), 0.18 (544), 0.28 (355), 0.32 (140), 0.45 (86 trailing edge), 0.6 (107), 0.7 (631). No `borderSoft`/`borderStrong` distinction; every hairline is hand-picked.

### A11 Section header convention split
`SidebarSectionHeader` (`:426-434`): fills whole row, `padding(.horizontal, 2)`. `SummarySection` (AgentPanels.swift:146): indents only leading `.padding(.leading, 2)`. Same role, different horizontal behavior.

### A12 `theme.radii.pill = 999` defined but never used
Every actual pill in the app uses `Capsule()`. Token is dead.

**Fix:** Tokenise via `RoundedRectangle(cornerRadius: theme.radii.pill)` or remove.

---

## B. Composer (`CodexComposerBar.swift`)

### B13 Composer vs palette radii mismatch
- Outer composer surface: `theme.radii.large = 16` (`:183`).
- Four palettes (MCP/Slash/Mention/Inline): `theme.radii.composer = 28` (`:966, 1041, 1128, 1243`).

The 28-rounded palette "floats" over the 16-rounded composer → corners visibly disagree at the seam.

**Fix:** Align palette radius to `radii.large` (16), or introduce a single "popover" radius used by both.

### B14 TextField inset vs chip row inset mismatch (`:149-150` vs `:182`)
TextField inset inside composer: `.padding(.leading, 6) / .vertical, 6`. Whole composer glass padding: `.padding(10)`. Text-left starts at inset 16 (6+10) but chip row underneath inset is only 10 — text and chips in same column misaligned by 4pt. Also: left-only padding means trailing edge not matched.

**Fix:** `.padding(.horizontal, 8)` inside, or align chip row inset.

### B15 Two distinct chip vocabularies on the same composer surface
- `ComposerChipLabel` (`:855-870`): `RoundedRectangle(cornerRadius: theme.radii.medium = 12)`, `surfaceSunken.opacity(glassOpacity)` bg, **1pt border**, `minHeight: 28`, horizontal padding 10.
- `CodexStatusChip` (`CodexStatusChip.swift:27`): `Capsule()`, `color.opacity(0.16)` bg, **no border**, padding `chipPadding(4,8,4,8)`.

Plus `CodexFileChangeActionButton` (Capsule *with* `.opacity(0.74)` border, `.horizontal 8 / .vertical 4`) — three pill recipes in the same row.

**Fix:** Pick one chip shell + one border rule; centralise.

### B16 Send/Stop vs chips height mismatch
- `ComposerChipLabel` minHeight 28 (`:867`).
- `SendButton` frame `iconLarge + 4 = 32` (`:1266`).
- `ComposerStopButton` frame `iconLarge + 4 = 32` (`:885`).

In `HStack(spacing: 8)` at `:152`, the 32pt buttons tower 2pt above 28pt chips — visible baseline misalignment.

### B17 Three Send-button conventions
- Main composer Send (`:1266`): fixed frame 32, `Circle().fill(accent)` background via `.background { ... }`.
- Stop (`:885`): fixed frame 32, `.background(.., in: Circle())` + `.overlay(Circle().stroke...)`.
- Side-chat Send (`AgentPanels.swift:578`): `Image(...).font(.title2)` sized by fonts.

**Fix:** One shared `CodexSendCircleButton` component.

### B18 Palette row height 29 hardcoded (`:951, 1017, 1160, 1217`)
All four palettes use `.frame(height: 29)`. No token. Differs from `theme.fonts.sidebar.commandRowHeight`.

### B19 MCP palette internal insets don't line up (`:1111-1112` vs `:1121-1122`)
Header `.padding(.horizontal, 10) / .top, 9`; body `.padding(.horizontal, 8) / .bottom, 8`. Header text starts at 10, rows at 8 → 2pt misalignment. Other palettes use 10 for both.

### B20 Chip vs badge insets
Composer chip horizontal 10, minHeight 28. Slash palette scope badge: `.horizontal 7 / .vertical 3` in Capsule. No "small chip" token.

### B21 Three "pill background" recipes (`:1014`, `CodexFileChangeCard.swift:104`, `CodexStatusChip.swift:27`)
- Composer slash scope: `surfaceSunken.opacity(glassOpacity)`
- FileChangeCard add/remove badge: `surfaceElevated.opacity(0.32)`
- CodexStatusChip: `color.opacity(0.16)`

Three different backgrounds for same-sized small pills. They appear next to each other in transcript rows.

**Fix:** Standardise `chipPalette` enum (neutral / status / muted).

---

## C. Transcript cards

### C22 Different outer card radii
- `CodexCollapsibleCard.swift:44` (ToolCall/FileChange/Notice): `theme.radii.medium = 12`.
- `CodexCompletedWorkTraceView.swift:118` (nested): `theme.radii.small = 6`.

Sibling trace cards render at 12 vs 6 — visible step.

### C23 Inner block clipping inconsistent
`CodexToolCallCard.swift:130-133` clips detailBlock to `radii.small` (6) with own border. `CodexFileChangeCard.swift:133` `.background(theme.colors.codeBackground)` — no clip, no border.

### C24 Header background opacities differ
- NoticeCard header: `surfaceElevated.opacity(0.18)` (`:62`)
- ToolCallCard header: `surfaceElevated.opacity(0.28)` (`:61`)
- FileChangeCard header: `surfaceElevated.opacity(0.28)` (`:126`)

Notice is 0.10 less than siblings — same role, different shade.

### C25 Collapsible card literals differ
- ToolCall: `surface.opacity(glassOpacity)`, border `opacity(0.74)`
- FileChange: `surface.opacity(glassOpacity)`, border `opacity(0.74)`
- Notice: `surface.opacity(glassOpacity * 0.86)`, border `opacity(0.72)`

Same card tree, custom-tuned constants for one sibling.

### C26 Aggregate vs per-file card border opacity mismatch
- Aggregate (`CodexAggregateFileChangeCard.swift:103`): `theme.colors.border` full alpha.
- Per-file (`CodexFileChangeCard.swift:68`): `theme.colors.border.opacity(0.74)`.

Aggregate looks heavier-edged than its children — inverted emphasis.

### C27 Header-row paddings vary across card family
- FileChangeCard (`:124-125`): `.horizontal 10 / vertical 8`
- ToolCallCard (`:59-60`): `.horizontal 10 / vertical 8` ✓
- NoticeCard (`:60-61`): `.horizontal 10 / vertical 8` ✓
- MessageContentView command header (`:147-148`): `.horizontal 12 / vertical 10`
- OperationSummaryCard (`:34-35`): `.horizontal 10 / vertical 7`

Three verticals (7 / 8 / 10), two horizontals (10 / 12).

### C28 Expanded-body padding varies
- NoticeCard (`:75`): `.padding(10)` symmetric
- ToolCallCard (`:88`): `.padding(8)`; `:83` placeholder `.padding(12)`; `:144, 152` output `.padding(10)`
- FileChangeCard (`:171-172`): `.horizontal 12 / vertical 8`

### C29 Footer row vertical pad 7 — except RateLimitBanner 9
ToolCall/Footer/Notice/MessageContentView/OperationSummaryCard all use `.vertical 7`. RateLimitBanner uses 9 (`:25`). Single outlier.

### C30 `CodexCompletedWorkTraceView.swift:118-121` bespoke styling
`radii.small` (6), `surfaceElevated.opacity(0.18)`, border `border.opacity(0.42)`. None match other "card" recipes.

### C31 Multiple pill padding sizes in one block (`CodexTranscriptView.swift:425-498`)
- `:491` pill `.horizontal 9 / vertical 5`.
- `:441` mini-pill `.horizontal 7 / vertical 3`.
- `:481` `HStack(spacing:7)`.
- `:483` `HStack(spacing:5)`.
- `:425` `HStack(spacing:9)`.

Five distinct small-pill / HStack spacings inside one block.

### C32 Three card insets in same transcript column
- Lifecycle card assistant (`CodexTranscriptView.swift:501`): `.horizontal 13 / vertical 10`.
- User bubble (`:965`): `.horizontal 16 / vertical 11`.
- Empty-state prompt (`:1103`): `.horizontal 14 / vertical 11`.

Three "card row" insets — 13, 14, 16 horizontal — visible when assistant card sits above user bubble and below suggestion card.

### C33 `:1103-1104` `.vertical, 11` outlier
Only `CodexEmptyTranscriptView` and `CodexUserMessageRow` use vertical 11. Everywhere else 7 / 8 / 10 / 6. 11 appears twice and is never tokenised.

### C34 `CodexThinkingShimmer` opacity literals (`:1044-1047`)
Gradient stops `0.18 / 0.35 / 0.18` hard-coded; no token. `frame(width: 180, height: 12)` hard-coded.

### C35 Two floating-panel shadow conventions
- Transcript empty-state suggestion card (`:151`): `.black.opacity(0.16), radius: 12, y: 4` literal.
- AgentSidePanel (`CodexAgentPanels.swift:260`): `.black.opacity(theme.effects.glowOpacity), radius: 24, x: -8` tokenised.

Two recipes for "soft shadow."

### C37 `.padding(13)` symmetric (StructuredPanelCards.swift:229)
13 is the only symmetric-all-sides literal as panel padding anywhere. AgentPanels uses `16h/14v`; settings uses `16`; MCPStatusSheet uses `18`; PluginRouteView uses `18`. Five values (13/14/16/18) for "panel interior padding."

### C38 `CodexOperationSummaryCard.swift:34-35` header padding outliers
`.horizontal 10 / vertical 7`. Siblings use 10×8.

---

## D. Status chips & badges (cross-cutting)

### D39 Two "status chip" components diverge
- `CodexStatusChip.swift` — color-tinted Capsule, no border, `color.opacity(0.16)`, `chipPadding(4,8,4,8)`.
- `CodexInlineChatStatus.swift:46-50` — gray Capsule, `surfaceElevated.opacity(textFaintOpacity)`, no border, `.horizontal 7 / vertical 3`.

Same role, different inner padding, different background source.

### D40 Four status-dot sizes
- `CodexStatusChip.swift:20`: 6×6
- `CodexInlineChatStatus.swift:16`: 7×7
- `CodexTranscriptView.swift:539, 915`: 7×7
- `CodexCompletedWorkTraceView.swift:169`: 5×5

Three sizes for "live/done status dot."

**Fix:** One `statusDot` token.

### D41 Chip HStacks inconsistent
CodexStatusChip `HStack(spacing: 5)`. CodexInlineChatStatus uses 8 (`:13`) and 5 (`:39`).

### D42 Mini pills inconsistent border treatment
Some mini-pills in `CodexAgentLifecycleBlock` get `.overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))` (`:481`), others don't (`:491`).

### D43 `CodexFileChangeActionButton` is one-off
Capsule with border + `.horizontal 8 / vertical 4`, border `0.74`. CodexToolCallCard's expanded footer has no comparable styled capsule button — siblings fall back to plain `Image` buttons. One-off "action capsule button."

---

## E. Banners / notices / warnings

### E44 Two "warning banner" treatments
- RateLimit (`:24-30`): `RoundedRectangle(cornerRadius: theme.radii.medium)` (12), border `warning.opacity(0.35)`, `.horizontal 12 / vertical 9`, icon + text.
- SystemMessage (`CodexTranscriptView.swift:1013-1017`): `Capsule()`, no border, `warning.opacity(0.12)` bg, `.horizontal 14 / vertical 8`, centered with Spacers.

Different shape, inset, alignment. Same role conceptually.

### E45 RateLimit border 0.35 one-off
Background `warning.opacity(0.12)` matches SystemMessage, but border is one-off literal in RateLimitBanner only.

### E46 Two elevated opacities in one NoticeCard
- Header bg: `surfaceElevated.opacity(0.18)` (`:62`).
- CopyText footer: `surfaceElevated.opacity(0.24)` (`:88`).

Two adjacent elevated surfaces in same card. Plus they conflict with ToolCall/FileChange's 0.28.

---

## F. Settings (`CodexSettingsAboutRouteView.swift`, `CodexMobileRouteView.swift`)

### F47 Dividers
Settings divider (`:175`): `.overlay(theme.colors.border.opacity(0.7))`. Agent panel divider (`CodexAgentPanels.swift:240`): `.overlay(theme.colors.border)` full alpha.

**Fix:** One `divider()` token.

### F48 Appearance preview hard-codes radii 10 and 8
`:697, 706, 721` — neither is a token (radii.small=6, medium=12). Same file uses `radii.small` (`:1084`) — so within one file, three corner conventions (6, 8, 10).

### F49 Raw `Color.white` / `Color.black` literals
Appearance preview bypasses theme sem colors entirely (see 01-settings-theme.md §1.3).

### F50 Many `surfaceSunken/Elevated.opacity(0.x)` values for settings row control backgrounds
- 0.34 disabled pill (`:1180`).
- 0.60 selected sidebar row (`:1193`).
- 0.64 most input capsules (`:769, 882, 954, 1063`).
- 0.64 multiline body using `RoundedRectangle(radii.small)` — only non-Capsule input (`:1084`).

**Fix:** Standardise a `controlSurface` token across settings rows.

### F51 Multiline text body breaks capsule convention
`.padding(8)`, `RoundedRectangle(cornerRadius: theme.radii.small)`. Every other settings input row uses Capsule + `.padding(.horizontal, 10)` and `height: 30`. Multiline is odd one out.

### F52 Four section stack spacings
- 182 spacing 14
- 214 spacing 16
- 246/376/405/438/489/531/570/609 spacing 20
- 246 content pane spacing 22

Four section spacings in one screen (14/16/20/22).

### F53 72 vs 14 horizontal insets
Content pane `.padding(.horizontal, 72)` / `.vertical, 42` (`:253-254`). Sidebar pane `.padding(.horizontal, 14)`. 5× mismatch — divider never aligns to either pane's text rail.

### F54 Settings row HStacks use `spacing: 18`
`877, 910, 1002, 1032, 1057`. Sidebar and AgentPanels summary rows use 5-8. `Spacer(minLength: 12)` at `:873` — another untokenised 12.

### F55 Section header inconsistency
Settings group title (`:225-227`): `theme.fonts.caption`, no weight, `padding(.horizontal, 10)`. `SidebarSectionHeader` (`:426-434`): `theme.fonts.sidebar.sectionHeader.font`, `padding(.horizontal, 2)`.

### F56 Four screen-level paddings in `CodexMobileRouteView`
- Container `.padding(24)` (`:66`)
- Card `.padding(12)` (`:102`)
- Phone mock `.padding(18)` (`:161`)
- Selected-model chip `.padding(20)` (`:203`)

24/20/18/12 — four screen-level paddings, no token.

### F57 Phone mock with one-off radius
`RoundedRectangle(cornerRadius: 24)` (`:163-165`) and `surfaceElevated.opacity(0.82)`. Other cards in same route view use `theme.radii.medium` (`:103`).

---

## G. Cross-cutting

### G58 `lineWidth: 1` hardcoded 30+ places
No `theme.borders.width` token. Appearance preview at `:722` is sole `lineWidth: 2` (selected state) — every other "selected/hover border" re-uses 1.

### G59 Hairline border opacities hand-picked everywhere
Distinct literals in use: 0.10, 0.12, 0.18, 0.20, 0.24, 0.28, 0.32, 0.34, 0.35, 0.42, 0.45, 0.5, 0.52, 0.54, 0.58, 0.6, 0.64, 0.7, 0.72, 0.74, 0.82, 0.9, 0.96. `theme.effects.*Opacity` defines only `glassOpacity / textFaintOpacity / textDimOpacity / surfaceOpacity / glowOpacity` — most "border opacity" decisions leak inline.

**Fix:** Add `borderSoft / border / borderStrong` color role tokens (≈ 0.32 / 0.6 / 0.74–0.82).

### G60 `RoundedRectangle(cornerRadius: size * 0.3, ...)` (`CodexTheme.swift:1049`)
Single use, non-token, varies with `size`. No other radius derives from a frame.

### G61 Tap targets below 44pt
- `CodexProjectSidebar.swift:627` — chat action 21×21
- `CodexComposerBar.swift:867` — `minHeight: 28` chips
- `CodexComposerBar.swift:885, 1266` — Stop/Send 32×32
- `CodexAgentPanels.swift:593` — side-chat tools 30×30
- `CodexProjectSidebar.swift:185` — titlebar chrome 28×28
- `CodexAgentPanels.swift:220` — close 24×24
- `CodexComposerBar.swift:1083-1105` — palette header buttons 20×20

Five sizes for "primary tappable circle": 20/21/24/28/30/32.

### G62 `CodexInlineChatStatus.swift:55` `textTertiary.opacity(0.72)` literal
One-off unmatched elsewhere.

### G63 PluginRouteView bespoke hover/selected opacities
`:188, 240, 293, 394, 410, 444, 491`: 0.9 / 0.35 / 0.54 / 0.28 / 0.5 / 0.64 / 0.58. Two independent "clickable row" opacity scales (sidebar vs Plugin) — selected rows look different between screens.

### G64 Chat row asymmetric leading/trailing
`CodexProjectSidebar.swift:567-571`: `.leading, 6` / `.trailing, 8`. Combined with row hover fill radius 10, leading text starts closer to rounded edge than trailing content sits.

### G65 ComposerChipLabel ternary spacing
`CodexComposerBar.swift:857` — `HStack(spacing: title == nil ? 0 : 6)`. AddMenu renders with `title: nil`, so icon→(nothing) gap is 0; ModeChip has gap 6. Spacing pattern undocumented; icon position shifts when animating Add→optional title.

### G66 ToolCallCard has top Divider via CollapsibleCard, FileChangeCard's diffBody stretches beyond
Visible behavior mismatch in expanded body treatment.

### G67 Dead `theme.radii.pill = 999`
Every pill uses `Capsule()` avoiding the token.

---

## Highest-leverage fixes (summary)

1. **Pick one chip vocabulary** (Capsule vs `radii.medium`-rounded rectangle; border vs no-border; `chipPadding` token vs custom insets). B14, B15, B20, B21, D39, D43.
2. **Eliminate hard-coded sidebar radii of 10** — promote to `row` token (small 8 or medium 12). A1, A8.
3. **Add `borderSoft / border / borderStrong` color role** to absorb ~24 inlined border-opacity literals. A10, G59.
4. **Unify "card interior padding"** — codify `cardHeaderPadding (10/8)`, `cardBodyPadding (12/8)`, `cardFooterPadding (12/7)`, switch Operation/Notice/Tool/FileChange/Aggregate. C24, C26, C27, C28, C38.
5. **Align composer + palette radii** (B13) and inset (B14) — currently 16 vs 28, 6/10 mismatch.
6. **Replace appearance-preview raw `Color.white/.black` with theme colors** (F49) and promote 8/10 radii into tokens (F48).
7. **Status dot token** (`statusDot = 6` say); kill 5/6/7 spread (D40).
8. **Send/Stop/Chrome circle button component** with consistent frame (32 main, 28 sidebar, both ≥44 hit area via `.contentShape`). B16, B17, G61.
9. **Drop dead `theme.radii.pill = 999`** or use it consistently. G67, A12.
10. **Standardise "section header"** between Sidebar, SummarySection, Settings — currently three conventions. A11, F55.