use codex_presentation::AuthenticationPresentation;
use gpui::{
    ClipboardItem, Context, Entity, EventEmitter, Render, Role, Subscription, Window, div,
    prelude::*, px,
};

use crate::{
    CodexTheme,
    composer::{ComposerInput, InputEvent},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LoginEvent {
    ApiKey(String),
    Browser,
    DeviceCode,
    Cancel { login_id: String },
    OpenUrl(String),
    Back,
}

pub struct CodexAuthentication {
    presentation: AuthenticationPresentation,
    api_key: String,
    api_key_input: Entity<ComposerInput>,
    theme: CodexTheme,
    _input_subscription: Subscription,
}

impl CodexAuthentication {
    #[must_use]
    pub fn new(presentation: AuthenticationPresentation, cx: &mut Context<Self>) -> Self {
        let theme = CodexTheme::default();
        let input = cx.new(|cx| ComposerInput::new("API key…".into(), theme, true, cx));
        let subscription = cx.subscribe(&input, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Changed) {
                input.read(cx).text().clone_into(&mut this.api_key);
                cx.notify();
            }
        });
        Self {
            presentation,
            api_key: String::new(),
            api_key_input: input,
            theme,
            _input_subscription: subscription,
        }
    }

    pub fn set_presentation(
        &mut self,
        presentation: AuthenticationPresentation,
        cx: &mut Context<Self>,
    ) {
        self.presentation = presentation;
        cx.notify();
    }

    fn submit_api_key(&mut self, cx: &mut Context<Self>) {
        let key = self.api_key.trim().to_owned();
        if !key.is_empty() {
            self.api_key.clear();
            self.api_key_input.update(cx, ComposerInput::reset);
            cx.emit(LoginEvent::ApiKey(key));
        }
    }
}

impl EventEmitter<LoginEvent> for CodexAuthentication {}

impl Render for CodexAuthentication {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = match &self.presentation {
            AuthenticationPresentation::SignedOut {
                requires_openai_auth,
            } => render_signed_out(
                self.api_key_input.clone(),
                !self.api_key.trim().is_empty(),
                *requires_openai_auth,
                self.theme,
                cx,
            ),
            AuthenticationPresentation::Authenticated { label } => div()
                .text_sm()
                .child(format!("Authenticated as {label}"))
                .into_any(),
            AuthenticationPresentation::BrowserChallenge { login_id, url } => {
                render_url_challenge(login_id, url, None, self.theme, cx)
            }
            AuthenticationPresentation::DeviceChallenge {
                login_id,
                user_code,
                verification_url,
            } => render_url_challenge(login_id, verification_url, Some(user_code), self.theme, cx),
            AuthenticationPresentation::Failed { message } => div()
                .flex()
                .flex_col()
                .gap_3()
                .text_color(self.theme.danger)
                .child(message.clone())
                .child(
                    auth_button("auth-back", "Back", true, self.theme)
                        .on_click(cx.listener(|_, _, _, cx| cx.emit(LoginEvent::Back))),
                )
                .into_any(),
        };
        div()
            .id("codex-authentication")
            .role(Role::Dialog)
            .aria_label("Codex authentication")
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .bg(self.theme.background)
            .text_color(self.theme.text)
            .child(
                div()
                    .w(px(520.))
                    .rounded_xl()
                    .border_1()
                    .border_color(self.theme.border)
                    .bg(self.theme.elevated_surface)
                    .p_5()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .child(div().text_xl().child("Sign in to Codex"))
                    .child(body),
            )
    }
}

fn render_signed_out(
    api_key_input: Entity<ComposerInput>,
    can_submit: bool,
    requires_openai_auth: bool,
    theme: CodexTheme,
    cx: &mut Context<CodexAuthentication>,
) -> gpui::AnyElement {
    div()
        .flex()
        .flex_col()
        .gap_3()
        .when(requires_openai_auth, |view| {
            view.child(
                div()
                    .text_sm()
                    .text_color(theme.muted_text)
                    .child("This runtime requires OpenAI authentication."),
            )
        })
        .child(
            div()
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface)
                .child(api_key_input),
        )
        .child(
            auth_button("auth-api-key", "Use API key", can_submit, theme)
                .when(can_submit, |button| {
                    button.on_click(cx.listener(|this, _, _, cx| this.submit_api_key(cx)))
                }),
        )
        .child(
            auth_button("auth-browser", "Continue in browser", true, theme)
                .on_click(cx.listener(|_, _, _, cx| cx.emit(LoginEvent::Browser))),
        )
        .child(
            auth_button("auth-device", "Use device code", true, theme)
                .on_click(cx.listener(|_, _, _, cx| cx.emit(LoginEvent::DeviceCode))),
        )
        .into_any()
}

fn render_url_challenge(
    login_id: &str,
    url: &str,
    user_code: Option<&String>,
    theme: CodexTheme,
    cx: &mut Context<CodexAuthentication>,
) -> gpui::AnyElement {
    let open_url = url.to_owned();
    let cancel_id = login_id.to_owned();
    let copy_code = user_code.cloned();
    div()
        .flex()
        .flex_col()
        .gap_3()
        .when_some(user_code.cloned(), |view, code| {
            view.child(div().font_family("monospace").text_lg().child(code))
        })
        .when_some(copy_code, |view, code| {
            view.child(
                auth_button("auth-copy", "Copy code", true, theme).on_click(cx.listener(
                    move |_, _, _, cx| {
                        cx.write_to_clipboard(ClipboardItem::new_string(code.clone()));
                    },
                )),
            )
        })
        .child(
            auth_button("auth-open", "Open sign-in page", true, theme).on_click(
                cx.listener(move |_, _, _, cx| cx.emit(LoginEvent::OpenUrl(open_url.clone()))),
            ),
        )
        .child(
            auth_button("auth-cancel", "Cancel", true, theme).on_click(cx.listener(
                move |_, _, _, cx| {
                    cx.emit(LoginEvent::Cancel {
                        login_id: cancel_id.clone(),
                    });
                },
            )),
        )
        .into_any()
}

fn auth_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    theme: CodexTheme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .focusable()
        .tab_stop(enabled)
        .role(Role::Button)
        .aria_label(label)
        .rounded_lg()
        .border_1()
        .border_color(theme.border)
        .px_3()
        .py_2()
        .text_center()
        .text_color(if enabled {
            theme.text
        } else {
            theme.muted_text
        })
        .when(enabled, gpui::Styled::cursor_pointer)
        .child(label)
}
