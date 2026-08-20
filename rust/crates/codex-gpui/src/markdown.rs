//! Native rendering for framework-neutral Markdown presentation trees.

use std::ops::Range;

use codex_presentation::{MarkdownAlignment, MarkdownDocument, MarkdownNode, MarkdownQuoteKind};
use gpui::{
    AnyElement, EventEmitter, FontStyle, FontWeight, HighlightStyle, Role, StrikethroughStyle,
    StyledText, TextAlign, UnderlineStyle, WeakEntity, div, prelude::*, px,
};

use crate::transcript::{CodexTheme, TranscriptEvent, TranscriptLayoutMetrics, is_activation_key};

pub(crate) fn render_markdown<E>(
    document: &MarkdownDocument,
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    div()
        .id("assistant-markdown")
        .role(Role::Document)
        .aria_label("Assistant response")
        .w_full()
        .flex()
        .flex_col()
        .gap_3()
        .text_size(px(TranscriptLayoutMetrics::CHAT_TEXT_SIZE))
        .children(
            document
                .blocks
                .iter()
                .map(|block| render_block(&block.node, block.ordinal, theme, emitter)),
        )
        .into_any()
}

#[allow(clippy::too_many_lines)]
fn render_block<E>(
    node: &MarkdownNode,
    ordinal: usize,
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    let id = ("markdown-block", ordinal);
    match node {
        MarkdownNode::Paragraph(children) => div()
            .id(id)
            .whitespace_normal()
            .line_height(px(TranscriptLayoutMetrics::CHAT_LINE_HEIGHT))
            .child(render_inline(children, theme, emitter, ordinal))
            .into_any(),
        MarkdownNode::Heading { level, children } => div()
            .id(id)
            .role(Role::Heading)
            .aria_level(usize::from(*level))
            .text_size(px(heading_size(*level)))
            .font_weight(FontWeight::SEMIBOLD)
            .whitespace_normal()
            .child(render_inline(children, theme, emitter, ordinal))
            .into_any(),
        MarkdownNode::BlockQuote { kind, children } => div()
            .id(id)
            .role(Role::Blockquote)
            .aria_label(quote_label(*kind))
            .border_l_2()
            .border_color(match kind {
                Some(MarkdownQuoteKind::Warning | MarkdownQuoteKind::Caution) => theme.warning,
                Some(MarkdownQuoteKind::Tip | MarkdownQuoteKind::Note) => theme.accent,
                Some(MarkdownQuoteKind::Important) | None => theme.border,
            })
            .pl_3()
            .text_color(theme.muted_text)
            .children(
                children
                    .iter()
                    .enumerate()
                    .map(|(index, child)| render_block(child, index, theme, emitter)),
            )
            .into_any(),
        MarkdownNode::CodeBlock {
            language,
            code,
            complete,
        } => div()
            .id(id)
            .role(Role::Code)
            .aria_label(language.as_ref().map_or_else(
                || "Code block".to_owned(),
                |language| format!("{language} code block"),
            ))
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .bg(theme.surface)
            .overflow_hidden()
            .when(language.is_some() || !complete, |view| {
                view.child(
                    div()
                        .px_3()
                        .py_1()
                        .text_xs()
                        .text_color(theme.muted_text)
                        .child(
                            language
                                .clone()
                                .unwrap_or_else(|| "Streaming code".to_owned()),
                        ),
                )
            })
            .child(
                div()
                    .border_t_1()
                    .border_color(theme.border)
                    .p_3()
                    .font_family("monospace")
                    .text_sm()
                    .whitespace_normal()
                    .child(code.clone()),
            )
            .into_any(),
        MarkdownNode::List { start, items } => div()
            .id(id)
            .role(Role::List)
            .aria_label(if start.is_some() {
                "Ordered list"
            } else {
                "Unordered list"
            })
            .flex()
            .flex_col()
            .gap_1()
            .children(items.iter().enumerate().map(|(index, item)| {
                render_list_item(
                    item,
                    start.map_or("•".to_owned(), |start| {
                        format!("{}.", start.saturating_add(index as u64))
                    }),
                    index,
                    theme,
                    emitter,
                )
            }))
            .into_any(),
        MarkdownNode::Table {
            alignments,
            children,
        } => div()
            .id(id)
            .role(Role::Table)
            .aria_label("Markdown table")
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .overflow_hidden()
            .children(children.iter().enumerate().map(|(index, child)| {
                render_table_section(child, index, alignments, theme, emitter)
            }))
            .into_any(),
        MarkdownNode::Rule => div()
            .id(id)
            .aria_label("Horizontal separator")
            .h(px(1.))
            .w_full()
            .bg(theme.border)
            .into_any(),
        MarkdownNode::HtmlFallback(html) => div()
            .id(id)
            .role(Role::Code)
            .aria_label("Raw HTML shown as text")
            .rounded_lg()
            .border_1()
            .border_color(theme.warning)
            .bg(theme.surface)
            .p_3()
            .font_family("monospace")
            .text_sm()
            .whitespace_normal()
            .child(html.clone())
            .into_any(),
        MarkdownNode::Item(_) => render_list_item(node, "•".to_owned(), ordinal, theme, emitter),
        MarkdownNode::TableHead(children) | MarkdownNode::TableRow(children) => render_table_row(
            children,
            ordinal,
            matches!(node, MarkdownNode::TableHead(_)),
            &[],
            theme,
            emitter,
        ),
        MarkdownNode::TableCell(children) => div()
            .id(id)
            .flex_1()
            .min_w(px(120.))
            .px_3()
            .py_2()
            .whitespace_normal()
            .child(render_inline(children, theme, emitter, ordinal))
            .into_any(),
        _ => div()
            .id(id)
            .whitespace_normal()
            .child(render_inline(
                std::slice::from_ref(node),
                theme,
                emitter,
                ordinal,
            ))
            .into_any(),
    }
}

fn render_list_item<E>(
    item: &MarkdownNode,
    default_marker: String,
    index: usize,
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    let children = match item {
        MarkdownNode::Item(children) => children.as_slice(),
        _ => std::slice::from_ref(item),
    };
    let marker = children
        .iter()
        .find_map(|child| match child {
            MarkdownNode::TaskMarker { checked } => Some(if *checked { "☑" } else { "☐" }),
            MarkdownNode::Paragraph(nodes) => nodes.iter().find_map(|node| match node {
                MarkdownNode::TaskMarker { checked } => Some(if *checked { "☑" } else { "☐" }),
                _ => None,
            }),
            _ => None,
        })
        .map_or(default_marker, str::to_owned);
    div()
        .id(("markdown-list-item", index))
        .role(Role::ListItem)
        .aria_label(format!("{marker} {}", item.plain_text()))
        .flex()
        .items_start()
        .gap_2()
        .child(div().w(px(28.)).text_color(theme.muted_text).child(marker))
        .child(
            div().flex_1().flex().flex_col().gap_1().children(
                children
                    .iter()
                    .filter(|node| !matches!(node, MarkdownNode::TaskMarker { .. }))
                    .enumerate()
                    .map(|(child_index, child)| render_block(child, child_index, theme, emitter)),
            ),
        )
        .into_any()
}

fn render_table_section<E>(
    node: &MarkdownNode,
    index: usize,
    alignments: &[MarkdownAlignment],
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    match node {
        MarkdownNode::TableHead(children) => {
            render_table_row(children, index, true, alignments, theme, emitter)
        }
        MarkdownNode::TableRow(children) => {
            render_table_row(children, index, false, alignments, theme, emitter)
        }
        _ => render_block(node, index, theme, emitter),
    }
}

fn render_table_row<E>(
    children: &[MarkdownNode],
    index: usize,
    heading: bool,
    alignments: &[MarkdownAlignment],
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    div()
        .id(("markdown-table-row", index))
        .role(Role::Row)
        .w_full()
        .flex()
        .when(heading, |row| {
            row.bg(theme.surface).font_weight(FontWeight::SEMIBOLD)
        })
        .border_b_1()
        .border_color(theme.border)
        .children(children.iter().enumerate().map(|(cell_index, cell)| {
            div()
                .id(("markdown-table-cell", cell_index))
                .role(if heading {
                    Role::ColumnHeader
                } else {
                    Role::Cell
                })
                .flex_1()
                .min_w(px(120.))
                .border_r_1()
                .border_color(theme.border)
                .px_3()
                .py_2()
                .text_align(
                    alignments
                        .get(cell_index)
                        .map_or(TextAlign::Left, |alignment| {
                            markdown_text_alignment(*alignment)
                        }),
                )
                .whitespace_normal()
                .child(render_inline(
                    match cell {
                        MarkdownNode::TableCell(children) => children,
                        _ => std::slice::from_ref(cell),
                    },
                    theme,
                    emitter,
                    cell_index,
                ))
        }))
        .into_any()
}

const fn markdown_text_alignment(alignment: MarkdownAlignment) -> TextAlign {
    match alignment {
        MarkdownAlignment::Center => TextAlign::Center,
        MarkdownAlignment::Trailing => TextAlign::Right,
        MarkdownAlignment::Unspecified | MarkdownAlignment::Leading => TextAlign::Left,
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct InlineStyle(u8);

impl InlineStyle {
    const STRONG: u8 = 1 << 0;
    const EMPHASIS: u8 = 1 << 1;
    const STRIKETHROUGH: u8 = 1 << 2;
    const CODE: u8 = 1 << 3;
    const LINK: u8 = 1 << 4;
    const HTML: u8 = 1 << 5;
    const SUPERSCRIPT: u8 = 1 << 6;
    const SUBSCRIPT: u8 = 1 << 7;

    const fn with(self, flag: u8) -> Self {
        Self(self.0 | flag)
    }

    const fn has(self, flag: u8) -> bool {
        self.0 & flag != 0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct InlineLink {
    range: Range<usize>,
    destination: String,
    label: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct InlineProjection {
    text: String,
    highlights: Vec<(Range<usize>, InlineStyle)>,
    code_ranges: Vec<Range<usize>>,
    links: Vec<InlineLink>,
    superscript_ranges: Vec<Range<usize>>,
    subscript_ranges: Vec<Range<usize>>,
}

fn project_inline(nodes: &[MarkdownNode]) -> InlineProjection {
    let mut projection = InlineProjection::default();
    for node in nodes {
        flatten_inline(node, InlineStyle::default(), &mut projection);
    }
    projection
}

fn styled_inline(nodes: &[MarkdownNode], theme: CodexTheme) -> StyledText {
    styled_projection(&project_inline(nodes), theme)
}

fn styled_projection(projection: &InlineProjection, theme: CodexTheme) -> StyledText {
    let highlights = projection
        .highlights
        .iter()
        .map(|(range, style)| (range.clone(), highlight_style(*style, theme)));
    StyledText::new(projection.text.clone())
        .with_highlights(highlights)
        .with_font_family_overrides(
            projection
                .code_ranges
                .iter()
                .cloned()
                .map(|range| (range, "monospace".into())),
        )
}

fn styled_projection_range(
    projection: &InlineProjection,
    theme: CodexTheme,
    range: Range<usize>,
) -> StyledText {
    let highlights = projection.highlights.iter().filter_map(|(source, style)| {
        let start = source.start.max(range.start);
        let end = source.end.min(range.end);
        (start < end).then_some((
            start - range.start..end - range.start,
            highlight_style(*style, theme),
        ))
    });
    let code_ranges = projection.code_ranges.iter().filter_map(|source| {
        let start = source.start.max(range.start);
        let end = source.end.min(range.end);
        (start < end).then_some((start - range.start..end - range.start, "monospace".into()))
    });
    StyledText::new(projection.text[range.clone()].to_owned())
        .with_highlights(highlights)
        .with_font_family_overrides(code_ranges)
}

fn highlight_style(style: InlineStyle, theme: CodexTheme) -> HighlightStyle {
    let mut highlight = HighlightStyle::default();
    if style.has(InlineStyle::STRONG) {
        highlight.font_weight = Some(FontWeight::BOLD);
    }
    if style.has(InlineStyle::EMPHASIS) {
        highlight.font_style = Some(FontStyle::Italic);
    }
    if style.has(InlineStyle::STRIKETHROUGH) {
        highlight.strikethrough = Some(StrikethroughStyle {
            thickness: px(1.),
            color: Some(theme.muted_text.into()),
        });
    }
    if style.has(InlineStyle::CODE) {
        highlight.background_color = Some(theme.surface.into());
    }
    if style.has(InlineStyle::LINK) {
        highlight.color = Some(theme.accent.into());
        highlight.underline = Some(UnderlineStyle {
            thickness: px(1.),
            color: Some(theme.accent.into()),
            wavy: false,
        });
    }
    if style.has(InlineStyle::HTML) {
        highlight.color = Some(theme.warning.into());
    }
    highlight
}

fn render_inline<E>(
    nodes: &[MarkdownNode],
    theme: CodexTheme,
    emitter: &WeakEntity<E>,
    ordinal: usize,
) -> AnyElement
where
    E: EventEmitter<TranscriptEvent>,
{
    let projection = project_inline(nodes);
    if projection.links.is_empty()
        && projection.superscript_ranges.is_empty()
        && projection.subscript_ranges.is_empty()
    {
        return div()
            .id(format!("markdown-inline:{ordinal}"))
            .child(styled_inline(nodes, theme))
            .into_any();
    }

    let mut boundaries = vec![0, projection.text.len()];
    for link in &projection.links {
        boundaries.extend([link.range.start, link.range.end]);
    }
    boundaries.extend(
        projection
            .superscript_ranges
            .iter()
            .flat_map(|range| [range.start, range.end]),
    );
    boundaries.extend(
        projection
            .subscript_ranges
            .iter()
            .flat_map(|range| [range.start, range.end]),
    );
    boundaries.sort_unstable();
    boundaries.dedup();

    let fragments = boundaries
        .windows(2)
        .enumerate()
        .filter_map(|(index, bounds)| {
            let start = bounds[0];
            let end = bounds[1];
            if start == end {
                return None;
            }
            let range = start..end;
            let link = projection
                .links
                .iter()
                .find(|link| link.range.start <= start && end <= link.range.end);
            let is_superscript = projection
                .superscript_ranges
                .iter()
                .any(|script| script.start <= start && end <= script.end);
            let is_subscript = projection
                .subscript_ranges
                .iter()
                .any(|script| script.start <= start && end <= script.end);
            let mut fragment = div()
                .id(format!("markdown-inline:{ordinal}:{index}"))
                .child(styled_projection_range(&projection, theme, range));
            if is_superscript || is_subscript {
                fragment = fragment
                    .text_size(px(TranscriptLayoutMetrics::CHAT_TEXT_SIZE * 0.75))
                    .relative()
                    .top(px(if is_superscript { -3. } else { 3. }));
            }
            if let Some(link) = link {
                let event = TranscriptEvent::OpenLink {
                    destination: link.destination.clone(),
                    label: link.label.clone(),
                };
                let emitter = emitter.clone();
                let click_emitter = emitter.clone();
                let click_event = event.clone();
                fragment = fragment
                    .role(Role::Link)
                    .aria_label(format!("Open link {}", link.label))
                    .focusable()
                    .tab_stop(true)
                    .text_color(theme.accent)
                    .cursor_pointer()
                    .on_click(move |_, _, cx| {
                        click_emitter
                            .update(cx, |_, cx| cx.emit(click_event.clone()))
                            .ok();
                    })
                    .on_key_down(move |key_event, window, cx| {
                        if is_activation_key(&key_event.keystroke.key) {
                            window.prevent_default();
                            emitter.update(cx, |_, cx| cx.emit(event.clone())).ok();
                        }
                    });
            }
            Some(fragment)
        })
        .collect::<Vec<_>>();

    div()
        .id(format!("markdown-inline:{ordinal}:root"))
        .w_full()
        .flex()
        .flex_wrap()
        .items_baseline()
        .whitespace_normal()
        .children(fragments)
        .into_any()
}

fn flatten_inline(node: &MarkdownNode, mut style: InlineStyle, output: &mut InlineProjection) {
    match node {
        MarkdownNode::Text(text) => append_inline(text, style, output),
        MarkdownNode::InlineCode(code) | MarkdownNode::CodeBlock { code, .. } => {
            style = style.with(InlineStyle::CODE);
            append_inline(code, style, output);
        }
        MarkdownNode::Strong(children) => {
            style = style.with(InlineStyle::STRONG);
            flatten_children(children, style, output);
        }
        MarkdownNode::Emphasis(children) => {
            style = style.with(InlineStyle::EMPHASIS);
            flatten_children(children, style, output);
        }
        MarkdownNode::Strikethrough(children) => {
            style = style.with(InlineStyle::STRIKETHROUGH);
            flatten_children(children, style, output);
        }
        MarkdownNode::Link {
            destination,
            children,
            ..
        } => {
            let start = output.text.len();
            style = style.with(InlineStyle::LINK);
            flatten_children(children, style, output);
            let end = output.text.len();
            if start < end {
                output.links.push(InlineLink {
                    range: start..end,
                    destination: destination.clone(),
                    label: output.text[start..end].to_owned(),
                });
            }
        }
        MarkdownNode::Image { alt, .. } => {
            style = style.with(InlineStyle::EMPHASIS);
            append_inline("Image: ", style, output);
            flatten_children(alt, style, output);
        }
        MarkdownNode::HtmlFallback(html) => {
            style = style.with(InlineStyle::HTML);
            append_inline(html, style, output);
        }
        MarkdownNode::SoftBreak | MarkdownNode::HardBreak => append_inline("\n", style, output),
        MarkdownNode::TaskMarker { checked } => {
            append_inline(if *checked { "☑ " } else { "☐ " }, style, output);
        }
        MarkdownNode::Rule => append_inline("—", style, output),
        MarkdownNode::Superscript(children) => {
            let start = output.text.len();
            flatten_children(children, style.with(InlineStyle::SUPERSCRIPT), output);
            let end = output.text.len();
            if start < end {
                output.superscript_ranges.push(start..end);
            }
        }
        MarkdownNode::Subscript(children) => {
            let start = output.text.len();
            flatten_children(children, style.with(InlineStyle::SUBSCRIPT), output);
            let end = output.text.len();
            if start < end {
                output.subscript_ranges.push(start..end);
            }
        }
        MarkdownNode::Paragraph(children)
        | MarkdownNode::Heading { children, .. }
        | MarkdownNode::BlockQuote { children, .. }
        | MarkdownNode::Item(children)
        | MarkdownNode::Table { children, .. }
        | MarkdownNode::TableHead(children)
        | MarkdownNode::TableRow(children)
        | MarkdownNode::TableCell(children)
        | MarkdownNode::Group(children) => flatten_children(children, style, output),
        MarkdownNode::List { items, .. } => flatten_children(items, style, output),
    }
}

fn flatten_children(children: &[MarkdownNode], style: InlineStyle, output: &mut InlineProjection) {
    for child in children {
        flatten_inline(child, style, output);
    }
}

fn append_inline(text: &str, style: InlineStyle, output: &mut InlineProjection) {
    if text.is_empty() {
        return;
    }
    let start = output.text.len();
    output.text.push_str(text);
    let range = start..output.text.len();
    if style != InlineStyle::default() {
        output.highlights.push((range.clone(), style));
    }
    if style.has(InlineStyle::CODE) {
        output.code_ranges.push(range);
    }
}

const fn heading_size(level: u8) -> f32 {
    match level {
        1 => 24.,
        2 => 21.,
        3 => 18.,
        _ => 15.,
    }
}

const fn quote_label(kind: Option<MarkdownQuoteKind>) -> &'static str {
    match kind {
        Some(MarkdownQuoteKind::Note) => "Note",
        Some(MarkdownQuoteKind::Tip) => "Tip",
        Some(MarkdownQuoteKind::Important) => "Important",
        Some(MarkdownQuoteKind::Warning) => "Warning",
        Some(MarkdownQuoteKind::Caution) => "Caution",
        None => "Quote",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_projection_uses_disjoint_utf8_ranges() {
        let document = MarkdownDocument::parse("😀 **bold and *italic*** plus `code`");
        let MarkdownNode::Paragraph(nodes) = &document.blocks[0].node else {
            panic!("paragraph expected");
        };
        let mut projection = InlineProjection::default();
        flatten_children(nodes, InlineStyle::default(), &mut projection);
        for (index, (range, _)) in projection.highlights.iter().enumerate() {
            assert!(projection.text.is_char_boundary(range.start));
            assert!(projection.text.is_char_boundary(range.end));
            if index > 0 {
                assert!(projection.highlights[index - 1].0.end <= range.start);
            }
        }
    }

    #[test]
    fn inline_projection_keeps_links_inline_and_records_scripts() {
        let nodes = vec![
            MarkdownNode::Link {
                destination: "https://example.com".to_owned(),
                title: String::new(),
                children: vec![MarkdownNode::Text("docs".to_owned())],
            },
            MarkdownNode::Text(" H".to_owned()),
            MarkdownNode::Subscript(vec![MarkdownNode::Text("2".to_owned())]),
            MarkdownNode::Text("O x".to_owned()),
            MarkdownNode::Superscript(vec![MarkdownNode::Text("2".to_owned())]),
        ];
        let projection = project_inline(&nodes);
        assert_eq!(projection.links.len(), 1);
        assert_eq!(projection.links[0].label, "docs");
        assert_eq!(projection.links[0].destination, "https://example.com");
        assert_eq!(projection.superscript_ranges.len(), 1);
        assert_eq!(projection.subscript_ranges.len(), 1);
        assert_eq!(projection.text, "docs H2O x2");
    }

    #[test]
    fn inline_link_activation_uses_disclosure_keyboard_keys() {
        assert!(is_activation_key("enter"));
        assert!(is_activation_key("space"));
        assert!(!is_activation_key("tab"));
    }
}
