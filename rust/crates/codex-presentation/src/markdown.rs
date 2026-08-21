//! Framework-neutral, non-HTML Markdown projection.

use std::sync::Arc;

use pulldown_cmark::{
    Alignment, BlockQuoteKind, CodeBlockKind, Event, Options, Parser, Tag, TagEnd,
};

/// Parsed Markdown retained by presentation models and reusable UI hosts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkdownDocument {
    /// Exact source. Hosts may offer copy/source actions without reconstructing it.
    pub source: Arc<str>,
    /// Stable top-level block ordinals in source order.
    pub blocks: Vec<MarkdownBlock>,
}

/// One top-level Markdown block.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkdownBlock {
    pub ordinal: usize,
    pub node: MarkdownNode,
}

/// One link preserved from Markdown for an explicit host activation policy.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkdownLink {
    pub destination: String,
    pub label: String,
    pub title: String,
}

/// Safe semantic Markdown tree. Raw HTML remains visible text and is never interpreted.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MarkdownNode {
    Paragraph(Vec<Self>),
    Heading {
        level: u8,
        children: Vec<Self>,
    },
    BlockQuote {
        kind: Option<MarkdownQuoteKind>,
        children: Vec<Self>,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
        complete: bool,
    },
    List {
        start: Option<u64>,
        items: Vec<Self>,
    },
    Item(Vec<Self>),
    Table {
        alignments: Vec<MarkdownAlignment>,
        children: Vec<Self>,
    },
    TableHead(Vec<Self>),
    TableRow(Vec<Self>),
    TableCell(Vec<Self>),
    Strong(Vec<Self>),
    Emphasis(Vec<Self>),
    Strikethrough(Vec<Self>),
    Superscript(Vec<Self>),
    Subscript(Vec<Self>),
    Link {
        destination: String,
        title: String,
        children: Vec<Self>,
    },
    Image {
        source: String,
        title: String,
        alt: Vec<Self>,
    },
    Text(String),
    InlineCode(String),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker {
        checked: bool,
    },
    HtmlFallback(String),
    Group(Vec<Self>),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MarkdownAlignment {
    Unspecified,
    Leading,
    Center,
    Trailing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MarkdownQuoteKind {
    Note,
    Tip,
    Important,
    Warning,
    Caution,
}

impl MarkdownDocument {
    /// Parse `CommonMark` plus the GFM extensions used by Codex transcripts.
    #[must_use]
    pub fn parse(source: &str) -> Self {
        let mut options = Options::empty();
        options.insert(
            Options::ENABLE_TABLES
                | Options::ENABLE_STRIKETHROUGH
                | Options::ENABLE_TASKLISTS
                | Options::ENABLE_GFM,
        );
        let mut roots = Vec::new();
        let mut stack = Vec::new();
        for (event, range) in Parser::new_ext(source, options).into_offset_iter() {
            match event {
                Event::Start(tag) => stack.push(Frame::new(tag, range.start)),
                Event::End(end) => {
                    let Some(frame) = stack.pop() else {
                        continue;
                    };
                    debug_assert_eq!(frame.expected, end);
                    append_node(
                        finish_frame(frame, source, range.end),
                        &mut stack,
                        &mut roots,
                    );
                }
                Event::Text(text) => append_node(
                    MarkdownNode::Text(text.into_string()),
                    &mut stack,
                    &mut roots,
                ),
                Event::Code(code) => append_node(
                    MarkdownNode::InlineCode(code.into_string()),
                    &mut stack,
                    &mut roots,
                ),
                Event::InlineMath(math) | Event::DisplayMath(math) => append_node(
                    MarkdownNode::Text(math.into_string()),
                    &mut stack,
                    &mut roots,
                ),
                Event::Html(html) | Event::InlineHtml(html) => append_node(
                    MarkdownNode::HtmlFallback(html.into_string()),
                    &mut stack,
                    &mut roots,
                ),
                Event::FootnoteReference(label) => append_node(
                    MarkdownNode::Text(format!("[^{label}]")),
                    &mut stack,
                    &mut roots,
                ),
                Event::SoftBreak => {
                    append_node(MarkdownNode::SoftBreak, &mut stack, &mut roots);
                }
                Event::HardBreak => {
                    append_node(MarkdownNode::HardBreak, &mut stack, &mut roots);
                }
                Event::Rule => append_node(MarkdownNode::Rule, &mut stack, &mut roots),
                Event::TaskListMarker(checked) => {
                    append_node(MarkdownNode::TaskMarker { checked }, &mut stack, &mut roots);
                }
            }
        }

        while let Some(frame) = stack.pop() {
            append_node(
                finish_frame(frame, source, source.len()),
                &mut stack,
                &mut roots,
            );
        }
        Self {
            source: Arc::from(source),
            blocks: roots
                .into_iter()
                .enumerate()
                .map(|(ordinal, node)| MarkdownBlock { ordinal, node })
                .collect(),
        }
    }

    /// Collect links without activating them or interpreting their schemes.
    #[must_use]
    pub fn links(&self) -> Vec<MarkdownLink> {
        let mut links = Vec::new();
        for block in &self.blocks {
            collect_links(&block.node, &mut links);
        }
        links
    }
}

impl MarkdownNode {
    /// Plain semantic text for accessibility, copying, and compact fallbacks.
    #[must_use]
    pub fn plain_text(&self) -> String {
        match self {
            Self::Text(text) | Self::InlineCode(text) | Self::HtmlFallback(text) => text.clone(),
            Self::SoftBreak | Self::HardBreak => "\n".to_owned(),
            Self::Rule => "—".to_owned(),
            Self::TaskMarker { checked } => if *checked { "[x] " } else { "[ ] " }.to_owned(),
            Self::CodeBlock { code, .. } => code.clone(),
            Self::Link { children, .. }
            | Self::Paragraph(children)
            | Self::Heading { children, .. }
            | Self::BlockQuote { children, .. }
            | Self::Strong(children)
            | Self::Emphasis(children)
            | Self::Strikethrough(children)
            | Self::Superscript(children)
            | Self::Subscript(children)
            | Self::Table { children, .. }
            | Self::TableHead(children)
            | Self::TableRow(children)
            | Self::TableCell(children)
            | Self::Item(children)
            | Self::Group(children) => join_plain(children),
            Self::List { items, .. } => items
                .iter()
                .map(Self::plain_text)
                .collect::<Vec<_>>()
                .join("\n"),
            Self::Image { alt, .. } => format!("Image: {}", join_plain(alt)),
        }
    }
}

fn join_plain(children: &[MarkdownNode]) -> String {
    children.iter().map(MarkdownNode::plain_text).collect()
}

fn collect_links(node: &MarkdownNode, links: &mut Vec<MarkdownLink>) {
    let children = match node {
        MarkdownNode::Link {
            destination,
            title,
            children,
        } => {
            links.push(MarkdownLink {
                destination: destination.clone(),
                label: join_plain(children),
                title: title.clone(),
            });
            children.as_slice()
        }
        MarkdownNode::Paragraph(children)
        | MarkdownNode::Heading { children, .. }
        | MarkdownNode::BlockQuote { children, .. }
        | MarkdownNode::Item(children)
        | MarkdownNode::Table { children, .. }
        | MarkdownNode::TableHead(children)
        | MarkdownNode::TableRow(children)
        | MarkdownNode::TableCell(children)
        | MarkdownNode::Strong(children)
        | MarkdownNode::Emphasis(children)
        | MarkdownNode::Strikethrough(children)
        | MarkdownNode::Superscript(children)
        | MarkdownNode::Subscript(children)
        | MarkdownNode::Group(children) => children.as_slice(),
        MarkdownNode::List { items, .. } => items.as_slice(),
        MarkdownNode::Image { alt, .. } => alt.as_slice(),
        MarkdownNode::CodeBlock { .. }
        | MarkdownNode::Text(_)
        | MarkdownNode::InlineCode(_)
        | MarkdownNode::SoftBreak
        | MarkdownNode::HardBreak
        | MarkdownNode::Rule
        | MarkdownNode::TaskMarker { .. }
        | MarkdownNode::HtmlFallback(_) => return,
    };
    for child in children {
        collect_links(child, links);
    }
}

struct Frame {
    expected: TagEnd,
    kind: FrameKind,
    children: Vec<MarkdownNode>,
    source_start: usize,
}

enum FrameKind {
    Paragraph,
    Heading(u8),
    BlockQuote(Option<MarkdownQuoteKind>),
    CodeBlock {
        language: Option<String>,
        fenced: bool,
    },
    HtmlBlock,
    List(Option<u64>),
    Item,
    Table(Vec<MarkdownAlignment>),
    TableHead,
    TableRow,
    TableCell,
    Strong,
    Emphasis,
    Strikethrough,
    Superscript,
    Subscript,
    Link {
        destination: String,
        title: String,
    },
    Image {
        source: String,
        title: String,
    },
    Group,
}

impl Frame {
    fn new(tag: Tag<'_>, source_start: usize) -> Self {
        let expected = tag.to_end();
        let kind = match tag {
            Tag::Paragraph => FrameKind::Paragraph,
            Tag::Heading { level, .. } => FrameKind::Heading(level as u8),
            Tag::BlockQuote(kind) => FrameKind::BlockQuote(kind.map(map_quote_kind)),
            Tag::CodeBlock(kind) => match kind {
                CodeBlockKind::Indented => FrameKind::CodeBlock {
                    language: None,
                    fenced: false,
                },
                CodeBlockKind::Fenced(info) => FrameKind::CodeBlock {
                    language: info
                        .split_whitespace()
                        .next()
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned),
                    fenced: true,
                },
            },
            Tag::HtmlBlock => FrameKind::HtmlBlock,
            Tag::List(start) => FrameKind::List(start),
            Tag::Item => FrameKind::Item,
            Tag::Table(alignments) => {
                FrameKind::Table(alignments.into_iter().map(map_alignment).collect())
            }
            Tag::TableHead => FrameKind::TableHead,
            Tag::TableRow => FrameKind::TableRow,
            Tag::TableCell => FrameKind::TableCell,
            Tag::Strong => FrameKind::Strong,
            Tag::Emphasis => FrameKind::Emphasis,
            Tag::Strikethrough => FrameKind::Strikethrough,
            Tag::Superscript => FrameKind::Superscript,
            Tag::Subscript => FrameKind::Subscript,
            Tag::Link {
                dest_url, title, ..
            } => FrameKind::Link {
                destination: dest_url.into_string(),
                title: title.into_string(),
            },
            Tag::Image {
                dest_url, title, ..
            } => FrameKind::Image {
                source: dest_url.into_string(),
                title: title.into_string(),
            },
            Tag::FootnoteDefinition(_)
            | Tag::DefinitionList
            | Tag::DefinitionListTitle
            | Tag::DefinitionListDefinition
            | Tag::MetadataBlock(_) => FrameKind::Group,
        };
        Self {
            expected,
            kind,
            children: Vec::new(),
            source_start,
        }
    }
}

fn append_node(node: MarkdownNode, stack: &mut [Frame], roots: &mut Vec<MarkdownNode>) {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(node);
    } else {
        roots.push(node);
    }
}

fn finish_frame(frame: Frame, source: &str, source_end: usize) -> MarkdownNode {
    let children = frame.children;
    match frame.kind {
        FrameKind::Paragraph => MarkdownNode::Paragraph(children),
        FrameKind::Heading(level) => MarkdownNode::Heading { level, children },
        FrameKind::BlockQuote(kind) => MarkdownNode::BlockQuote { kind, children },
        FrameKind::CodeBlock { language, fenced } => MarkdownNode::CodeBlock {
            language,
            code: join_plain(&children),
            complete: !fenced
                || fenced_code_complete(
                    source
                        .get(frame.source_start..source_end)
                        .unwrap_or_default(),
                ),
        },
        FrameKind::HtmlBlock => MarkdownNode::HtmlFallback(join_plain(&children)),
        FrameKind::List(start) => MarkdownNode::List {
            start,
            items: children,
        },
        FrameKind::Item => MarkdownNode::Item(children),
        FrameKind::Table(alignments) => MarkdownNode::Table {
            alignments,
            children,
        },
        FrameKind::TableHead => MarkdownNode::TableHead(children),
        FrameKind::TableRow => MarkdownNode::TableRow(children),
        FrameKind::TableCell => MarkdownNode::TableCell(children),
        FrameKind::Strong => MarkdownNode::Strong(children),
        FrameKind::Emphasis => MarkdownNode::Emphasis(children),
        FrameKind::Strikethrough => MarkdownNode::Strikethrough(children),
        FrameKind::Superscript => MarkdownNode::Superscript(children),
        FrameKind::Subscript => MarkdownNode::Subscript(children),
        FrameKind::Link { destination, title } => MarkdownNode::Link {
            destination,
            title,
            children,
        },
        FrameKind::Image { source, title } => MarkdownNode::Image {
            source,
            title,
            alt: children,
        },
        FrameKind::Group => MarkdownNode::Group(children),
    }
}

fn map_alignment(alignment: Alignment) -> MarkdownAlignment {
    match alignment {
        Alignment::None => MarkdownAlignment::Unspecified,
        Alignment::Left => MarkdownAlignment::Leading,
        Alignment::Center => MarkdownAlignment::Center,
        Alignment::Right => MarkdownAlignment::Trailing,
    }
}

const fn map_quote_kind(kind: BlockQuoteKind) -> MarkdownQuoteKind {
    match kind {
        BlockQuoteKind::Note => MarkdownQuoteKind::Note,
        BlockQuoteKind::Tip => MarkdownQuoteKind::Tip,
        BlockQuoteKind::Important => MarkdownQuoteKind::Important,
        BlockQuoteKind::Warning => MarkdownQuoteKind::Warning,
        BlockQuoteKind::Caution => MarkdownQuoteKind::Caution,
    }
}

fn fenced_code_complete(source: &str) -> bool {
    let mut lines = source.lines();
    let Some(opening) = lines.next().map(str::trim_start) else {
        return false;
    };
    let Some(fence_character) = opening.chars().next().filter(|c| matches!(c, '`' | '~')) else {
        return false;
    };
    let opening_length = opening
        .chars()
        .take_while(|character| *character == fence_character)
        .count();
    if opening_length < 3 {
        return false;
    }
    lines.any(|line| {
        let trimmed = line.trim();
        let length = trimmed
            .chars()
            .take_while(|character| *character == fence_character)
            .count();
        length >= opening_length && trimmed.chars().skip(length).all(char::is_whitespace)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_rich_blocks_without_interpreting_html() {
        let document =
            MarkdownDocument::parse("# Heading\n\n> quoted **text**\n\n---\n\n<div>raw</div>");
        assert_eq!(document.blocks.len(), 4);
        assert!(matches!(
            document.blocks[0].node,
            MarkdownNode::Heading { level: 1, .. }
        ));
        assert!(matches!(
            document.blocks[1].node,
            MarkdownNode::BlockQuote { .. }
        ));
        assert!(matches!(document.blocks[2].node, MarkdownNode::Rule));
        assert_eq!(
            document.blocks[3].node,
            MarkdownNode::HtmlFallback("<div>raw</div>".to_owned())
        );
    }

    #[test]
    fn preserves_links_tables_and_nested_task_lists() {
        let document = MarkdownDocument::parse(
            "Read [docs](https://example.com).\n\n- [ ] parent\n  - [x] child\n\n| A | B |\n| :- | -: |\n| x | y |",
        );
        let debug = format!("{document:?}");
        assert!(debug.contains("https://example.com"));
        assert!(debug.contains("checked: false"));
        assert!(debug.contains("checked: true"));
        assert!(debug.contains("Leading"));
        assert!(debug.contains("Trailing"));
        assert_eq!(
            document.links(),
            vec![MarkdownLink {
                destination: "https://example.com".to_owned(),
                label: "docs".to_owned(),
                title: String::new(),
            }]
        );
    }

    #[test]
    fn distinguishes_streaming_and_complete_fences() {
        let streaming = MarkdownDocument::parse("```rust\nlet value = 1;");
        assert!(matches!(
            streaming.blocks[0].node,
            MarkdownNode::CodeBlock {
                complete: false,
                ..
            }
        ));
        let complete = MarkdownDocument::parse("```rust\nlet value = 1;\n```");
        assert!(matches!(
            complete.blocks[0].node,
            MarkdownNode::CodeBlock { complete: true, .. }
        ));
    }
}
