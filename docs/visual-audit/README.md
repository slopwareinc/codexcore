# CodexCore Visual Audit — Index

Four-part audit conducted on `Sources/CodexCoreUI/` against `CodexTheme.swift` and the surrounding views. Findings stored locally so nothing is lost; a single GitHub issue summarizes and the fix-PR runs through the high-leverage subset.

## Files

- [`01-settings-theme.md`](./01-settings-theme.md) — Settings page, especially the Theme section. 23 concrete findings + TL;DR.
- [`02-layout-corners-spacing.md`](./02-layout-corners-spacing.md) — Corner radii, padding, spacing, alignments, separators. ~70 findings grouped by area.
- [`03-color-typography-tokens.md`](./03-color-typography-tokens.md) — Color literals escaping the theme, font literals, theme structure, sidebar font feature plumbing.
- [`04-component-polish.md`](./04-component-polish.md) — Component-by-component visual polish: cards, chips, banners, overlays, buttons, menus, panels. ~120 findings.

## Top ten highest-leverage fixes

1. **Wire `CodexAgentThemePreset` into a Settings picker** above the raw color editors. Five finished themes exist; surface them.
2. **Replace `CodexThemeModePreview` with a real mini chat row** driven by `editableTheme.agentTheme(...)`. Kill 92pt abstract tile.
3. **Use SwiftUI `ColorPicker`** instead of `CodexHexColorRow`; kill dead "Import"/"Copy theme" pills; remove the three disabled vapor rows (or implement already-built enums).
4. **Add `borderSoft / border / borderStrong` color tokens** to absorb 13 hand-picked border opacity values.
5. **Standardize one chip vocabulary** across `CodexStatusChip`, `CodexInlineChatStatus`, `CodexFileChangeActionButton`, `ComposerChipLabel` — one shape, one border rule, one background recipe, `chipPadding` token.
6. **Pick one disclosure chevron convention** (`chevron.right` rotated 0/90 — iOS standard) and apply to NoticeCard, ToolCallCard, FileChangeCard, OperationSummaryCard, AgentPanels SummarySection.
7. **Add haptic feedback** on every card toggle, send/stop, status-transition, theme/mode selection.
8. **Drive all non-sidebar typography through `theme.fonts.*`** — `panelTitle`, `routeTitle`, `sheetTitle`, `micro` tokens.
9. **Use `.monospacedDigit()`** on every diff counter, byte count, exit code, timing, token count.
10. **Replace raw `ProgressView()`** with a single shared spinner (or animated SF Symbol), and add `CodexEmptyState`/`CodexErrorState` components to replace four "No X yet" one-liners and bare red `Text(error)` strings.

## Notable bugs flagged

- `onAccent` hardcoded `.white` (`CodexTheme.swift:213`) — contrast bug for light custom accents.
- Appearance preview hardcoded `Color.white/.black` literals ignoring user theme.
- Em-dash vs ASCII "-" mismatch between aggregate and per-file card diff counters.
- `Radius` 320 (`theme.spacing.sidePanelWidth`) disagrees with sidebar's actual 288 (`SidebarMetrics.expandedWidth`).
- `CodexBlockView.swift:80-81` `isBaseBold` substring match treats `DMSans-Medium` as bold.
- `CodexCommandPaletteOverlay.swift:73` 540×620 hard-coded `frame` — crashes iPhone widths.
- Six "Not available in CodexCore yet" disabled rows across settings marketing incompleteness.

## Reference

GitHub issue: see PR body for `Fixes #NN` link.
Audit date: 2025-07-06.