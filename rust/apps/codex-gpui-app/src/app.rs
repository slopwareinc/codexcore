use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use async_channel::{Receiver, Sender};
use codex_app_server_client::{
    AppServerClient, CanonicalObservation, LocalSessionConfig, SessionObservation,
};
use codex_app_server_interaction::{
    ServerRequestBody, ServerRequestReply, TypedServerRequest, default_resolution, parse_pending,
};
use codex_app_server_sdk::{
    Codex, CodexInput, CodexThread, ListModelsOptions, ListThreadsOptions, LoginAppBrand,
    LoginRequest, PaginatedResumeOptions, StartThreadOptions, TurnOptions,
};
use codex_app_server_state::{StateObservationScope, ThreadId, TurnKey};
use codex_app_server_wire::JsonRpcErrorObject;
use codex_gpui::{
    ActiveSubmitBehavior, CodexAuthentication, CodexComposer, CodexGoal, CodexModelPicker,
    CodexPrompt, CodexQueue, CodexSubagentNavigator, CodexTheme, CodexThreadList,
    CodexTranscriptV2, ComposerAttachment, ComposerEvent, GoalEvent, LoginEvent,
    ModelSelectionEvent, PromptIntent, QueueEvent, SubagentSelectionEvent, ThreadListCommand,
    ThreadSelectionEvent, TranscriptEvent, display_reasoning_effort,
};
use codex_presentation::{
    AuthenticationPresentation, GoalPresentation, ModelPickerPresentation, PromptActionKind,
    PromptPresentation, QueuePresentation, StandardItemPolicy, TaskStatusPresentation,
    ThreadGraphKey, ThreadGraphProjector, ThreadGraphSnapshot, ThreadListPresentation,
    ThreadListRow, project_account, project_goal, project_login_challenge, project_model_picker,
    project_prompt, project_queue, project_thread_list,
    transcript_v2::{TranscriptV2Presentation, TranscriptV2Projector},
};
use gpui::{
    App, AppContext, Bounds, Context, Entity, PathPromptOptions, Render, Subscription, Task,
    Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_platform::application;
use gpui_tokio::Tokio;
use serde_json::json;

use crate::config::RunConfiguration;
use crate::goal::execute_goal_event;

const UPDATE_CAPACITY: usize = 32;
const COMMAND_CAPACITY: usize = 16;
const LOCAL_HOST_ID: &str = "local";
const SIDEBAR_WIDTH: f32 = 304.;
const TOOLBAR_HEIGHT: f32 = 46.;
const COMPOSER_FRAME_WIDTH: f32 = 768.;

pub fn run() {
    let config = match RunConfiguration::parse(std::env::args().skip(1)) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("codex-gpui-app: {error}");
            std::process::exit(2);
        }
    };

    if config.headless {
        if let Err(error) = run_headless(config) {
            eprintln!("codex-gpui-app: {error}");
            std::process::exit(1);
        }
        return;
    }

    application().run(move |cx: &mut App| {
        gpui_tokio::init(cx);
        codex_gpui::init_composer(cx);
        let bounds = Bounds::centered(None, size(px(1_200.), px(840.)), cx);
        cx.open_window(
            WindowOptions {
                focus: true,
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..WindowOptions::default()
            },
            |_, cx| cx.new(|cx| CodexApp::new(config, cx)),
        )
        .expect("open Codex GPUI window");
        cx.activate(true);
    });
}

fn run_headless(config: RunConfiguration) -> Result<(), String> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?
        .block_on(async move {
            let (updates, receiver) = async_channel::bounded(UPDATE_CAPACITY);
            let (commands, command_receiver) = async_channel::bounded(COMMAND_CAPACITY);
            let queued_prompt = config.queued_prompt.clone();
            let printer = tokio::spawn(print_updates(receiver, commands, queued_prompt));
            let result = run_session(config, updates, command_receiver).await;
            printer.await.map_err(|error| error.to_string())?;
            result
        })
}

async fn print_updates(
    receiver: Receiver<AppUpdate>,
    commands: Sender<HostCommand>,
    queued_prompt: Option<String>,
) {
    let mut queued = false;
    while let Ok(update) = receiver.recv().await {
        match update {
            AppUpdate::Status(status) => println!("status: {status}"),
            AppUpdate::Canonical {
                transcript,
                root,
                graph,
            } => {
                println!(
                    "transcript: revision={} turns={}",
                    transcript.revision.get(),
                    transcript.turns.len()
                );
                println!("subagents: {}", graph.descendants(&root).len());
            }
            AppUpdate::Prompt(Some(prompt)) => println!("prompt: {}", prompt.title),
            AppUpdate::Prompt(None) => {}
            AppUpdate::ModelPicker(presentation) => println!(
                "models: {} selected={}",
                presentation.models.len(),
                presentation.selected_model
            ),
            AppUpdate::ThreadList(presentation) => {
                println!("tasks: {}", presentation.rows.len());
            }
            AppUpdate::Queue(presentation) => println!("queue: {}", presentation.rows.len()),
            AppUpdate::Goal(Some(presentation)) => println!(
                "goal: {} · {}",
                presentation.status_label, presentation.token_usage_label
            ),
            AppUpdate::Goal(None) => println!("goal: none"),
            AppUpdate::Authentication(presentation) => println!(
                "authentication: {}",
                match presentation {
                    AuthenticationPresentation::SignedOut { .. } => "signed-out",
                    AuthenticationPresentation::Authenticated { .. } => "authenticated",
                    AuthenticationPresentation::BrowserChallenge { .. } => "browser-challenge",
                    AuthenticationPresentation::DeviceChallenge { .. } => "device-challenge",
                    AuthenticationPresentation::Failed { .. } => "failed",
                }
            ),
            AppUpdate::TurnActive(active) => {
                println!("turn-active: {active}");
                if active
                    && !queued
                    && let Some(text) = queued_prompt.clone()
                {
                    queued = true;
                    let _ = commands
                        .send(HostCommand::Submit {
                            text,
                            attachments: Vec::new(),
                            active_behavior: ActiveSubmitBehavior::Queue,
                        })
                        .await;
                }
            }
            AppUpdate::Failed(error) => eprintln!("session failed: {error}"),
        }
    }
}

enum AppUpdate {
    Status(String),
    Canonical {
        transcript: TranscriptV2Presentation,
        root: ThreadGraphKey,
        graph: ThreadGraphSnapshot,
    },
    Prompt(Option<PromptPresentation>),
    ModelPicker(ModelPickerPresentation),
    ThreadList(ThreadListPresentation),
    Queue(QueuePresentation),
    Goal(Option<GoalPresentation>),
    Authentication(AuthenticationPresentation),
    TurnActive(bool),
    Failed(String),
}

#[derive(Clone, Debug)]
enum HostCommand {
    Prompt(PromptIntent),
    Submit {
        text: String,
        attachments: Vec<ComposerAttachment>,
        active_behavior: ActiveSubmitBehavior,
    },
    Interrupt,
    SelectThread(ThreadId),
    NewChat,
    Search,
    SelectModel(ModelSelectionEvent),
    Queue(QueueEvent),
    Goal(GoalEvent),
    Login(LoginEvent),
    Shutdown,
}

struct CodexApp {
    transcript: Entity<CodexTranscriptV2>,
    thread_list: Entity<CodexThreadList>,
    subagent_navigator: Entity<CodexSubagentNavigator>,
    model_picker: Entity<CodexModelPicker>,
    queue: Entity<CodexQueue>,
    goal: Entity<CodexGoal>,
    authentication: Entity<CodexAuthentication>,
    authentication_visible: bool,
    inspector_visible: bool,
    composer: Entity<CodexComposer>,
    prompt: Option<Entity<CodexPrompt>>,
    prompt_subscription: Option<Subscription>,
    attachment_picker_task: Option<Task<()>>,
    _composer_subscription: Subscription,
    _transcript_subscription: Subscription,
    _thread_list_subscription: Subscription,
    _thread_command_subscription: Subscription,
    _subagent_subscription: Subscription,
    _model_picker_subscription: Subscription,
    _queue_subscription: Subscription,
    _goal_subscription: Subscription,
    _authentication_subscription: Subscription,
    _quit_subscription: Subscription,
    status: String,
    command_sender: Sender<HostCommand>,
    _session_task: Task<Result<(), gpui_tokio::JoinError>>,
    _update_task: Task<()>,
}

struct InitialViews {
    transcript: Entity<CodexTranscriptV2>,
    thread_list: Entity<CodexThreadList>,
    subagent_navigator: Entity<CodexSubagentNavigator>,
    model_picker: Entity<CodexModelPicker>,
    queue: Entity<CodexQueue>,
    goal: Entity<CodexGoal>,
    composer: Entity<CodexComposer>,
    authentication: Entity<CodexAuthentication>,
}

fn initial_views(queue_enabled: bool, cx: &mut Context<CodexApp>) -> InitialViews {
    let pending = TranscriptV2Presentation {
        revision: codex_app_server_state::StateRevision::ZERO,
        thread_id: ThreadId::from("pending"),
        turns: Vec::new(),
    };
    InitialViews {
        transcript: cx.new(|_| CodexTranscriptV2::new(&pending)),
        thread_list: cx.new(|_| {
            CodexThreadList::new(ThreadListPresentation {
                rows: Vec::new(),
                next_cursor: None,
                backwards_cursor: None,
            })
        }),
        subagent_navigator: cx.new(|_| {
            let snapshot = ThreadGraphSnapshot {
                revision: codex_app_server_state::StateRevision::ZERO,
                nodes: std::collections::BTreeMap::new(),
                edges: Vec::new(),
                actions: Vec::new(),
                roots: Vec::new(),
                cycle_edges: Vec::new(),
            };
            CodexSubagentNavigator::new(
                ThreadGraphKey::new(LOCAL_HOST_ID, ThreadId::from("pending")),
                &snapshot,
            )
        }),
        model_picker: cx.new(|_| {
            CodexModelPicker::new(ModelPickerPresentation {
                models: Vec::new(),
                selected_model: String::new(),
                selected_effort: String::new(),
            })
        }),
        queue: cx.new(|_| {
            CodexQueue::new(QueuePresentation {
                rows: Vec::new(),
                next_cursor: None,
            })
        }),
        goal: cx.new(|cx| CodexGoal::new(None, cx)),
        composer: cx.new(|cx| {
            let mut composer = CodexComposer::new(cx);
            composer.set_queue_enabled(queue_enabled, cx);
            composer
        }),
        authentication: cx.new(|cx| {
            CodexAuthentication::new(
                AuthenticationPresentation::SignedOut {
                    requires_openai_auth: true,
                },
                cx,
            )
        }),
    }
}

fn subscribe_transcript_links(
    transcript: &Entity<CodexTranscriptV2>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    cx.subscribe(
        transcript,
        move |_, _, event: &TranscriptEvent, cx| match event {
            TranscriptEvent::OpenLink { destination, .. }
                if is_allowed_external_url(destination) =>
            {
                cx.open_url(destination);
            }
            // These actions intentionally remain host-owned seams. The
            // reference host has no edit/fork/retry policy yet, so it does
            // not pretend to mutate canonical state from a view event.
            TranscriptEvent::OpenLink { .. }
            | TranscriptEvent::EditUserMessage { .. }
            | TranscriptEvent::RetryTurn { .. }
            | TranscriptEvent::ForkTurn { .. } => {}
        },
    )
}

fn subscribe_subagent_selection(
    navigator: &Entity<CodexSubagentNavigator>,
    sender: &Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    let sender = sender.clone();
    cx.subscribe(navigator, move |_, _, event: &SubagentSelectionEvent, _| {
        if let Some(thread_id) = selected_subagent_thread(event) {
            let _ = sender.try_send(HostCommand::SelectThread(thread_id));
        }
    })
}

fn subscribe_goal(
    goal: &Entity<CodexGoal>,
    sender: Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    cx.subscribe(goal, move |_, _, event: &GoalEvent, _| {
        let _ = sender.try_send(HostCommand::Goal(event.clone()));
    })
}

fn subscribe_authentication(
    authentication: &Entity<CodexAuthentication>,
    sender: Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    cx.subscribe(authentication, move |_, _, event: &LoginEvent, cx| {
        if let LoginEvent::OpenUrl(url) = event {
            cx.open_url(url);
        } else {
            let _ = sender.try_send(HostCommand::Login(event.clone()));
        }
    })
}

fn selected_subagent_thread(event: &SubagentSelectionEvent) -> Option<ThreadId> {
    (event.key.host_id == LOCAL_HOST_ID).then(|| event.key.thread_id.clone())
}

fn subscribe_thread_selection(
    thread_list: &Entity<CodexThreadList>,
    sender: &Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    let sender = sender.clone();
    cx.subscribe(thread_list, move |_, _, event: &ThreadSelectionEvent, _| {
        let _ = sender.try_send(HostCommand::SelectThread(event.thread_id.clone()));
    })
}

fn subscribe_thread_commands(
    thread_list: &Entity<CodexThreadList>,
    sender: &Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    let sender = sender.clone();
    cx.subscribe(thread_list, move |_, _, event: &ThreadListCommand, _| {
        let command = match event {
            ThreadListCommand::NewChat => HostCommand::NewChat,
            ThreadListCommand::Search => HostCommand::Search,
        };
        let _ = sender.try_send(command);
    })
}

fn subscribe_composer(
    composer: &Entity<CodexComposer>,
    sender: &Sender<HostCommand>,
    cx: &mut Context<CodexApp>,
) -> Subscription {
    let sender = sender.clone();
    cx.subscribe(composer, move |this, _, event: &ComposerEvent, cx| {
        let command = match event {
            ComposerEvent::Submit {
                text,
                attachments,
                active_behavior,
            } => HostCommand::Submit {
                text: text.clone(),
                attachments: attachments.clone(),
                active_behavior: *active_behavior,
            },
            ComposerEvent::OpenAttachmentPicker => {
                this.open_attachment_picker(cx);
                return;
            }
            ComposerEvent::RemoveAttachment { .. } => return,
            ComposerEvent::Interrupt => HostCommand::Interrupt,
            ComposerEvent::OpenModelPicker => {
                this.inspector_visible = true;
                cx.notify();
                return;
            }
        };
        let _ = sender.try_send(command);
    })
}

impl CodexApp {
    fn new(config: RunConfiguration, cx: &mut Context<Self>) -> Self {
        let InitialViews {
            transcript,
            thread_list,
            subagent_navigator,
            model_picker,
            queue,
            goal,
            composer,
            authentication,
        } = initial_views(!config.ephemeral, cx);
        let (update_sender, update_receiver) = async_channel::bounded(UPDATE_CAPACITY);
        let (command_sender, command_receiver) = async_channel::bounded(COMMAND_CAPACITY);
        let composer_subscription = subscribe_composer(&composer, &command_sender, cx);
        let transcript_subscription = subscribe_transcript_links(&transcript, cx);
        let thread_list_subscription =
            subscribe_thread_selection(&thread_list, &command_sender, cx);
        let thread_command_subscription =
            subscribe_thread_commands(&thread_list, &command_sender, cx);
        let subagent_subscription =
            subscribe_subagent_selection(&subagent_navigator, &command_sender, cx);
        let model_sender = command_sender.clone();
        let model_picker_subscription = cx.subscribe(
            &model_picker,
            move |_, _, event: &ModelSelectionEvent, _| {
                let _ = model_sender.try_send(HostCommand::SelectModel(event.clone()));
            },
        );
        let queue_sender = command_sender.clone();
        let queue_subscription = cx.subscribe(&queue, move |_, _, event: &QueueEvent, _| {
            let _ = queue_sender.try_send(HostCommand::Queue(event.clone()));
        });
        let goal_subscription = subscribe_goal(&goal, command_sender.clone(), cx);
        let authentication_subscription =
            subscribe_authentication(&authentication, command_sender.clone(), cx);
        let quit_sender = command_sender.clone();
        let quit_subscription = cx.on_app_quit(move |_, _| {
            let quit_sender = quit_sender.clone();
            async move {
                let _ = quit_sender.send(HostCommand::Shutdown).await;
            }
        });
        let session_task = Tokio::spawn(cx, async move {
            if let Err(error) = run_session(config, update_sender.clone(), command_receiver).await {
                let _ = update_sender.send(AppUpdate::Failed(error)).await;
            }
        });
        let update_task = cx.spawn(async move |this, cx| {
            while let Ok(update) = update_receiver.recv().await {
                if this
                    .update(cx, |this, cx| this.apply_update(update, cx))
                    .is_err()
                {
                    break;
                }
            }
        });

        Self {
            transcript,
            thread_list,
            subagent_navigator,
            model_picker,
            queue,
            goal,
            authentication,
            authentication_visible: true,
            inspector_visible: false,
            composer,
            prompt: None,
            prompt_subscription: None,
            attachment_picker_task: None,
            _composer_subscription: composer_subscription,
            _transcript_subscription: transcript_subscription,
            _thread_list_subscription: thread_list_subscription,
            _thread_command_subscription: thread_command_subscription,
            _subagent_subscription: subagent_subscription,
            _model_picker_subscription: model_picker_subscription,
            _queue_subscription: queue_subscription,
            _goal_subscription: goal_subscription,
            _authentication_subscription: authentication_subscription,
            _quit_subscription: quit_subscription,
            status: "Starting Codex App Server…".to_owned(),
            command_sender,
            _session_task: session_task,
            _update_task: update_task,
        }
    }

    fn apply_update(&mut self, update: AppUpdate, cx: &mut Context<Self>) {
        match update {
            AppUpdate::Status(status) => self.status = status,
            AppUpdate::Canonical {
                transcript: presentation,
                root,
                graph,
            } => {
                self.transcript.update(cx, |transcript, cx| {
                    transcript.set_presentation(&presentation, cx);
                });
                self.subagent_navigator.update(cx, |navigator, cx| {
                    navigator.set_snapshot(root, &graph, cx);
                });
            }
            AppUpdate::Prompt(presentation) => self.install_prompt(presentation, cx),
            AppUpdate::ModelPicker(presentation) => {
                let composer_label = composer_model_label(&presentation);
                self.composer.update(cx, |composer, cx| {
                    composer.set_model_label(composer_label, cx);
                });
                self.model_picker.update(cx, |picker, cx| {
                    picker.set_presentation(presentation, cx);
                });
            }
            AppUpdate::ThreadList(presentation) => {
                self.thread_list.update(cx, |thread_list, cx| {
                    thread_list.set_presentation(presentation, cx);
                });
            }
            AppUpdate::Queue(presentation) => {
                self.queue.update(cx, |queue, cx| {
                    queue.set_presentation(presentation, cx);
                });
            }
            AppUpdate::Goal(presentation) => {
                self.goal.update(cx, |goal, cx| {
                    goal.set_presentation(presentation, cx);
                });
            }
            AppUpdate::Authentication(presentation) => {
                self.authentication_visible = !matches!(
                    presentation,
                    AuthenticationPresentation::Authenticated { .. }
                );
                self.authentication.update(cx, |authentication, cx| {
                    authentication.set_presentation(presentation, cx);
                });
            }
            AppUpdate::TurnActive(active) => {
                self.composer.update(cx, |composer, cx| {
                    composer.set_turn_active(active, cx);
                });
            }
            AppUpdate::Failed(error) => {
                self.status = format!("Session failed: {error}");
                self.install_prompt(None, cx);
            }
        }
        cx.notify();
    }

    fn open_attachment_picker(&mut self, cx: &mut Context<Self>) {
        let receiver = cx.prompt_for_paths(attachment_picker_options());
        let composer = self.composer.clone();
        self.attachment_picker_task = Some(cx.spawn(async move |_, cx| {
            let Ok(Ok(Some(paths))) = receiver.await else {
                return;
            };
            if paths.is_empty() {
                return;
            }
            composer.update(cx, |composer, cx| composer.add_attachments(paths, cx));
        }));
    }

    fn install_prompt(&mut self, presentation: Option<PromptPresentation>, cx: &mut Context<Self>) {
        self.prompt_subscription = None;
        self.prompt = presentation.map(|presentation| {
            let prompt = cx.new(|cx| CodexPrompt::new(presentation, cx));
            let sender = self.command_sender.clone();
            self.prompt_subscription = Some(cx.subscribe(
                &prompt,
                move |_this, _prompt, intent: &PromptIntent, cx| {
                    if intent.action == PromptActionKind::OpenUrl
                        && let Some(url) = &intent.url
                    {
                        cx.open_url(url);
                        return;
                    }
                    let _ = sender.try_send(HostCommand::Prompt(intent.clone()));
                },
            ));
            prompt
        });
    }
}

impl Render for CodexApp {
    #[allow(clippy::too_many_lines)]
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = CodexTheme::default();
        let inspector_label = if self.inspector_visible {
            "Hide inspector"
        } else {
            "Show inspector"
        };
        div()
            .id("codex-workspace")
            .size_full()
            .relative()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(theme.background)
            .text_color(theme.text)
            .child(
                div()
                    .id("codex-window-chrome")
                    .h(px(TOOLBAR_HEIGHT))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .bg(theme.background)
                    .child(
                        div()
                            .w(px(SIDEBAR_WIDTH))
                            .h_full()
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .px_4()
                            .bg(theme.surface)
                            .child(
                                div()
                                    .text_base()
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child("Codex"),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .flex()
                            .items_center()
                            .justify_between()
                            .px_4()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_sm().child("New task"))
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(theme.tertiary_text)
                                            .child("CodexCore"),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .when(self.status.starts_with("Session failed:"), |view| {
                                        view.child(
                                            div()
                                                .text_xs()
                                                .text_color(theme.danger)
                                                .child(self.status.clone()),
                                        )
                                    })
                                    .child(
                                        shell_button(
                                            "inspector-toggle",
                                            "☷",
                                            inspector_label,
                                            self.inspector_visible,
                                            theme,
                                        )
                                        .on_click(
                                            cx.listener(|this, _, _, cx| {
                                                this.inspector_visible = !this.inspector_visible;
                                                cx.notify();
                                            }),
                                        ),
                                    ),
                            ),
                    ),
            )
            .child(
                div()
                    .id("codex-workspace-body")
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .overflow_hidden()
                    .child(
                        div()
                            .id("codex-sidebar")
                            .w(px(SIDEBAR_WIDTH))
                            .h_full()
                            .flex_shrink_0()
                            .border_r_1()
                            .border_color(theme.border)
                            .child(self.thread_list.clone()),
                    )
                    .child(
                        div()
                            .id("codex-chat-column")
                            .flex_1()
                            .h_full()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .overflow_hidden()
                            .child(div().flex_1().min_h_0().child(self.transcript.clone()))
                            .when_some(self.prompt.clone(), |view, prompt| {
                                view.child(div().flex_shrink_0().px_6().pb_3().child(prompt))
                            })
                            .child(self.queue.clone())
                            .child(
                                div()
                                    .flex_shrink_0()
                                    .w_full()
                                    .flex()
                                    .justify_center()
                                    .px(px(14.))
                                    .pb(px(22.))
                                    .child(
                                        div()
                                            .w_full()
                                            .max_w(px(COMPOSER_FRAME_WIDTH))
                                            .child(self.composer.clone()),
                                    ),
                            ),
                    )
                    .when(self.inspector_visible, |view| {
                        view.child(
                            div()
                                .id("codex-inspector")
                                .w(px(280.))
                                .h_full()
                                .flex_shrink_0()
                                .flex()
                                .flex_col()
                                .overflow_hidden()
                                .border_l_1()
                                .border_color(theme.border)
                                .child(
                                    div()
                                        .flex_shrink_0()
                                        .border_b_1()
                                        .border_color(theme.border)
                                        .child(self.goal.clone()),
                                )
                                .child(div().flex_1().min_h_0().child(self.model_picker.clone()))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_h_0()
                                        .border_t_1()
                                        .border_color(theme.border)
                                        .child(self.subagent_navigator.clone()),
                                ),
                        )
                    }),
            )
            .when(self.authentication_visible, |view| {
                view.child(
                    div()
                        .absolute()
                        .top(px(0.))
                        .right(px(0.))
                        .bottom(px(0.))
                        .left(px(0.))
                        .child(self.authentication.clone()),
                )
            })
    }
}

fn shell_button(
    id: &'static str,
    glyph: &'static str,
    label: &'static str,
    active: bool,
    theme: CodexTheme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .focusable()
        .tab_stop(true)
        .role(gpui::Role::Button)
        .aria_label(label)
        .rounded_lg()
        .px_2()
        .py_1()
        .text_sm()
        .text_color(if active {
            theme.accent
        } else {
            theme.muted_text
        })
        .when(active, |button| button.bg(theme.accent.opacity(0.14)))
        .cursor_pointer()
        .child(glyph)
}

async fn ensure_authenticated(
    codex: &Codex,
    commands: &Receiver<HostCommand>,
    updates: &Sender<AppUpdate>,
    observation: &mut SessionObservation,
) -> Result<(), String> {
    if publish_account(codex, updates).await? {
        return Ok(());
    }
    loop {
        tokio::select! {
            changed = observation.changed() => {
                changed.map_err(|error| error.to_string())?;
                if publish_account(codex, updates).await? {
                    return Ok(());
                }
            }
            command = commands.recv() => {
                match command {
                    Ok(HostCommand::Login(event)) => {
                        match handle_login_event(codex, event, updates).await {
                            Ok(true) if publish_account(codex, updates).await? => return Ok(()),
                            Ok(_) => {}
                            Err(error) => {
                                updates.send(AppUpdate::Authentication(
                                    AuthenticationPresentation::Failed { message: error }
                                )).await.ok();
                            }
                        }
                    }
                    Ok(HostCommand::Shutdown) | Err(_) => {
                        return Err("authentication canceled by host shutdown".to_owned());
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn publish_account(codex: &Codex, updates: &Sender<AppUpdate>) -> Result<bool, String> {
    let account = codex
        .account(false)
        .await
        .map_err(|error| error.to_string())?;
    let ready = account.account.is_some() || !account.requires_openai_auth;
    let presentation = if ready && account.account.is_none() {
        AuthenticationPresentation::Authenticated {
            label: "No account required".to_owned(),
        }
    } else {
        project_account(&account)
    };
    updates
        .send(AppUpdate::Authentication(presentation))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    Ok(ready)
}

async fn handle_login_event(
    codex: &Codex,
    event: LoginEvent,
    updates: &Sender<AppUpdate>,
) -> Result<bool, String> {
    let (presentation, refresh_account) = match event {
        LoginEvent::ApiKey(api_key) => {
            let challenge = codex
                .login(LoginRequest::ApiKey(api_key))
                .await
                .map_err(|error| error.to_string())?;
            let complete = matches!(challenge, codex_app_server_sdk::LoginChallenge::Complete);
            (project_login_challenge(challenge), complete)
        }
        LoginEvent::Browser => {
            let challenge = codex
                .login(LoginRequest::ChatGptBrowser {
                    streamlined: true,
                    hosted_success_page: true,
                    app_brand: Some(LoginAppBrand::Codex),
                })
                .await
                .map_err(|error| error.to_string())?;
            (project_login_challenge(challenge), false)
        }
        LoginEvent::DeviceCode => {
            let challenge = codex
                .login(LoginRequest::ChatGptDeviceCode)
                .await
                .map_err(|error| error.to_string())?;
            (project_login_challenge(challenge), false)
        }
        LoginEvent::Cancel { login_id } => {
            codex
                .cancel_login(&login_id)
                .await
                .map_err(|error| error.to_string())?;
            (
                project_account(
                    &codex
                        .account(false)
                        .await
                        .map_err(|error| error.to_string())?,
                ),
                true,
            )
        }
        LoginEvent::Back => (
            project_account(
                &codex
                    .account(false)
                    .await
                    .map_err(|error| error.to_string())?,
            ),
            true,
        ),
        LoginEvent::OpenUrl(_) => return Ok(false),
    };
    updates
        .send(AppUpdate::Authentication(presentation))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    Ok(refresh_account)
}

// Keeping the ordered host loop contiguous makes turn/queue/switch precedence auditable.
#[allow(clippy::too_many_lines)]
async fn run_session(
    config: RunConfiguration,
    updates: Sender<AppUpdate>,
    commands: Receiver<HostCommand>,
) -> Result<(), String> {
    let queue_enabled = !config.ephemeral;
    send_status(&updates, "Connecting to Codex App Server…").await;
    let codex = Codex::connect_local(LocalSessionConfig::app_server(config.codex_binary.clone()))
        .await
        .map_err(|error| error.to_string())?;
    let mut session_observation = codex
        .client()
        .observe()
        .await
        .map_err(|error| error.to_string())?;
    ensure_authenticated(&codex, &commands, &updates, &mut session_observation).await?;
    let mut turn_options = load_model_catalog(&codex, &updates).await?;
    let (started_thread, mut thread_id) =
        start_initial_thread(&codex, &config, &turn_options, &updates).await?;
    let mut thread = Some(started_thread);
    let mut canonical_observation = observe_thread(&codex, &thread_id).await?;
    refresh_goal_for_selection(
        thread
            .as_ref()
            .ok_or_else(|| "selected thread lease is missing".to_owned())?,
        &updates,
    )
    .await;
    let mut next_launch = (config.headless || config.prompt_explicit).then(|| TurnLaunch::Input {
        text: config.prompt.clone(),
        attachments: Vec::new(),
    });
    let mut next_queue_id = 1_u64;
    let mut shutdown = false;
    while !shutdown {
        let launch = match next_launch.take() {
            Some(launch) => launch,
            None => match next_idle_action(
                codex.client(),
                &thread_id,
                &mut canonical_observation,
                &commands,
                &updates,
            )
            .await?
            {
                IdleAction::Submit { text, attachments } => TurnLaunch::Input { text, attachments },
                IdleAction::Select(selected) => {
                    if selected != thread_id {
                        let replacement =
                            switch_thread(&codex, &mut thread, selected, &updates).await?;
                        thread_id = replacement.id().clone();
                        thread = Some(replacement);
                        canonical_observation = observe_thread(&codex, &thread_id).await?;
                    }
                    continue;
                }
                IdleAction::NewChat => {
                    if let Some(previous) = thread.take() {
                        previous.close().await.map_err(|error| error.to_string())?;
                    }
                    let (replacement, replacement_id) =
                        start_initial_thread(&codex, &config, &turn_options, &updates).await?;
                    thread_id = replacement_id;
                    thread = Some(replacement);
                    canonical_observation = observe_thread(&codex, &thread_id).await?;
                    refresh_goal_for_selection(
                        thread
                            .as_ref()
                            .ok_or_else(|| "new thread lease is missing".to_owned())?,
                        &updates,
                    )
                    .await;
                    publish_selected(codex.client(), &thread_id, &updates).await?;
                    send_status(&updates, "New chat ready").await;
                    continue;
                }
                IdleAction::Search => {
                    send_status(&updates, "Search is available from the task sidebar").await;
                    continue;
                }
                IdleAction::SelectModel(selection) => {
                    apply_model_selection(&mut turn_options, &selection);
                    send_status(&updates, "Model selection updated for the next turn").await;
                    continue;
                }
                IdleAction::Queue(event) => {
                    if !queue_enabled {
                        send_status(&updates, "Durable queue is unavailable for ephemeral tasks")
                            .await;
                        continue;
                    }
                    let current = thread
                        .as_ref()
                        .ok_or_else(|| "selected thread lease is missing".to_owned())?;
                    handle_queue_event(current, event).await?;
                    publish_queue(current, &updates).await?;
                    continue;
                }
                IdleAction::Goal(event) => {
                    let current = thread
                        .as_ref()
                        .ok_or_else(|| "selected thread lease is missing".to_owned())?;
                    handle_goal_event(current, event, &updates).await;
                    continue;
                }
                IdleAction::Shutdown => break,
            },
        };
        let outcome = drive_turn(
            &codex,
            thread
                .as_ref()
                .ok_or_else(|| "selected thread lease is missing".to_owned())?,
            &thread_id,
            launch,
            queue_enabled,
            &turn_options,
            TurnDriver {
                session_observation: &mut session_observation,
                canonical_observation: &mut canonical_observation,
                commands: &commands,
                updates: &updates,
                next_queue_id: &mut next_queue_id,
                queue_enabled,
            },
        )
        .await?;
        shutdown = outcome.shutdown;
        if let Some(selection) = &outcome.pending_model {
            apply_model_selection(&mut turn_options, selection);
        }
        if shutdown {
            break;
        }
        if let Some(selected) = &outcome.pending_selection
            && selected != &thread_id
        {
            let replacement =
                switch_thread(&codex, &mut thread, selected.clone(), &updates).await?;
            thread_id = replacement.id().clone();
            thread = Some(replacement);
            canonical_observation = observe_thread(&codex, &thread_id).await?;
            continue;
        }
        if let Some(launch) = next_queued_launch(
            &codex,
            thread
                .as_ref()
                .ok_or_else(|| "selected thread lease is missing".to_owned())?,
            &thread_id,
            &outcome,
            queue_enabled,
            &mut canonical_observation,
            &updates,
        )
        .await?
        {
            next_launch = Some(launch);
            continue;
        }
        if config.headless {
            break;
        }
        publish_idle(&codex, &thread_id, &updates).await?;
    }

    finish_session(&codex, &mut thread, config.headless && !shutdown, &updates).await
}

async fn publish_idle(
    codex: &Codex,
    thread_id: &ThreadId,
    updates: &Sender<AppUpdate>,
) -> Result<(), String> {
    refresh_thread_list(
        codex,
        thread_id,
        None,
        TaskStatusPresentation::Idle,
        updates,
    )
    .await?;
    send_status(updates, "Ready for another message").await;
    Ok(())
}

async fn finish_session(
    codex: &Codex,
    thread: &mut Option<CodexThread>,
    completed: bool,
    updates: &Sender<AppUpdate>,
) -> Result<(), String> {
    if completed {
        send_status(updates, "Turn complete").await;
    }
    updates.send(AppUpdate::Prompt(None)).await.ok();
    if let Some(thread) = thread.take() {
        thread.close().await.map_err(|error| error.to_string())?;
    }
    codex.close().await.map_err(|error| error.to_string())
}

async fn observe_thread(
    codex: &Codex,
    thread_id: &ThreadId,
) -> Result<CanonicalObservation, String> {
    codex
        .client()
        .observe_canonical(StateObservationScope::thread(thread_id.clone()))
        .await
        .map_err(|error| error.to_string())
}

async fn next_queued_launch(
    codex: &Codex,
    thread: &CodexThread,
    thread_id: &ThreadId,
    outcome: &TurnOutcome,
    queue_enabled: bool,
    observation: &mut CanonicalObservation,
    updates: &Sender<AppUpdate>,
) -> Result<Option<TurnLaunch>, String> {
    if !queue_enabled {
        return Ok(None);
    }
    if !outcome.queue_changed && !outcome.check_queue_after {
        return Ok(None);
    }
    if queue_has_items(thread).await? {
        send_status(updates, "Starting queued follow-up…").await;
        return Ok(Some(TurnLaunch::Queued {
            after: outcome.completed_turn_id.clone(),
        }));
    }
    if outcome.queue_changed
        && let Some(turn_id) =
            wait_for_successor_turn(codex, thread_id, &outcome.completed_turn_id, observation)
                .await?
    {
        send_status(updates, "Following auto-started queued turn…").await;
        return Ok(Some(TurnLaunch::Existing(turn_id)));
    }
    Ok(None)
}

async fn wait_for_successor_turn(
    codex: &Codex,
    thread_id: &ThreadId,
    completed_turn_id: &codex_app_server_state::TurnId,
    observation: &mut CanonicalObservation,
) -> Result<Option<codex_app_server_state::TurnId>, String> {
    for _ in 0..40 {
        let state = codex
            .client()
            .canonical_snapshot()
            .await
            .map_err(|error| error.to_string())?;
        if let Some(thread) = state.threads.get(thread_id)
            && let Some(index) = thread
                .turn_ids
                .iter()
                .position(|turn_id| turn_id == completed_turn_id)
            && let Some(successor) = thread.turn_ids.get(index + 1)
        {
            return Ok(Some(successor.clone()));
        }
        let _ =
            tokio::time::timeout(std::time::Duration::from_millis(50), observation.changed()).await;
    }
    Ok(None)
}

async fn start_initial_thread(
    codex: &Codex,
    config: &RunConfiguration,
    turn_options: &TurnOptions,
    updates: &Sender<AppUpdate>,
) -> Result<(CodexThread, ThreadId), String> {
    send_status(updates, "Starting thread…").await;
    let thread = codex
        .start_thread(StartThreadOptions {
            cwd: Some(config.cwd.clone()),
            model: turn_options.model.clone(),
            ephemeral: Some(config.ephemeral),
            ..StartThreadOptions::default()
        })
        .await
        .map_err(|error| error.to_string())?;
    let thread_id = thread.id().clone();
    refresh_thread_list(
        codex,
        &thread_id,
        Some(&config.cwd),
        if config.headless || config.prompt_explicit {
            TaskStatusPresentation::Running
        } else {
            TaskStatusPresentation::Idle
        },
        updates,
    )
    .await?;
    Ok((thread, thread_id))
}

struct TurnOutcome {
    shutdown: bool,
    pending_selection: Option<ThreadId>,
    pending_model: Option<ModelSelectionEvent>,
    queue_changed: bool,
    check_queue_after: bool,
    completed_turn_id: codex_app_server_state::TurnId,
}

enum TurnLaunch {
    Input {
        text: String,
        attachments: Vec<ComposerAttachment>,
    },
    Queued {
        after: codex_app_server_state::TurnId,
    },
    Existing(codex_app_server_state::TurnId),
}

struct TurnDriver<'a> {
    session_observation: &'a mut SessionObservation,
    canonical_observation: &'a mut CanonicalObservation,
    commands: &'a Receiver<HostCommand>,
    updates: &'a Sender<AppUpdate>,
    next_queue_id: &'a mut u64,
    queue_enabled: bool,
}

impl TurnDriver<'_> {
    async fn handle_command(
        &mut self,
        command: Result<HostCommand, async_channel::RecvError>,
        codex: &Codex,
        thread: &CodexThread,
        turn: &codex_app_server_sdk::CodexTurn,
        outcome: &mut TurnOutcome,
    ) -> Result<(), String> {
        match command {
            Ok(HostCommand::Prompt(intent)) => handle_prompt(codex.client(), intent).await?,
            Ok(HostCommand::Submit {
                text,
                attachments,
                active_behavior,
            }) => match active_behavior {
                ActiveSubmitBehavior::Steer => turn
                    .steer(composer_submission_inputs(text, &attachments))
                    .await
                    .map_err(|error| error.to_string())?,
                ActiveSubmitBehavior::Queue => {
                    if !self.queue_enabled {
                        send_status(
                            self.updates,
                            "Durable queue is unavailable for ephemeral tasks",
                        )
                        .await;
                        return Ok(());
                    }
                    let queue_id = *self.next_queue_id;
                    *self.next_queue_id = self
                        .next_queue_id
                        .checked_add(1)
                        .ok_or_else(|| "queue client identity exhausted".to_owned())?;
                    match thread
                        .queue_add(
                            composer_submission_inputs(text, &attachments),
                            format!("codex-gpui-{}-{queue_id}", thread.id()),
                        )
                        .await
                    {
                        Ok(_) => {
                            outcome.queue_changed = true;
                            publish_queue(thread, self.updates).await?;
                        }
                        Err(error) => {
                            send_status(self.updates, &format!("Queue failed: {error}")).await;
                        }
                    }
                }
            },
            Ok(HostCommand::Interrupt) => {
                turn.interrupt().await.map_err(|error| error.to_string())?;
            }
            Ok(HostCommand::NewChat) => {
                send_status(
                    self.updates,
                    "Finish the active turn before starting a new chat",
                )
                .await;
            }
            Ok(HostCommand::Search) => {
                send_status(
                    self.updates,
                    "Search is available after this turn completes",
                )
                .await;
            }
            Ok(HostCommand::SelectThread(selected)) => {
                outcome.pending_selection = Some(selected);
                send_status(
                    self.updates,
                    "Task switch queued until the active turn completes…",
                )
                .await;
            }
            Ok(HostCommand::SelectModel(selection)) => {
                outcome.pending_model = Some(selection);
                send_status(self.updates, "Model change queued for the next turn…").await;
            }
            Ok(HostCommand::Queue(event)) => {
                if !self.queue_enabled {
                    send_status(
                        self.updates,
                        "Durable queue is unavailable for ephemeral tasks",
                    )
                    .await;
                    return Ok(());
                }
                handle_queue_event(thread, event).await?;
                publish_queue(thread, self.updates).await?;
            }
            Ok(HostCommand::Goal(event)) => {
                handle_goal_event(thread, event, self.updates).await;
            }
            Ok(HostCommand::Login(_)) => {}
            Ok(HostCommand::Shutdown) | Err(_) => outcome.shutdown = true,
        }
        Ok(())
    }
}

async fn drive_turn(
    codex: &Codex,
    thread: &CodexThread,
    thread_id: &ThreadId,
    launch: TurnLaunch,
    queue_enabled: bool,
    options: &TurnOptions,
    mut driver: TurnDriver<'_>,
) -> Result<TurnOutcome, String> {
    send_status(driver.updates, "Running turn…").await;
    let check_queue_after = !matches!(&launch, TurnLaunch::Input { .. });
    let turn = match launch {
        TurnLaunch::Input { text, attachments } => {
            thread
                .start_turn(
                    composer_submission_inputs(text, &attachments),
                    options.clone(),
                )
                .await
        }
        TurnLaunch::Queued { after } => match thread.queue_start(None).await {
            Ok(turn) => Ok(turn),
            Err(start_error) => {
                let successor =
                    wait_for_successor_turn(codex, thread_id, &after, driver.canonical_observation)
                        .await?;
                match successor {
                    Some(turn_id) => thread.retain_turn(turn_id).await,
                    None => Err(start_error),
                }
            }
        },
        TurnLaunch::Existing(turn_id) => thread.retain_turn(turn_id).await,
    }
    .map_err(|error| error.to_string())?;
    driver.updates.send(AppUpdate::TurnActive(true)).await.ok();
    if queue_enabled {
        publish_queue(thread, driver.updates).await?;
    }
    let turn_key = TurnKey {
        thread_id: thread_id.clone(),
        turn_id: turn.id().clone(),
    };
    let mut outcome = TurnOutcome {
        shutdown: false,
        pending_selection: None,
        pending_model: None,
        queue_changed: false,
        check_queue_after,
        completed_turn_id: turn.id().clone(),
    };
    let (mut terminal, mut projected_revision) =
        publish_current(codex.client(), thread_id, &turn_key, driver.updates).await?;
    while !terminal {
        tokio::select! {
            changed = driver.canonical_observation.changed() => {
                let changed = changed.map_err(|error| error.to_string())?;
                if changed > projected_revision {
                    let (state, is_terminal) = publish_transcript(
                        codex.client(), thread_id, Some(&turn_key), driver.updates
                    ).await?;
                    projected_revision = state.revision;
                    terminal = is_terminal;
                }
            }
            changed = driver.session_observation.changed() => {
                changed.map_err(|error| error.to_string())?;
                publish_pending(codex.client(), driver.updates).await?;
            }
            command = driver.commands.recv() => {
                driver.handle_command(command, codex, thread, &turn, &mut outcome).await?;
                if outcome.shutdown {
                    break;
                }
            }
        }
    }
    turn.close().await.map_err(|error| error.to_string())?;
    driver.updates.send(AppUpdate::TurnActive(false)).await.ok();
    Ok(outcome)
}

async fn switch_thread(
    codex: &Codex,
    previous: &mut Option<CodexThread>,
    selected: ThreadId,
    updates: &Sender<AppUpdate>,
) -> Result<CodexThread, String> {
    send_status(updates, "Loading selected task…").await;
    let replacement = codex
        .resume_thread_hydrated(selected.clone(), PaginatedResumeOptions::default())
        .await
        .map_err(|error| error.to_string())?;
    refresh_goal_for_selection(&replacement, updates).await;
    if let Some(previous) = previous.take() {
        previous.close().await.map_err(|error| error.to_string())?;
    }
    publish_selected(codex.client(), &selected, updates).await?;
    refresh_thread_list(
        codex,
        &selected,
        None,
        TaskStatusPresentation::Idle,
        updates,
    )
    .await?;
    send_status(updates, "Ready for another message").await;
    Ok(replacement)
}

async fn refresh_thread_list(
    codex: &Codex,
    selected: &ThreadId,
    selected_cwd: Option<&std::path::Path>,
    selected_status: TaskStatusPresentation,
    updates: &Sender<AppUpdate>,
) -> Result<(), String> {
    let page = codex
        .list_threads(ListThreadsOptions {
            limit: Some(100),
            ..ListThreadsOptions::default()
        })
        .await
        .map_err(|error| error.to_string())?;
    let mut presentation = project_thread_list(&page, Some(selected));
    if !presentation
        .rows
        .iter()
        .any(|row| &row.thread_id == selected)
    {
        presentation.rows.insert(
            0,
            ThreadListRow {
                thread_id: selected.clone(),
                title: "Current task".to_owned(),
                cwd: selected_cwd
                    .map(|path| path.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                updated_at: current_unix_seconds(),
                status: selected_status,
                is_selected: true,
            },
        );
    }
    updates
        .send(AppUpdate::ThreadList(presentation))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())
}

async fn load_model_catalog(
    codex: &Codex,
    updates: &Sender<AppUpdate>,
) -> Result<TurnOptions, String> {
    let page = codex
        .list_models(ListModelsOptions {
            limit: Some(100),
            ..ListModelsOptions::default()
        })
        .await
        .map_err(|error| error.to_string())?;
    let presentation = project_model_picker(&page, None, None);
    let options = TurnOptions {
        model: (!presentation.selected_model.is_empty())
            .then(|| presentation.selected_model.clone()),
        effort: (!presentation.selected_effort.is_empty())
            .then(|| presentation.selected_effort.clone()),
        ..TurnOptions::default()
    };
    updates
        .send(AppUpdate::ModelPicker(presentation))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    Ok(options)
}

fn apply_model_selection(options: &mut TurnOptions, selection: &ModelSelectionEvent) {
    options.model = Some(selection.model.clone());
    options.effort = Some(selection.effort.clone());
}

async fn queue_has_items(thread: &CodexThread) -> Result<bool, String> {
    thread
        .queue_list(None, Some(1))
        .await
        .map(|page| !page.data.is_empty())
        .map_err(|error| error.to_string())
}

async fn publish_queue(thread: &CodexThread, updates: &Sender<AppUpdate>) -> Result<(), String> {
    let page = thread
        .queue_list(None, Some(100))
        .await
        .map_err(|error| error.to_string())?;
    updates
        .send(AppUpdate::Queue(project_queue(&page)))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())
}

async fn refresh_goal(thread: &CodexThread, updates: &Sender<AppUpdate>) -> Result<(), String> {
    let goal = thread.get_goal().await.map_err(|error| error.to_string())?;
    updates
        .send(AppUpdate::Goal(project_goal(goal.as_ref())))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())
}

async fn refresh_goal_for_selection(thread: &CodexThread, updates: &Sender<AppUpdate>) {
    if let Err(error) = refresh_goal(thread, updates).await {
        updates.send(AppUpdate::Goal(None)).await.ok();
        send_status(updates, &format!("Goal refresh failed: {error}")).await;
    }
}

async fn handle_goal_event(thread: &CodexThread, event: GoalEvent, updates: &Sender<AppUpdate>) {
    match execute_goal_event(thread, event).await {
        Ok(status) => match refresh_goal(thread, updates).await {
            Ok(()) => send_status(updates, status).await,
            Err(error) => {
                send_status(
                    updates,
                    &format!("{status}, but the goal could not be refreshed: {error}"),
                )
                .await;
            }
        },
        Err(error) => send_status(updates, &format!("Goal update failed: {error}")).await,
    }
}

async fn handle_queue_event(thread: &CodexThread, event: QueueEvent) -> Result<(), String> {
    match event {
        QueueEvent::Remove { id } => {
            thread
                .queue_delete(&id)
                .await
                .map_err(|error| error.to_string())?;
        }
        QueueEvent::Reorder { ids } => thread
            .queue_reorder(ids)
            .await
            .map_err(|error| error.to_string())?,
    }
    Ok(())
}

async fn publish_current(
    client: &AppServerClient,
    thread_id: &ThreadId,
    turn_key: &TurnKey,
    updates: &Sender<AppUpdate>,
) -> Result<(bool, codex_app_server_state::StateRevision), String> {
    publish_pending(client, updates).await?;
    let (state, terminal) = publish_transcript(client, thread_id, Some(turn_key), updates).await?;
    Ok((terminal, state.revision))
}

async fn publish_selected(
    client: &AppServerClient,
    thread_id: &ThreadId,
    updates: &Sender<AppUpdate>,
) -> Result<codex_app_server_state::CanonicalState, String> {
    publish_pending(client, updates).await?;
    Ok(publish_transcript(client, thread_id, None, updates)
        .await?
        .0)
}

async fn publish_pending(
    client: &AppServerClient,
    updates: &Sender<AppUpdate>,
) -> Result<(), String> {
    resolve_defaults(client).await?;
    let session = client.snapshot().await.map_err(|error| error.to_string())?;
    let pending = parse_pending(&session).map_err(|error| error.to_string())?;
    updates
        .send(AppUpdate::Prompt(pending.first().map(project_prompt)))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())
}

async fn publish_transcript(
    client: &AppServerClient,
    thread_id: &ThreadId,
    turn_key: Option<&TurnKey>,
    updates: &Sender<AppUpdate>,
) -> Result<(codex_app_server_state::CanonicalState, bool), String> {
    let state = client
        .canonical_snapshot()
        .await
        .map_err(|error| error.to_string())?;
    let transcript = TranscriptV2Projector::project(&state, thread_id, &StandardItemPolicy);
    let root = ThreadGraphKey::new(LOCAL_HOST_ID, thread_id.clone());
    let graph = ThreadGraphProjector::project(&state, LOCAL_HOST_ID);
    updates
        .send(AppUpdate::Canonical {
            transcript,
            root,
            graph,
        })
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    updates
        .send(AppUpdate::Goal(project_goal(
            state
                .threads
                .get(thread_id)
                .and_then(|thread| thread.goal.as_ref()),
        )))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    let terminal = turn_key.is_some_and(|turn_key| {
        state
            .turns
            .get(turn_key)
            .is_some_and(|turn| turn.status.is_terminal())
    });
    Ok((state, terminal))
}

async fn resolve_defaults(client: &AppServerClient) -> Result<(), String> {
    let snapshot = client.snapshot().await.map_err(|error| error.to_string())?;
    let pending = parse_pending(&snapshot).map_err(|error| error.to_string())?;
    for request in pending {
        if let Some(reply) = default_resolution(&request, current_unix_seconds()) {
            client
                .resolve_server_request(request.key, reply.into_resolution())
                .await
                .map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

enum IdleAction {
    Submit {
        text: String,
        attachments: Vec<ComposerAttachment>,
    },
    Select(ThreadId),
    NewChat,
    Search,
    SelectModel(ModelSelectionEvent),
    Queue(QueueEvent),
    Goal(GoalEvent),
    Shutdown,
}

async fn next_idle_action(
    client: &AppServerClient,
    thread_id: &ThreadId,
    observation: &mut CanonicalObservation,
    commands: &Receiver<HostCommand>,
    updates: &Sender<AppUpdate>,
) -> Result<IdleAction, String> {
    loop {
        tokio::select! {
            changed = observation.changed() => {
                changed.map_err(|error| error.to_string())?;
                publish_transcript(client, thread_id, None, updates).await?;
            }
            command = commands.recv() => match command {
                Ok(HostCommand::Submit { text, attachments, .. }) => {
                    return Ok(IdleAction::Submit { text, attachments });
                }
                Ok(HostCommand::SelectThread(thread_id)) => {
                    return Ok(IdleAction::Select(thread_id));
                }
                Ok(HostCommand::NewChat) => return Ok(IdleAction::NewChat),
                Ok(HostCommand::Search) => return Ok(IdleAction::Search),
                Ok(HostCommand::SelectModel(selection)) => {
                    return Ok(IdleAction::SelectModel(selection));
                }
                Ok(HostCommand::Queue(event)) => return Ok(IdleAction::Queue(event)),
                Ok(HostCommand::Goal(event)) => return Ok(IdleAction::Goal(event)),
                Ok(HostCommand::Prompt(intent)) => handle_prompt(client, intent).await?,
                Ok(HostCommand::Interrupt | HostCommand::Login(_)) => {}
                Ok(HostCommand::Shutdown) | Err(_) => return Ok(IdleAction::Shutdown),
            }
        }
    }
}

async fn handle_prompt(client: &AppServerClient, intent: PromptIntent) -> Result<(), String> {
    let snapshot = client.snapshot().await.map_err(|error| error.to_string())?;
    let request = parse_pending(&snapshot)
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|request| request.key == intent.key)
        .ok_or_else(|| "prompt was already resolved".to_owned())?;
    let Some(reply) = reply_for_intent(
        &request,
        intent.action,
        intent.answers.as_ref(),
        intent.mcp_content.as_ref(),
    ) else {
        return Ok(());
    };
    client
        .resolve_server_request(request.key, reply.into_resolution())
        .await
        .map_err(|error| error.to_string())
}

fn reply_for_intent(
    request: &TypedServerRequest,
    action: PromptActionKind,
    answers: Option<&std::collections::BTreeMap<String, Vec<String>>>,
    mcp_content: Option<&serde_json::Value>,
) -> Option<ServerRequestReply> {
    let approved = action == PromptActionKind::Approve;
    let declined = action == PromptActionKind::Decline;
    match &request.body {
        ServerRequestBody::CommandApproval { .. } if approved || declined => {
            Some(ServerRequestReply::CommandDecision(json!(if approved {
                "accept"
            } else {
                "decline"
            })))
        }
        ServerRequestBody::FileChangeApproval { .. } if approved || declined => {
            Some(ServerRequestReply::FileDecision(json!(if approved {
                "accept"
            } else {
                "decline"
            })))
        }
        ServerRequestBody::PermissionsApproval { permissions, .. } if approved => {
            Some(ServerRequestReply::Permissions {
                permissions: permissions.clone(),
                scope: None,
                strict_auto_review: None,
            })
        }
        ServerRequestBody::PermissionsApproval { .. } if declined => Some(user_declined()),
        ServerRequestBody::LegacyExecApproval { .. }
        | ServerRequestBody::LegacyPatchApproval { .. }
            if approved || declined =>
        {
            Some(ServerRequestReply::LegacyDecision(if approved {
                json!("approved")
            } else {
                json!({"denied": {"rejection": "User declined"}})
            }))
        }
        ServerRequestBody::McpElicitation { .. } if declined => {
            Some(ServerRequestReply::McpElicitation {
                action: "decline".to_owned(),
                content: None,
                metadata: None,
            })
        }
        ServerRequestBody::McpElicitation { metadata, .. }
            if action == PromptActionKind::Respond && mcp_content.is_some() =>
        {
            Some(ServerRequestReply::McpElicitation {
                action: "accept".to_owned(),
                content: mcp_content.cloned(),
                metadata: metadata.clone(),
            })
        }
        ServerRequestBody::UserInput { .. } if action == PromptActionKind::Respond => answers
            .cloned()
            .map(|answers| ServerRequestReply::UserInput { answers }),
        _ => None,
    }
}

fn user_declined() -> ServerRequestReply {
    ServerRequestReply::Error(JsonRpcErrorObject {
        code: -32_000,
        message: "User declined additional permissions".to_owned(),
        data: None,
    })
}

async fn send_status(updates: &Sender<AppUpdate>, status: &str) {
    updates
        .send(AppUpdate::Status(status.to_owned()))
        .await
        .ok();
}

fn composer_model_label(presentation: &ModelPickerPresentation) -> String {
    let display_name = presentation
        .models
        .iter()
        .find(|model| model.model == presentation.selected_model)
        .map(|model| model.display_name.as_str())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or(presentation.selected_model.as_str());
    if display_name.trim().is_empty() {
        return "Model".to_owned();
    }
    let effort = display_reasoning_effort(&presentation.selected_effort);
    if effort.is_empty() {
        return display_name.to_owned();
    }
    format!("{display_name} · {effort}")
}

fn composer_submission_inputs(
    text: impl Into<String>,
    attachments: &[ComposerAttachment],
) -> Vec<CodexInput> {
    let text = text.into();
    let mut inputs = Vec::with_capacity(attachments.len() + 1);
    if !text.trim().is_empty() {
        inputs.push(CodexInput::text(text));
    }
    inputs.extend(attachments.iter().map(composer_attachment_input));
    inputs
}

fn attachment_picker_options() -> PathPromptOptions {
    PathPromptOptions {
        files: true,
        directories: true,
        multiple: true,
        prompt: Some("Add files and folders".into()),
    }
}

fn composer_attachment_input(attachment: &ComposerAttachment) -> CodexInput {
    let path = attachment.path().to_path_buf();
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase);
    if extension.as_deref().is_some_and(is_image_extension) {
        CodexInput::LocalImage { path, detail: None }
    } else if extension.as_deref().is_some_and(is_audio_extension) {
        CodexInput::LocalAudio(path)
    } else {
        CodexInput::Mention {
            name: composer_attachment_name(attachment.path()),
            path,
        }
    }
}

fn composer_attachment_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map_or_else(|| "attachment".to_owned(), str::to_owned)
}

fn is_image_extension(extension: &str) -> bool {
    matches!(
        extension,
        "avif" | "bmp" | "gif" | "heic" | "jpeg" | "jpg" | "png" | "tif" | "tiff" | "webp"
    )
}

fn is_audio_extension(extension: &str) -> bool {
    matches!(
        extension,
        "aac" | "flac" | "m4a" | "mp3" | "ogg" | "wav" | "webm"
    )
}

fn current_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or_default()
}

fn is_allowed_external_url(destination: &str) -> bool {
    let Ok(url) = url::Url::parse(destination) else {
        return false;
    };
    matches!(url.scheme(), "http" | "https")
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use codex_app_server_client::ServerRequestKey;
    use codex_app_server_interaction::{InteractionScope, McpElicitationMode, UserQuestion};
    use codex_app_server_wire::JsonRpcId;

    use super::*;

    #[test]
    fn external_link_policy_allows_only_network_urls_without_credentials() {
        assert!(is_allowed_external_url("https://example.com/docs"));
        assert!(is_allowed_external_url("http://localhost:3000"));
        assert!(!is_allowed_external_url("javascript:alert(1)"));
        assert!(!is_allowed_external_url("data:text/plain,secret"));
        assert!(!is_allowed_external_url("file:///tmp/private"));
        assert!(!is_allowed_external_url("https://user:pass@example.com"));
        assert!(!is_allowed_external_url("/relative/path"));
    }

    #[test]
    fn maps_only_explicit_command_approval_intents() {
        let request = TypedServerRequest {
            key: ServerRequestKey {
                connection_epoch: 2,
                request_id: JsonRpcId::Integer(7),
            },
            body: ServerRequestBody::CommandApproval {
                scope: InteractionScope {
                    thread_id: ThreadId::from("thread"),
                    turn_id: None,
                    item_id: None,
                },
                command: Some("pwd".to_owned()),
                cwd: Some("/workspace".to_owned()),
                reason: None,
                available_decisions: Vec::new(),
                additional_permissions: None,
            },
            raw_params: BTreeMap::new(),
        };
        assert_eq!(
            reply_for_intent(&request, PromptActionKind::Approve, None, None),
            Some(ServerRequestReply::CommandDecision(json!("accept")))
        );
        assert_eq!(
            reply_for_intent(&request, PromptActionKind::Respond, None, None),
            None
        );
    }

    #[test]
    fn maps_complete_user_answers_to_typed_reply() {
        let request = TypedServerRequest {
            key: ServerRequestKey {
                connection_epoch: 2,
                request_id: JsonRpcId::Integer(8),
            },
            body: ServerRequestBody::UserInput {
                scope: InteractionScope {
                    thread_id: ThreadId::from("thread"),
                    turn_id: None,
                    item_id: None,
                },
                is_blocking: true,
                questions: vec![UserQuestion {
                    id: "choice".to_owned(),
                    header: "Choice".to_owned(),
                    question: "Pick one".to_owned(),
                    is_secret: false,
                    is_other_allowed: false,
                    options: Vec::new(),
                }],
            },
            raw_params: BTreeMap::new(),
        };
        let answers = BTreeMap::from([("choice".to_owned(), vec!["Safe".to_owned()])]);
        assert_eq!(
            reply_for_intent(&request, PromptActionKind::Respond, Some(&answers), None,),
            Some(ServerRequestReply::UserInput { answers })
        );
    }

    #[test]
    fn model_selection_updates_next_turn_as_one_pair() {
        let mut options = TurnOptions::default();
        apply_model_selection(
            &mut options,
            &ModelSelectionEvent {
                model: "model".to_owned(),
                effort: "high".to_owned(),
            },
        );
        assert_eq!(options.model.as_deref(), Some("model"));
        assert_eq!(options.effort.as_deref(), Some("high"));
    }

    #[test]
    fn composer_model_label_uses_catalog_name_and_human_effort() {
        let presentation = ModelPickerPresentation {
            models: vec![codex_presentation::ModelChoicePresentation {
                model: "gpt-5.6-sol".to_owned(),
                display_name: "5.6 Sol".to_owned(),
                description: String::new(),
                is_default: true,
                default_effort: "xhigh".to_owned(),
                efforts: Vec::new(),
            }],
            selected_model: "gpt-5.6-sol".to_owned(),
            selected_effort: "xhigh".to_owned(),
        };
        assert_eq!(composer_model_label(&presentation), "5.6 Sol · Extra High");
    }

    #[test]
    fn composer_model_label_title_cases_all_known_efforts() {
        let model = codex_presentation::ModelChoicePresentation {
            model: "model".to_owned(),
            display_name: "Model".to_owned(),
            description: String::new(),
            is_default: true,
            default_effort: "medium".to_owned(),
            efforts: Vec::new(),
        };
        for (wire, label) in [
            ("none", "None"),
            ("minimal", "Minimal"),
            ("low", "Low"),
            ("medium", "Medium"),
            ("high", "High"),
            ("xhigh", "Extra High"),
            ("max", "Maximum"),
            ("ultra", "Ultra"),
        ] {
            let presentation = ModelPickerPresentation {
                models: vec![model.clone()],
                selected_model: "model".to_owned(),
                selected_effort: wire.to_owned(),
            };
            assert_eq!(
                composer_model_label(&presentation),
                format!("Model · {label}")
            );
        }
    }

    #[test]
    fn composer_submission_inputs_encode_multiline_text_and_typed_paths() {
        let attachments = vec![
            ComposerAttachment::new("/tmp/diagram.png"),
            ComposerAttachment::new("/tmp/notes.md"),
            ComposerAttachment::new("/tmp/recording.m4a"),
            ComposerAttachment::new("/tmp/project"),
        ];
        let inputs = composer_submission_inputs("first line\nsecond line", &attachments);
        let values = inputs
            .into_iter()
            .map(CodexInput::into_value)
            .collect::<Vec<_>>();
        assert_eq!(
            values,
            vec![
                json!({"type": "text", "text": "first line\nsecond line"}),
                json!({"type": "localImage", "path": "/tmp/diagram.png"}),
                json!({"type": "mention", "name": "notes.md", "path": "/tmp/notes.md"}),
                json!({"type": "localAudio", "path": "/tmp/recording.m4a"}),
                json!({"type": "mention", "name": "project", "path": "/tmp/project"}),
            ]
        );
    }

    #[test]
    fn composer_submission_inputs_allow_attachment_only_turns() {
        let inputs = composer_submission_inputs("", &[ComposerAttachment::new("/tmp/README.md")]);
        assert_eq!(
            inputs
                .into_iter()
                .map(CodexInput::into_value)
                .collect::<Vec<_>>(),
            vec![json!({
                "type": "mention",
                "name": "README.md",
                "path": "/tmp/README.md"
            })]
        );
    }

    #[test]
    fn attachment_picker_allows_multiple_files_and_directories() {
        let options = attachment_picker_options();
        assert!(options.files);
        assert!(options.directories);
        assert!(options.multiple);
        assert_eq!(options.prompt.as_deref(), Some("Add files and folders"));
    }

    #[test]
    fn subagent_selection_accepts_only_the_local_host() {
        let local = SubagentSelectionEvent {
            key: ThreadGraphKey::new(LOCAL_HOST_ID, ThreadId::from("child")),
        };
        let remote = SubagentSelectionEvent {
            key: ThreadGraphKey::new("remote", ThreadId::from("child")),
        };
        assert_eq!(
            selected_subagent_thread(&local)
                .as_ref()
                .map(ThreadId::as_str),
            Some("child")
        );
        assert_eq!(selected_subagent_thread(&remote), None);
    }

    #[test]
    fn maps_mcp_form_content_to_accept_reply_with_metadata() {
        let request = TypedServerRequest {
            key: ServerRequestKey {
                connection_epoch: 2,
                request_id: JsonRpcId::Integer(9),
            },
            body: ServerRequestBody::McpElicitation {
                scope: InteractionScope {
                    thread_id: ThreadId::from("thread"),
                    turn_id: None,
                    item_id: None,
                },
                server_name: "server".to_owned(),
                message: "Configure".to_owned(),
                mode: McpElicitationMode::Form {
                    requested_schema: json!({"type": "object"}),
                },
                metadata: Some(json!({"request": "meta"})),
            },
            raw_params: BTreeMap::new(),
        };
        let content = json!({"name": "value"});
        assert_eq!(
            reply_for_intent(&request, PromptActionKind::Respond, None, Some(&content),),
            Some(ServerRequestReply::McpElicitation {
                action: "accept".to_owned(),
                content: Some(content),
                metadata: Some(json!({"request": "meta"})),
            })
        );
    }
}
