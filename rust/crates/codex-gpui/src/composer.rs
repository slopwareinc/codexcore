use std::ops::Range;

use gpui::{
    App, Bounds, ClipboardItem, Context, CursorStyle, Element, ElementId, ElementInputHandler,
    Entity, EntityInputHandler, EventEmitter, FocusHandle, Focusable, GlobalElementId,
    InspectorElementId, KeyBinding, LayoutId, MouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, PaintQuad, Pixels, Point, Render, Role, ShapedLine, SharedString, Style, TextRun,
    UTF16Selection, UnderlineStyle, Window, actions, div, fill, point, prelude::*, px, relative,
    size,
};
use unicode_segmentation::UnicodeSegmentation;

use crate::CodexTheme;

const MAXIMUM_DRAFT_BYTES: usize = 256 * 1_024;
const MAXIMUM_INPUT_LINES: usize = 6;

actions!(
    codex_composer,
    [
        Backspace,
        Delete,
        Left,
        Right,
        SelectLeft,
        SelectRight,
        SelectAll,
        Home,
        End,
        Paste,
        Cut,
        Copy,
        Submit,
        Steer,
    ]
);

/// Install composer key bindings into one GPUI application.
pub fn init(cx: &mut App) {
    let context = Some("CodexComposerInput");
    cx.bind_keys([
        KeyBinding::new("backspace", Backspace, context),
        KeyBinding::new("delete", Delete, context),
        KeyBinding::new("left", Left, context),
        KeyBinding::new("right", Right, context),
        KeyBinding::new("shift-left", SelectLeft, context),
        KeyBinding::new("shift-right", SelectRight, context),
        KeyBinding::new("cmd-a", SelectAll, context),
        KeyBinding::new("ctrl-a", SelectAll, context),
        KeyBinding::new("cmd-v", Paste, context),
        KeyBinding::new("ctrl-v", Paste, context),
        KeyBinding::new("cmd-c", Copy, context),
        KeyBinding::new("ctrl-c", Copy, context),
        KeyBinding::new("cmd-x", Cut, context),
        KeyBinding::new("ctrl-x", Cut, context),
        KeyBinding::new("home", Home, context),
        KeyBinding::new("end", End, context),
        // Plain Enter is intentionally left to GPUI's native input handler so
        // it inserts a newline. Command/Ctrl+Enter remains the explicit send
        // gesture, and Command/Ctrl+Shift+Enter steers an active turn.
        KeyBinding::new("cmd-enter", Submit, context),
        KeyBinding::new("ctrl-enter", Submit, context),
        KeyBinding::new("cmd-shift-enter", Steer, context),
        KeyBinding::new("ctrl-shift-enter", Steer, context),
    ]);
}

/// Composer submission routed to the host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActiveSubmitBehavior {
    Queue,
    Steer,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ComposerEvent {
    Submit {
        text: String,
        active_behavior: ActiveSubmitBehavior,
    },
    Interrupt,
    OpenModelPicker,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ComposerControl {
    Send,
    Stop,
}

fn composer_control_order(turn_active: bool) -> &'static [ComposerControl] {
    if turn_active {
        &[ComposerControl::Send, ComposerControl::Stop]
    } else {
        &[ComposerControl::Send]
    }
}

fn model_control_event() -> ComposerEvent {
    ComposerEvent::OpenModelPicker
}

pub(crate) enum InputEvent {
    Submit,
    Changed,
}

pub(crate) struct SteerInputEvent;

#[derive(Clone)]
struct InputLineLayout {
    range: Range<usize>,
    line: ShapedLine,
}

#[derive(Clone, Default)]
struct InputLayout {
    lines: Vec<InputLineLayout>,
}

pub(crate) struct ComposerInput {
    focus_handle: FocusHandle,
    content: SharedString,
    placeholder: SharedString,
    accessibility_label: SharedString,
    selected_range: Range<usize>,
    selection_reversed: bool,
    marked_range: Option<Range<usize>>,
    last_layout: Option<InputLayout>,
    last_bounds: Option<Bounds<Pixels>>,
    last_line_height: Pixels,
    is_selecting: bool,
    theme: CodexTheme,
    secret: bool,
}

impl ComposerInput {
    pub(crate) fn new(
        placeholder: SharedString,
        theme: CodexTheme,
        secret: bool,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            focus_handle: cx.focus_handle(),
            content: SharedString::default(),
            placeholder,
            accessibility_label: "Message Codex".into(),
            selected_range: 0..0,
            selection_reversed: false,
            marked_range: None,
            last_layout: None,
            last_bounds: None,
            last_line_height: px(20.),
            is_selecting: false,
            theme,
            secret,
        }
    }

    pub(crate) fn text(&self) -> &str {
        &self.content
    }

    pub(crate) fn with_accessibility_label(
        mut self,
        accessibility_label: impl Into<SharedString>,
    ) -> Self {
        self.accessibility_label = accessibility_label.into();
        self
    }

    pub(crate) fn set_theme(&mut self, theme: CodexTheme, cx: &mut Context<Self>) {
        self.theme = theme;
        cx.notify();
    }

    pub(crate) fn set_text(&mut self, text: &str, cx: &mut Context<Self>) {
        let text = bounded_replacement(text, MAXIMUM_DRAFT_BYTES);
        self.content = text.into();
        self.selected_range = self.content.len()..self.content.len();
        self.marked_range = None;
        cx.emit(InputEvent::Changed);
        cx.notify();
    }

    pub(crate) fn reset(&mut self, cx: &mut Context<Self>) {
        self.set_text("", cx);
    }

    fn left(&mut self, _: &Left, _: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            self.move_to(self.previous_boundary(self.cursor_offset()), cx);
        } else {
            self.move_to(self.selected_range.start, cx);
        }
    }

    fn right(&mut self, _: &Right, _: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            self.move_to(self.next_boundary(self.cursor_offset()), cx);
        } else {
            self.move_to(self.selected_range.end, cx);
        }
    }

    fn select_left(&mut self, _: &SelectLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.previous_boundary(self.cursor_offset()), cx);
    }

    fn select_right(&mut self, _: &SelectRight, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.next_boundary(self.cursor_offset()), cx);
    }

    fn select_all(&mut self, _: &SelectAll, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(0, cx);
        self.select_to(self.content.len(), cx);
    }

    fn home(&mut self, _: &Home, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(0, cx);
    }

    fn end(&mut self, _: &End, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(self.content.len(), cx);
    }

    fn backspace(&mut self, _: &Backspace, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            let previous = self.previous_boundary(self.cursor_offset());
            if self.cursor_offset() == previous {
                window.play_system_bell();
                return;
            }
            self.select_to(previous, cx);
        }
        self.replace_text_in_range(None, "", window, cx);
    }

    fn delete(&mut self, _: &Delete, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            let next = self.next_boundary(self.cursor_offset());
            if self.cursor_offset() == next {
                window.play_system_bell();
                return;
            }
            self.select_to(next, cx);
        }
        self.replace_text_in_range(None, "", window, cx);
    }

    fn paste(&mut self, _: &Paste, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
            self.replace_text_in_range(None, &text, window, cx);
        }
    }

    fn copy(&mut self, _: &Copy, _: &mut Window, cx: &mut Context<Self>) {
        if !self.selected_range.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(
                self.content[self.selected_range.clone()].to_owned(),
            ));
        }
    }

    fn cut(&mut self, _: &Cut, window: &mut Window, cx: &mut Context<Self>) {
        self.copy(&Copy, window, cx);
        if !self.selected_range.is_empty() {
            self.replace_text_in_range(None, "", window, cx);
        }
    }

    fn submit(&mut self, _: &Submit, _: &mut Window, cx: &mut Context<Self>) {
        if !self.content.trim().is_empty() {
            cx.emit(InputEvent::Submit);
        }
    }

    fn steer(&mut self, _: &Steer, _: &mut Window, cx: &mut Context<Self>) {
        if !self.content.trim().is_empty() {
            cx.emit(SteerInputEvent);
        }
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        self.is_selecting = true;
        let index = self.index_for_mouse_position(event.position);
        if event.modifiers.shift {
            self.select_to(index, cx);
        } else {
            self.move_to(index, cx);
        }
    }

    fn on_mouse_up(&mut self, _: &MouseUpEvent, _: &mut Window, _: &mut Context<Self>) {
        self.is_selecting = false;
    }

    fn on_mouse_move(&mut self, event: &MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.is_selecting {
            self.select_to(self.index_for_mouse_position(event.position), cx);
        }
    }

    fn move_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        self.selected_range = offset..offset;
        self.selection_reversed = false;
        cx.notify();
    }

    fn select_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        if self.selection_reversed {
            self.selected_range.start = offset;
        } else {
            self.selected_range.end = offset;
        }
        if self.selected_range.end < self.selected_range.start {
            self.selection_reversed = !self.selection_reversed;
            self.selected_range = self.selected_range.end..self.selected_range.start;
        }
        cx.notify();
    }

    fn cursor_offset(&self) -> usize {
        if self.selection_reversed {
            self.selected_range.start
        } else {
            self.selected_range.end
        }
    }

    fn previous_boundary(&self, offset: usize) -> usize {
        self.content
            .grapheme_indices(true)
            .rev()
            .find_map(|(index, _)| (index < offset).then_some(index))
            .unwrap_or(0)
    }

    fn next_boundary(&self, offset: usize) -> usize {
        self.content
            .grapheme_indices(true)
            .find_map(|(index, _)| (index > offset).then_some(index))
            .unwrap_or(self.content.len())
    }

    fn index_for_mouse_position(&self, position: Point<Pixels>) -> usize {
        if self.content.is_empty() {
            return 0;
        }
        let (Some(bounds), Some(line)) = (self.last_bounds.as_ref(), self.last_layout.as_ref())
        else {
            return 0;
        };
        if position.y < bounds.top() {
            return 0;
        }
        if position.y > bounds.bottom() {
            return self.content.len();
        }
        let line_index = line_index_for_position(position.y, bounds.top(), self.last_line_height);
        let Some(line) = line
            .lines
            .get(line_index.min(line.lines.len().saturating_sub(1)))
        else {
            return self.content.len();
        };
        line.range.start
            + line
                .line
                .closest_index_for_x(position.x - bounds.left())
                .min(line.range.len())
    }

    fn offset_from_utf16(&self, offset: usize) -> usize {
        offset_from_utf16(&self.content, offset)
    }

    fn offset_to_utf16(&self, offset: usize) -> usize {
        offset_to_utf16(&self.content, offset)
    }

    fn range_to_utf16(&self, range: &Range<usize>) -> Range<usize> {
        self.offset_to_utf16(range.start)..self.offset_to_utf16(range.end)
    }

    fn range_from_utf16(&self, range: &Range<usize>) -> Range<usize> {
        self.offset_from_utf16(range.start)..self.offset_from_utf16(range.end)
    }
}

impl EventEmitter<InputEvent> for ComposerInput {}
impl EventEmitter<SteerInputEvent> for ComposerInput {}

impl EntityInputHandler for ComposerInput {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        actual_range: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let range = self.range_from_utf16(&range);
        actual_range.replace(self.range_to_utf16(&range));
        Some(self.content[range].to_owned())
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: self.range_to_utf16(&self.selected_range),
            reversed: self.selection_reversed,
        })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked_range
            .as_ref()
            .map(|range| self.range_to_utf16(range))
    }

    fn unmark_text(&mut self, _: &mut Window, _: &mut Context<Self>) {
        self.marked_range = None;
    }

    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        new_text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let range = range
            .as_ref()
            .map(|range| self.range_from_utf16(range))
            .or(self.marked_range.clone())
            .unwrap_or_else(|| self.selected_range.clone());
        let available = MAXIMUM_DRAFT_BYTES.saturating_sub(self.content.len() - range.len());
        let replacement = bounded_replacement(new_text, available);
        self.content = format!(
            "{}{}{}",
            &self.content[..range.start],
            replacement,
            &self.content[range.end..]
        )
        .into();
        let cursor = range.start + replacement.len();
        self.selected_range = cursor..cursor;
        self.selection_reversed = false;
        self.marked_range = None;
        cx.emit(InputEvent::Changed);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        new_text: &str,
        selected_range: Option<Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let start = range
            .as_ref()
            .map(|range| self.range_from_utf16(range).start)
            .or_else(|| self.marked_range.as_ref().map(|range| range.start))
            .unwrap_or(self.selected_range.start);
        self.replace_text_in_range(range, new_text, window, cx);
        let inserted_end = self.selected_range.end;
        self.marked_range = (inserted_end > start).then_some(start..inserted_end);
        if let Some(selected) = selected_range {
            let inserted = &self.content[start..inserted_end];
            self.selected_range = start + offset_from_utf16(inserted, selected.start)
                ..start + offset_from_utf16(inserted, selected.end);
        }
    }

    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        bounds: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let layout = self.last_layout.as_ref()?;
        let range = self.range_from_utf16(&range);
        let start = input_position_for_offset(layout, range.start, self.last_line_height);
        let end = input_position_for_offset(layout, range.end, self.last_line_height);
        Some(Bounds::from_corners(
            point(bounds.left() + start.x, bounds.top() + start.y),
            point(
                bounds.left() + end.x,
                bounds.top() + end.y + self.last_line_height,
            ),
        ))
    }

    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        let bounds = self.last_bounds?;
        let layout = self.last_layout.as_ref()?;
        if point.y < bounds.top() {
            return Some(0);
        }
        if point.y > bounds.bottom() {
            return Some(self.offset_to_utf16(self.content.len()));
        }
        let line_index = line_index_for_position(point.y, bounds.top(), self.last_line_height);
        let line = layout
            .lines
            .get(line_index.min(layout.lines.len().saturating_sub(1)))?;
        let index = line
            .line
            .closest_index_for_x(point.x - bounds.left())
            .min(line.range.len());
        Some(self.offset_to_utf16(line.range.start + index))
    }
}

fn input_position_for_offset(
    layout: &InputLayout,
    offset: usize,
    line_height: Pixels,
) -> Point<Pixels> {
    let line_index = line_index_for_offset(layout, offset);
    let line = &layout.lines[line_index];
    point(
        line.line.x_for_index(
            offset
                .saturating_sub(line.range.start)
                .min(line.range.len()),
        ),
        line_y(line_height, line_index),
    )
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn line_index_for_position(y: Pixels, top: Pixels, line_height: Pixels) -> usize {
    (((y - top) / line_height).floor()).max(0.) as usize
}

fn line_y(line_height: Pixels, line_index: usize) -> Pixels {
    line_height * f32::from(u16::try_from(line_index).unwrap_or(u16::MAX))
}

fn line_index_for_offset(layout: &InputLayout, offset: usize) -> usize {
    layout
        .lines
        .iter()
        .enumerate()
        .find_map(|(index, line)| (offset <= line.range.end).then_some(index))
        .unwrap_or_else(|| layout.lines.len().saturating_sub(1))
}

impl Focusable for ComposerInput {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for ComposerInput {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let input_height = composer_input_height(&self.content, window.line_height());
        div()
            .id("codex-composer-input")
            .key_context("CodexComposerInput")
            .track_focus(&self.focus_handle)
            .role(if self.secret {
                Role::PasswordInput
            } else {
                Role::TextInput
            })
            .aria_label(self.accessibility_label.clone())
            .aria_placeholder(self.placeholder.clone())
            .aria_value(if self.secret {
                masked_text(&self.content).into()
            } else {
                self.content.clone()
            })
            .cursor(CursorStyle::IBeam)
            .on_action(cx.listener(Self::backspace))
            .on_action(cx.listener(Self::delete))
            .on_action(cx.listener(Self::left))
            .on_action(cx.listener(Self::right))
            .on_action(cx.listener(Self::select_left))
            .on_action(cx.listener(Self::select_right))
            .on_action(cx.listener(Self::select_all))
            .on_action(cx.listener(Self::home))
            .on_action(cx.listener(Self::end))
            .on_action(cx.listener(Self::paste))
            .on_action(cx.listener(Self::cut))
            .on_action(cx.listener(Self::copy))
            .on_action(cx.listener(Self::submit))
            .on_action(cx.listener(Self::steer))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .h(input_height)
            .min_h(px(36.))
            .w_full()
            .overflow_hidden()
            .px_2()
            .py_1()
            .flex()
            .items_start()
            .child(InputTextElement { input: cx.entity() })
    }
}

struct InputTextElement {
    input: Entity<ComposerInput>,
}

struct InputPrepaint {
    layout: InputLayout,
    cursor: Option<PaintQuad>,
    selections: Vec<PaintQuad>,
}

impl IntoElement for InputTextElement {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for InputTextElement {
    type RequestLayoutState = ();
    type PrepaintState = InputPrepaint;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let input = self.input.read(cx);
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = composer_input_height(&input.content, window.line_height()).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        (): &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let input = self.input.read(cx);
        let content = input.content.clone();
        let selected = input.selected_range.clone();
        let cursor_index = input.cursor_offset();
        let theme = input.theme;
        let text_style = window.text_style();
        let (display, color) = if content.is_empty() {
            (input.placeholder.clone(), theme.muted_text.into())
        } else if input.secret {
            (masked_text(&content).into(), text_style.color)
        } else {
            (content, text_style.color)
        };
        let font_size = text_style.font_size.to_pixels(window.rem_size());
        let base_run = TextRun {
            len: display.len(),
            font: text_style.font(),
            color,
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        let mut layout = InputLayout::default();
        for range in input_line_ranges(&display) {
            let line_text: SharedString = display[range.clone()].into();
            let marked = input
                .marked_range
                .as_ref()
                .and_then(|marked| intersect_ranges(marked, &range));
            let runs = marked_runs_for_line(&base_run, range.clone(), marked.as_ref());
            let line = window
                .text_system()
                .shape_line(line_text, font_size, &runs, None);
            layout.lines.push(InputLineLayout { range, line });
        }

        let cursor = if selected.is_empty() {
            let cursor_position =
                input_position_for_offset(&layout, cursor_index, window.line_height());
            Some(fill(
                Bounds::new(
                    point(
                        bounds.left() + cursor_position.x,
                        bounds.top() + cursor_position.y,
                    ),
                    size(px(2.), window.line_height()),
                ),
                theme.accent,
            ))
        } else {
            None
        };
        let selections = selection_quads(
            &layout,
            &selected,
            bounds.origin,
            window.line_height(),
            theme.accent.opacity(0.25),
        );
        InputPrepaint {
            layout,
            cursor,
            selections,
        }
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        (): &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let focus = self.input.read(cx).focus_handle.clone();
        window.handle_input(
            &focus,
            ElementInputHandler::new(bounds, self.input.clone()),
            cx,
        );
        for selection in prepaint.selections.drain(..) {
            window.paint_quad(selection);
        }
        for (index, line) in prepaint.layout.lines.iter().enumerate() {
            line.line
                .paint(
                    point(
                        bounds.left(),
                        bounds.top() + line_y(window.line_height(), index),
                    ),
                    window.line_height(),
                    gpui::TextAlign::Left,
                    None,
                    window,
                    cx,
                )
                .expect("paint composer text");
        }
        if focus.is_focused(window)
            && let Some(cursor) = prepaint.cursor.take()
        {
            window.paint_quad(cursor);
        }
        self.input.update(cx, |input, _| {
            input.last_layout = Some(prepaint.layout.clone());
            input.last_bounds = Some(bounds);
            input.last_line_height = window.line_height();
        });
    }
}

fn input_line_ranges(text: &str) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0;
    for (index, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            ranges.push(start..index);
            start = index + 1;
        }
    }
    ranges.push(start..text.len());
    ranges
}

fn intersect_ranges(left: &Range<usize>, right: &Range<usize>) -> Option<Range<usize>> {
    let start = left.start.max(right.start);
    let end = left.end.min(right.end);
    (start < end).then_some(start..end)
}

fn marked_runs_for_line(
    base: &TextRun,
    line_range: Range<usize>,
    marked: Option<&Range<usize>>,
) -> Vec<TextRun> {
    let base = TextRun {
        len: line_range.len(),
        ..base.clone()
    };
    let Some(marked) = marked else {
        return vec![base];
    };
    let marked = marked.start - line_range.start..marked.end - line_range.start;
    [
        TextRun {
            len: marked.start,
            ..base.clone()
        },
        TextRun {
            len: marked.end - marked.start,
            underline: Some(UnderlineStyle {
                color: Some(base.color),
                thickness: px(1.),
                wavy: false,
            }),
            ..base.clone()
        },
        TextRun {
            len: line_range.len() - marked.end,
            ..base.clone()
        },
    ]
    .into_iter()
    .filter(|run| run.len > 0)
    .collect()
}

fn selection_quads(
    layout: &InputLayout,
    selected: &Range<usize>,
    origin: Point<Pixels>,
    line_height: Pixels,
    color: gpui::Rgba,
) -> Vec<PaintQuad> {
    if selected.is_empty() {
        return Vec::new();
    }
    layout
        .lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| {
            let start = selected.start.max(line.range.start).min(line.range.end);
            let end = selected.end.min(line.range.end);
            if start >= end {
                return None;
            }
            let left = line.line.x_for_index(start - line.range.start);
            let right = line
                .line
                .x_for_index(end - line.range.start)
                .max(left + px(2.));
            Some(fill(
                Bounds::new(
                    point(origin.x + left, origin.y + line_y(line_height, index)),
                    size(right - left, line_height),
                ),
                color,
            ))
        })
        .collect()
}

fn masked_text(value: &str) -> String {
    value
        .bytes()
        .map(|byte| if byte == b'\n' { '\n' } else { '*' })
        .collect()
}

fn composer_input_height(content: &str, line_height: Pixels) -> Pixels {
    let line_count = content
        .bytes()
        .filter(|byte| *byte == b'\n')
        .count()
        .saturating_add(1)
        .min(MAXIMUM_INPUT_LINES);
    px(36.)
        + line_height * f32::from(u16::try_from(line_count.saturating_sub(1)).unwrap_or(u16::MAX))
}

/// Controlled multiline composer with native IME and clipboard behavior.
pub struct CodexComposer {
    input: Entity<ComposerInput>,
    theme: CodexTheme,
    model_label: SharedString,
    turn_active: bool,
    queue_enabled: bool,
    active_submit_behavior: ActiveSubmitBehavior,
    _input_subscription: gpui::Subscription,
    _steer_subscription: gpui::Subscription,
}

impl CodexComposer {
    #[must_use]
    pub fn new(cx: &mut Context<Self>) -> Self {
        let theme = CodexTheme::default();
        let input = cx.new(|cx| ComposerInput::new("Message Codex…".into(), theme, false, cx));
        let subscription = cx.subscribe(&input, |this, _, event: &InputEvent, cx| match event {
            InputEvent::Submit => this.submit(cx),
            InputEvent::Changed => {}
        });
        let steer_subscription = cx.subscribe(&input, |this, _, _: &SteerInputEvent, cx| {
            this.submit_with_behavior(ActiveSubmitBehavior::Steer, cx);
        });
        Self {
            input,
            theme,
            model_label: "Model".into(),
            turn_active: false,
            queue_enabled: true,
            active_submit_behavior: ActiveSubmitBehavior::Queue,
            _input_subscription: subscription,
            _steer_subscription: steer_subscription,
        }
    }

    #[must_use]
    pub fn with_theme(mut self, theme: CodexTheme, cx: &mut Context<Self>) -> Self {
        self.theme = theme;
        self.input.update(cx, |input, cx| {
            input.theme = theme;
            cx.notify();
        });
        self
    }

    #[must_use]
    pub fn text(&self, cx: &App) -> String {
        self.input.read(cx).text().to_owned()
    }

    pub fn set_text(&mut self, text: &str, cx: &mut Context<Self>) {
        self.input.update(cx, |input, cx| input.set_text(text, cx));
    }

    pub fn set_turn_active(&mut self, active: bool, cx: &mut Context<Self>) {
        if self.turn_active != active {
            self.turn_active = active;
            cx.notify();
        }
    }

    /// Update the compact model label shown in the composer control row.
    pub fn set_model_label(&mut self, label: impl Into<SharedString>, cx: &mut Context<Self>) {
        let label = label.into();
        if self.model_label != label {
            self.model_label = label;
            cx.notify();
        }
    }

    /// Enable durable queue controls while a turn is active.
    ///
    /// Ephemeral App Server threads do not support durable queued submissions,
    /// so hosts should disable this capability for those threads.
    pub fn set_queue_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if self.queue_enabled != enabled {
            self.queue_enabled = enabled;
            if !enabled {
                self.active_submit_behavior = ActiveSubmitBehavior::Steer;
            }
            cx.notify();
        }
    }

    #[must_use]
    pub fn input_focus_handle(&self, cx: &App) -> FocusHandle {
        self.input.read(cx).focus_handle.clone()
    }

    fn submit(&mut self, cx: &mut Context<Self>) {
        self.submit_with_behavior(self.active_submit_behavior, cx);
    }

    fn submit_with_behavior(
        &mut self,
        active_behavior: ActiveSubmitBehavior,
        cx: &mut Context<Self>,
    ) {
        let text = self.input.read(cx).text().trim().to_owned();
        if text.is_empty() {
            return;
        }
        self.input.update(cx, ComposerInput::reset);
        cx.emit(ComposerEvent::Submit {
            text,
            active_behavior,
        });
    }

    fn interrupt(&mut self, cx: &mut Context<Self>) {
        if self.turn_active {
            cx.emit(ComposerEvent::Interrupt);
        }
    }
}

impl EventEmitter<ComposerEvent> for CodexComposer {}

impl Render for CodexComposer {
    #[allow(clippy::too_many_lines)]
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let can_submit = !self.input.read(cx).text().trim().is_empty();
        let theme = self.theme;
        let model_label = self.model_label.clone();
        let show_interrupt =
            composer_control_order(self.turn_active).contains(&ComposerControl::Stop);
        let submit_accessibility_label = if self.turn_active && self.queue_enabled {
            "Send message; Command/Ctrl+Shift+Enter steers the active turn"
        } else {
            "Send message"
        };
        div()
            .id("codex-composer")
            .role(Role::Form)
            .aria_label("Codex message composer")
            .w_full()
            .text_size(px(crate::TranscriptLayoutMetrics::CHAT_TEXT_SIZE))
            .flex()
            .flex_col()
            .gap_2()
            .rounded(px(16.))
            .border_1()
            .border_color(theme.border)
            .bg(theme.elevated_surface)
            .p(px(10.))
            .child(
                div()
                    .min_h(px(34.))
                    .flex()
                    .items_center()
                    .px_1()
                    .child(div().flex_1().overflow_hidden().child(self.input.clone())),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("codex-composer-model")
                            .focusable()
                            .tab_stop(true)
                            .role(Role::Button)
                            .aria_label("Choose model")
                            .h(px(28.))
                            .max_w(px(240.))
                            .px_1()
                            .flex()
                            .items_center()
                            .gap_1()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .cursor_pointer()
                            .on_click(cx.listener(|_, _, _, cx| {
                                cx.emit(model_control_event());
                            }))
                            .child(model_label)
                            .child("⌄"),
                    )
                    .child(
                        div()
                            .id("codex-composer-submit")
                            .focusable()
                            .tab_stop(true)
                            .role(Role::Button)
                            .aria_label(submit_accessibility_label)
                            .size(px(32.))
                            .rounded_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .bg(if can_submit {
                                theme.accent
                            } else {
                                theme.surface
                            })
                            .text_color(if can_submit {
                                theme.background
                            } else {
                                theme.muted_text
                            })
                            .cursor_pointer()
                            .when(can_submit, |button| {
                                button.on_click(cx.listener(|this, _, _, cx| this.submit(cx)))
                            })
                            .child("↑"),
                    )
                    .when(show_interrupt, |view| {
                        view.child(
                            div()
                                .id("codex-composer-interrupt")
                                .focusable()
                                .tab_stop(true)
                                .role(Role::Button)
                                .aria_label("Interrupt active turn")
                                .size(px(32.))
                                .rounded_full()
                                .border_1()
                                .border_color(theme.danger)
                                .flex()
                                .items_center()
                                .justify_center()
                                .text_color(theme.danger)
                                .cursor_pointer()
                                .on_click(cx.listener(|this, _, _, cx| this.interrupt(cx)))
                                .child("■"),
                        )
                    }),
            )
    }
}

fn bounded_replacement(value: &str, maximum_bytes: usize) -> String {
    let normalized = value.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.len() <= maximum_bytes {
        return normalized;
    }
    let mut end = maximum_bytes;
    while !normalized.is_char_boundary(end) {
        end -= 1;
    }
    normalized[..end].to_owned()
}

fn offset_from_utf16(content: &str, offset: usize) -> usize {
    content
        .chars()
        .scan((0_usize, 0_usize), |state, character| {
            let current = *state;
            state.0 += character.len_utf16();
            state.1 += character.len_utf8();
            Some(current)
        })
        .find_map(|(utf16, utf8)| (utf16 >= offset).then_some(utf8))
        .unwrap_or(content.len())
}

fn offset_to_utf16(content: &str, offset: usize) -> usize {
    content
        .char_indices()
        .take_while(|(utf8, _)| *utf8 < offset)
        .map(|(_, character)| character.len_utf16())
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_preserves_newlines_and_is_utf8_safe() {
        assert_eq!(bounded_replacement("one\ntwo", 32), "one\ntwo");
        assert_eq!(bounded_replacement("界界", 4), "界");
    }

    #[test]
    fn multiline_height_grows_and_caps_at_six_lines() {
        let line_height = px(20.);
        assert_eq!(composer_input_height("one", line_height), px(36.));
        assert_eq!(composer_input_height("one\ntwo", line_height), px(56.));
        assert_eq!(
            composer_input_height("1\n2\n3\n4\n5\n6\n7", line_height),
            px(136.)
        );
    }

    #[test]
    fn line_ranges_keep_empty_trailing_lines_for_newline_insertion() {
        assert_eq!(input_line_ranges("one\n"), vec![0..3, 4..4]);
        assert_eq!(input_line_ranges("\n"), vec![0..0, 1..1]);
    }

    #[test]
    fn utf16_offsets_round_trip_surrogate_pairs() {
        assert_eq!(offset_to_utf16("a😀b", 5), 3);
        assert_eq!(offset_from_utf16("a😀b", 3), 5);
    }

    #[test]
    fn active_composer_controls_keep_send_before_stop() {
        assert_eq!(
            composer_control_order(true),
            &[ComposerControl::Send, ComposerControl::Stop]
        );
        assert_eq!(composer_control_order(false), &[ComposerControl::Send]);
    }

    #[test]
    fn model_control_uses_a_typed_host_event() {
        assert!(matches!(
            model_control_event(),
            ComposerEvent::OpenModelPicker
        ));
    }
}
