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
        KeyBinding::new("enter", Submit, context),
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
}

pub(crate) enum InputEvent {
    Submit,
    Changed,
}

pub(crate) struct ComposerInput {
    focus_handle: FocusHandle,
    content: SharedString,
    placeholder: SharedString,
    selected_range: Range<usize>,
    selection_reversed: bool,
    marked_range: Option<Range<usize>>,
    last_layout: Option<ShapedLine>,
    last_bounds: Option<Bounds<Pixels>>,
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
            selected_range: 0..0,
            selection_reversed: false,
            marked_range: None,
            last_layout: None,
            last_bounds: None,
            is_selecting: false,
            theme,
            secret,
        }
    }

    pub(crate) fn text(&self) -> &str {
        &self.content
    }

    pub(crate) fn set_theme(&mut self, theme: CodexTheme, cx: &mut Context<Self>) {
        self.theme = theme;
        cx.notify();
    }

    fn set_text(&mut self, text: &str, cx: &mut Context<Self>) {
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
        line.closest_index_for_x(position.x - bounds.left())
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
        Some(Bounds::from_corners(
            point(
                bounds.left() + layout.x_for_index(range.start),
                bounds.top(),
            ),
            point(
                bounds.left() + layout.x_for_index(range.end),
                bounds.bottom(),
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
        let index = layout.index_for_x(point.x - bounds.left())?;
        Some(self.offset_to_utf16(index))
    }
}

impl Focusable for ComposerInput {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for ComposerInput {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("codex-composer-input")
            .key_context("CodexComposerInput")
            .track_focus(&self.focus_handle)
            .role(if self.secret {
                Role::PasswordInput
            } else {
                Role::TextInput
            })
            .aria_label("Message Codex")
            .aria_placeholder(self.placeholder.clone())
            .aria_value(if self.secret {
                SharedString::from("*".repeat(self.content.len()))
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
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .h(px(42.))
            .w_full()
            .overflow_hidden()
            .px_2()
            .flex()
            .items_center()
            .child(InputTextElement { input: cx.entity() })
    }
}

struct InputTextElement {
    input: Entity<ComposerInput>,
}

struct InputPrepaint {
    line: Option<ShapedLine>,
    cursor: Option<PaintQuad>,
    selection: Option<PaintQuad>,
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
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = window.line_height().into();
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
            (
                SharedString::from("*".repeat(content.len())),
                text_style.color,
            )
        } else {
            (content, text_style.color)
        };
        let run = TextRun {
            len: display.len(),
            font: text_style.font(),
            color,
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        let runs = marked_runs(&run, display.len(), input.marked_range.as_ref());
        let font_size = text_style.font_size.to_pixels(window.rem_size());
        let line = window
            .text_system()
            .shape_line(display, font_size, &runs, None);
        let cursor_x = line.x_for_index(cursor_index);
        let (selection, cursor) = if selected.is_empty() {
            (
                None,
                Some(fill(
                    Bounds::new(
                        point(bounds.left() + cursor_x, bounds.top()),
                        size(px(2.), bounds.size.height),
                    ),
                    theme.accent,
                )),
            )
        } else {
            (
                Some(fill(
                    Bounds::from_corners(
                        point(
                            bounds.left() + line.x_for_index(selected.start),
                            bounds.top(),
                        ),
                        point(
                            bounds.left() + line.x_for_index(selected.end),
                            bounds.bottom(),
                        ),
                    ),
                    theme.accent.opacity(0.25),
                )),
                None,
            )
        };
        InputPrepaint {
            line: Some(line),
            cursor,
            selection,
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
        if let Some(selection) = prepaint.selection.take() {
            window.paint_quad(selection);
        }
        let line = prepaint.line.take().expect("prepaint produces a line");
        line.paint(
            bounds.origin,
            window.line_height(),
            gpui::TextAlign::Left,
            None,
            window,
            cx,
        )
        .expect("paint composer text");
        if focus.is_focused(window)
            && let Some(cursor) = prepaint.cursor.take()
        {
            window.paint_quad(cursor);
        }
        self.input.update(cx, |input, _| {
            input.last_layout = Some(line);
            input.last_bounds = Some(bounds);
        });
    }
}

fn marked_runs(
    base: &TextRun,
    display_length: usize,
    marked: Option<&Range<usize>>,
) -> Vec<TextRun> {
    let Some(marked) = marked else {
        return vec![base.clone()];
    };
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
            len: display_length - marked.end,
            ..base.clone()
        },
    ]
    .into_iter()
    .filter(|run| run.len > 0)
    .collect()
}

/// Controlled single-line composer with native IME and clipboard behavior.
pub struct CodexComposer {
    input: Entity<ComposerInput>,
    theme: CodexTheme,
    turn_active: bool,
    active_submit_behavior: ActiveSubmitBehavior,
    _input_subscription: gpui::Subscription,
}

impl CodexComposer {
    #[must_use]
    pub fn new(cx: &mut Context<Self>) -> Self {
        let theme = CodexTheme::default();
        let input = cx.new(|cx| ComposerInput::new("Message Codex…".into(), theme, false, cx));
        let subscription = cx.subscribe(&input, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Submit) {
                this.submit(cx);
            }
        });
        Self {
            input,
            theme,
            turn_active: false,
            active_submit_behavior: ActiveSubmitBehavior::Queue,
            _input_subscription: subscription,
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

    #[must_use]
    pub fn input_focus_handle(&self, cx: &App) -> FocusHandle {
        self.input.read(cx).focus_handle.clone()
    }

    fn submit(&mut self, cx: &mut Context<Self>) {
        let text = self.input.read(cx).text().trim().to_owned();
        if text.is_empty() {
            return;
        }
        self.input.update(cx, ComposerInput::reset);
        cx.emit(ComposerEvent::Submit {
            text,
            active_behavior: self.active_submit_behavior,
        });
    }

    fn toggle_active_behavior(&mut self, cx: &mut Context<Self>) {
        self.active_submit_behavior = match self.active_submit_behavior {
            ActiveSubmitBehavior::Queue => ActiveSubmitBehavior::Steer,
            ActiveSubmitBehavior::Steer => ActiveSubmitBehavior::Queue,
        };
        cx.notify();
    }

    fn interrupt(&mut self, cx: &mut Context<Self>) {
        if self.turn_active {
            cx.emit(ComposerEvent::Interrupt);
        }
    }
}

impl EventEmitter<ComposerEvent> for CodexComposer {}

impl Render for CodexComposer {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let can_submit = !self.input.read(cx).text().trim().is_empty();
        let theme = self.theme;
        let submit_label = if self.turn_active {
            match self.active_submit_behavior {
                ActiveSubmitBehavior::Queue => "Queue",
                ActiveSubmitBehavior::Steer => "Steer",
            }
        } else {
            "Send"
        };
        div()
            .id("codex-composer")
            .role(Role::Form)
            .aria_label("Codex message composer")
            .w_full()
            .flex()
            .items_center()
            .gap_2()
            .rounded_xl()
            .border_1()
            .border_color(theme.border)
            .bg(theme.elevated_surface)
            .p_2()
            .child(div().flex_1().overflow_hidden().child(self.input.clone()))
            .when(self.turn_active, |view| {
                view.child(
                    div()
                        .id("codex-composer-active-behavior")
                        .focusable()
                        .tab_stop(true)
                        .role(Role::Button)
                        .aria_label("Toggle between queue and steer")
                        .rounded_lg()
                        .border_1()
                        .border_color(theme.border)
                        .px_3()
                        .py_2()
                        .text_xs()
                        .cursor_pointer()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.toggle_active_behavior(cx);
                        }))
                        .child(submit_label),
                )
            })
            .child(
                div()
                    .id("codex-composer-submit")
                    .focusable()
                    .tab_stop(true)
                    .role(Role::Button)
                    .aria_label(format!("{submit_label} message"))
                    .rounded_lg()
                    .px_3()
                    .py_2()
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
                    .child(submit_label),
            )
            .when(self.turn_active, |view| {
                view.child(
                    div()
                        .id("codex-composer-interrupt")
                        .focusable()
                        .tab_stop(true)
                        .role(Role::Button)
                        .aria_label("Interrupt active turn")
                        .rounded_lg()
                        .border_1()
                        .border_color(theme.danger)
                        .px_3()
                        .py_2()
                        .text_color(theme.danger)
                        .cursor_pointer()
                        .on_click(cx.listener(|this, _, _, cx| this.interrupt(cx)))
                        .child("Stop"),
                )
            })
    }
}

fn bounded_replacement(value: &str, maximum_bytes: usize) -> String {
    let normalized = value.replace(['\r', '\n'], " ");
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
    fn replacement_is_single_line_bounded_and_utf8_safe() {
        assert_eq!(bounded_replacement("one\ntwo", 32), "one two");
        assert_eq!(bounded_replacement("界界", 4), "界");
    }

    #[test]
    fn utf16_offsets_round_trip_surrogate_pairs() {
        assert_eq!(offset_to_utf16("a😀b", 5), 3);
        assert_eq!(offset_from_utf16("a😀b", 3), 5);
    }
}
