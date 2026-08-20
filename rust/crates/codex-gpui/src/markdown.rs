//! Native rendering for framework-neutral Markdown presentation trees.

use std::ops::Range;

use codex_presentation::{MarkdownAlignment, MarkdownDocument, MarkdownNode, MarkdownQuoteKind};
use gpui::{
    AnyElement, FontStyle, FontWeight, HighlightStyle, Role, StrikethroughStyle, StyledText,
    TextAlign, UnderlineStyle, WeakEntity, div, prelude::*, px,
};

use crate::transcript::{CodexTheme, CodexTranscript, TranscriptEvent};

pub(crate) fn render_markdown(
    document: &MarkdownDocument,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
) -> AnyElement {
    let links = document.links();
    div()
        .id("assistant-markdown")
        .role(Role::Document)
        .aria_label("Assistant response")
        .w_full()
        .flex()
        .flex_col()
        .gap_3()
        .children(
            document
                .blocks
                .iter()
                .map(|block| render_block(&block.node, block.ordinal, theme)),
        )
        .when(!links.is_empty(), |view| {
            view.child(
                div()
                    .id("assistant-markdown-links")
                    .role(Role::List)
                    .aria_label("Links in assistant response")
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(links.into_iter().enumerate().map(|(index, link)| {
                        let event = TranscriptEvent::OpenLink {
                            destination: link.destination,
                            label: link.label.clone(),
                        };
                        let emitter = emitter.clone();
                        div()
                            .id(("assistant-markdown-link", index))
                            .role(Role::Link)
                            .aria_label(format!("Open link {}", link.label))
                            .rounded_lg()
                            .border_1()
                            .border_color(theme.border)
                            .px_2()
                            .py_1()
                            .text_xs()
                            .text_color(theme.accent)
                            .cursor_pointer()
                            .on_click(move |_, _, cx| {
                                emitter.update(cx, |_, cx| cx.emit(event.clone())).ok();
                            })
                            .child(link.label)
                    })),
            )
        })
        .into_any()
}

#[allow(clippy::too_many_lines)]
fn render_block(node: &MarkdownNode, ordinal: usize, theme: CodexTheme) -> AnyElement {
    let id = ("markdown-block", ordinal);
    match node {
        MarkdownNode::Paragraph(children) => div()
            .id(id)
            .whitespace_normal()
            .line_height(px(22.))
            .child(styled_inline(children, theme))
            .into_any(),
        MarkdownNode::Heading { level, children } => div()
            .id(id)
            .role(Role::Heading)
            .aria_level(usize::from(*level))
            .text_size(px(heading_size(*level)))
            .font_weight(FontWeight::SEMIBOLD)
            .whitespace_normal()
            .child(styled_inline(children, theme))
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
                    .map(|(index, child)| render_block(child, index, theme)),
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
            .children(
                children
                    .iter()
                    .enumerate()
                    .map(|(index, child)| render_table_section(child, index, alignments, theme)),
            )
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
        MarkdownNode::Item(_) => render_list_item(node, "•".to_owned(), ordinal, theme),
        MarkdownNode::TableHead(children) | MarkdownNode::TableRow(children) => render_table_row(
            children,
            ordinal,
            matches!(node, MarkdownNode::TableHead(_)),
            &[],
            theme,
        ),
        MarkdownNode::TableCell(children) => div()
            .id(id)
            .flex_1()
            .min_w(px(120.))
            .px_3()
            .py_2()
            .whitespace_normal()
            .child(styled_inline(children, theme))
            .into_any(),
        _ => div()
            .id(id)
            .whitespace_normal()
            .child(styled_inline(std::slice::from_ref(node), theme))
            .into_any(),
    }
}

fn render_list_item(
    item: &MarkdownNode,
    default_marker: String,
    index: usize,
    theme: CodexTheme,
) -> AnyElement {
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
                    .map(|(child_index, child)| render_block(child, child_index, theme)),
            ),
        )
        .into_any()
}

fn render_table_section(
    node: &MarkdownNode,
    index: usize,
    alignments: &[MarkdownAlignment],
    theme: CodexTheme,
) -> AnyElement {
    match node {
        MarkdownNode::TableHead(children) => {
            render_table_row(children, index, true, alignments, theme)
        }
        MarkdownNode::TableRow(children) => {
            render_table_row(children, index, false, alignments, theme)
        }
        _ => render_block(node, index, theme),
    }
}

fn render_table_row(
    children: &[MarkdownNode],
    index: usize,
    heading: bool,
    alignments: &[MarkdownAlignment],
    theme: CodexTheme,
) -> AnyElement {
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
                .child(styled_inline(
                    match cell {
                        MarkdownNode::TableCell(children) => children,
                        _ => std::slice::from_ref(cell),
                    },
                    theme,
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

#[derive(Clone, Copy, Default, Eq, PartialEq)]
struct InlineStyle(u8);

impl InlineStyle {
    const STRONG: u8 = 1 << 0;
    const EMPHASIS: u8 = 1 << 1;
    const STRIKETHROUGH: u8 = 1 << 2;
    const CODE: u8 = 1 << 3;
    const LINK: u8 = 1 << 4;
    const HTML: u8 = 1 << 5;

    const fn with(self, flag: u8) -> Self {
        Self(self.0 | flag)
    }

    const fn has(self, flag: u8) -> bool {
        self.0 & flag != 0
    }
}

struct InlineProjection {
    text: String,
    highlights: Vec<(Range<usize>, InlineStyle)>,
    code_ranges: Vec<Range<usize>>,
}

fn styled_inline(nodes: &[MarkdownNode], theme: CodexTheme) -> StyledText {
    let mut projection = InlineProjection {
        text: String::new(),
        highlights: Vec::new(),
        code_ranges: Vec::new(),
    };
    for node in nodes {
        flatten_inline(node, InlineStyle::default(), &mut projection);
    }
    let highlights = projection.highlights.into_iter().map(|(range, style)| {
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
        (range, highlight)
    });
    StyledText::new(projection.text)
        .with_highlights(highlights)
        .with_font_family_overrides(
            projection
                .code_ranges
                .into_iter()
                .map(|range| (range, "monospace".into())),
        )
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
        MarkdownNode::Link { children, .. } => {
            style = style.with(InlineStyle::LINK);
            flatten_children(children, style, output);
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
        MarkdownNode::Superscript(children)
        | MarkdownNode::Subscript(children)
        | MarkdownNode::Paragraph(children)
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
        let mut projection = InlineProjection {
            text: String::new(),
            highlights: Vec::new(),
            code_ranges: Vec::new(),
        };
        flatten_children(nodes, InlineStyle::default(), &mut projection);
        for (index, (range, _)) in projection.highlights.iter().enumerate() {
            assert!(projection.text.is_char_boundary(range.start));
            assert!(projection.text.is_char_boundary(range.end));
            if index > 0 {
                assert!(projection.highlights[index - 1].0.end <= range.start);
            }
        }
    }
}
