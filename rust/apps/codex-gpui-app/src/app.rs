use std::time::{SystemTime, UNIX_EPOCH};

use async_channel::{Receiver, Sender};
use codex_app_server_client::{
    AppServerClient, CanonicalObservation, LocalSessionConfig, SessionObservation,
};
use codex_app_server_interaction::{
    ServerRequestBody, ServerRequestReply, TypedServerRequest, default_resolution, parse_pending,
};
use codex_app_server_sdk::{
    Codex, CodexInput, CodexThread, ListModelsOptions, ListThreadsOptions, PaginatedResumeOptions,
    StartThreadOptions, TurnOptions,
};
use codex_app_server_state::{StateObservationScope, ThreadId, TurnKey};
use codex_app_server_wire::JsonRpcErrorObject;
use codex_gpui::{
    ActiveSubmitBehavior, CodexComposer, CodexModelPicker, CodexPrompt, CodexQueue,
    CodexThreadList, CodexTranscript, ComposerEvent, ModelSelectionEvent, PromptIntent, QueueEvent,
    ThreadSelectionEvent,
};
use codex_presentation::{
    ModelPickerPresentation, PromptActionKind, PromptPresentation, QueuePresentation,
    StandardItemPolicy, TaskStatusPresentation, ThreadListPresentation, ThreadListRow,
    TranscriptPresentation, TranscriptProjector, project_model_picker, project_prompt,
    project_queue, project_thread_list,
};
use gpui::{
    App, AppContext, Bounds, Context, Entity, Render, Subscription, Task, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, rgb, size,
};
use gpui_platform::application;
use gpui_tokio::Tokio;
use serde_json::json;

use crate::config::RunConfiguration;

const UPDATE_CAPACITY: usize = 32;
const COMMAND_CAPACITY: usize = 16;

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
        let bounds = Bounds::centered(None, size(px(1_040.), px(780.)), cx);
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
            AppUpdate::Transcript(presentation) => println!(
                "transcript: revision={} turns={}",
                presentation.revision.get(),
                presentation.turns.len()
            ),
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
    Transcript(TranscriptPresentation),
    Prompt(Option<PromptPresentation>),
    ModelPicker(ModelPickerPresentation),
    ThreadList(ThreadListPresentation),
    Queue(QueuePresentation),
    TurnActive(bool),
    Failed(String),
}

#[derive(Clone, Debug)]
enum HostCommand {
    Prompt(PromptIntent),
    Submit {
        text: String,
        active_behavior: ActiveSubmitBehavior,
    },
    Interrupt,
    SelectThread(ThreadId),
    SelectModel(ModelSelectionEvent),
    Queue(QueueEvent),
    Shutdown,
}

struct CodexApp {
    transcript: Entity<CodexTranscript>,
    thread_list: Entity<CodexThreadList>,
    model_picker: Entity<CodexModelPicker>,
    queue: Entity<CodexQueue>,
    composer: Entity<CodexComposer>,
    prompt: Option<Entity<CodexPrompt>>,
    prompt_subscription: Option<Subscription>,
    _composer_subscription: Subscription,
    _thread_list_subscription: Subscription,
    _model_picker_subscription: Subscription,
    _queue_subscription: Subscription,
    _quit_subscription: Subscription,
    status: String,
    command_sender: Sender<HostCommand>,
    _session_task: Task<Result<(), gpui_tokio::JoinError>>,
    _update_task: Task<()>,
}

struct InitialViews {
    transcript: Entity<CodexTranscript>,
    thread_list: Entity<CodexThreadList>,
    model_picker: Entity<CodexModelPicker>,
    queue: Entity<CodexQueue>,
    composer: Entity<CodexComposer>,
}

fn initial_views(cx: &mut Context<CodexApp>) -> InitialViews {
    let pending = TranscriptPresentation {
        revision: codex_app_server_state::StateRevision::ZERO,
        thread_id: ThreadId::from("pending"),
        turns: Vec::new(),
    };
    InitialViews {
        transcript: cx.new(|_| CodexTranscript::new(&pending)),
        thread_list: cx.new(|_| {
            CodexThreadList::new(ThreadListPresentation {
                rows: Vec::new(),
                next_cursor: None,
                backwards_cursor: None,
            })
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
        composer: cx.new(CodexComposer::new),
    }
}

impl CodexApp {
    fn new(config: RunConfiguration, cx: &mut Context<Self>) -> Self {
        let InitialViews {
            transcript,
            thread_list,
            model_picker,
            queue,
            composer,
        } = initial_views(cx);
        let (update_sender, update_receiver) = async_channel::bounded(UPDATE_CAPACITY);
        let (command_sender, command_receiver) = async_channel::bounded(COMMAND_CAPACITY);
        let composer_sender = command_sender.clone();
        let composer_subscription =
            cx.subscribe(&composer, move |_, _, event: &ComposerEvent, _| {
                let command = match event {
                    ComposerEvent::Submit {
                        text,
                        active_behavior,
                    } => HostCommand::Submit {
                        text: text.clone(),
                        active_behavior: *active_behavior,
                    },
                    ComposerEvent::Interrupt => HostCommand::Interrupt,
                };
                let _ = composer_sender.try_send(command);
            });
        let selection_sender = command_sender.clone();
        let thread_list_subscription = cx.subscribe(
            &thread_list,
            move |_, _, event: &ThreadSelectionEvent, _| {
                let _ =
                    selection_sender.try_send(HostCommand::SelectThread(event.thread_id.clone()));
            },
        );
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
            model_picker,
            queue,
            composer,
            prompt: None,
            prompt_subscription: None,
            _composer_subscription: composer_subscription,
            _thread_list_subscription: thread_list_subscription,
            _model_picker_subscription: model_picker_subscription,
            _queue_subscription: queue_subscription,
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
            AppUpdate::Transcript(presentation) => {
                self.transcript.update(cx, |transcript, cx| {
                    transcript.set_presentation(&presentation, cx);
                });
            }
            AppUpdate::Prompt(presentation) => self.install_prompt(presentation, cx),
            AppUpdate::ModelPicker(presentation) => {
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
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(rgb(0x0017_1717))
            .text_color(rgb(0x00f2_f2f2))
            .child(
                div()
                    .flex_shrink_0()
                    .px_5()
                    .py_3()
                    .border_b_1()
                    .border_color(rgb(0x003a_3a3a))
                    .text_sm()
                    .text_color(rgb(0x00a3_a3a3))
                    .child(self.status.clone()),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .overflow_hidden()
                    .child(
                        div()
                            .w(px(280.))
                            .h_full()
                            .flex_shrink_0()
                            .border_r_1()
                            .border_color(rgb(0x003a_3a3a))
                            .child(self.thread_list.clone()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .overflow_hidden()
                            .child(self.transcript.clone()),
                    )
                    .child(
                        div()
                            .w(px(260.))
                            .h_full()
                            .flex_shrink_0()
                            .border_l_1()
                            .border_color(rgb(0x003a_3a3a))
                            .child(self.model_picker.clone()),
                    ),
            )
            .when_some(self.prompt.clone(), |view, prompt| {
                view.child(div().flex_shrink_0().w_full().px_5().pb_5().child(prompt))
            })
            .child(self.queue.clone())
            .child(
                div()
                    .flex_shrink_0()
                    .w_full()
                    .px_5()
                    .pb_5()
                    .child(self.composer.clone()),
            )
    }
}

async fn run_session(
    config: RunConfiguration,
    updates: Sender<AppUpdate>,
    commands: Receiver<HostCommand>,
) -> Result<(), String> {
    send_status(&updates, "Connecting to Codex App Server…").await;
    let codex = Codex::connect_local(LocalSessionConfig::app_server(config.codex_binary.clone()))
        .await
        .map_err(|error| error.to_string())?;
    let mut turn_options = load_model_catalog(&codex, &updates).await?;
    let (started_thread, mut thread_id) =
        start_initial_thread(&codex, &config, &turn_options, &updates).await?;
    let mut thread = Some(started_thread);
    let mut session_observation = codex
        .client()
        .observe()
        .await
        .map_err(|error| error.to_string())?;
    let mut canonical_observation = observe_thread(&codex, &thread_id).await?;
    let mut next_launch = Some(TurnLaunch::Input(config.prompt.clone()));
    let mut next_queue_id = 1_u64;
    let mut shutdown = false;
    while !shutdown {
        let launch = match next_launch.take() {
            Some(launch) => launch,
            None => match next_idle_action(codex.client(), &commands).await? {
                IdleAction::Submit(input) => TurnLaunch::Input(input),
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
                IdleAction::SelectModel(selection) => {
                    apply_model_selection(&mut turn_options, &selection);
                    send_status(&updates, "Model selection updated for the next turn").await;
                    continue;
                }
                IdleAction::Queue(event) => {
                    let current = thread
                        .as_ref()
                        .ok_or_else(|| "selected thread lease is missing".to_owned())?;
                    handle_queue_event(current, event).await?;
                    publish_queue(current, &updates).await?;
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
            &turn_options,
            TurnDriver {
                session_observation: &mut session_observation,
                canonical_observation: &mut canonical_observation,
                commands: &commands,
                updates: &updates,
                next_queue_id: &mut next_queue_id,
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
        if schedule_queued_follow_up(thread.as_ref(), &outcome, &updates).await? {
            next_launch = Some(TurnLaunch::Queued);
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

async fn schedule_queued_follow_up(
    thread: Option<&CodexThread>,
    outcome: &TurnOutcome,
    updates: &Sender<AppUpdate>,
) -> Result<bool, String> {
    let has_queue = if outcome.queue_changed {
        true
    } else if outcome.check_queue_after {
        queue_has_items(thread.ok_or_else(|| "selected thread lease is missing".to_owned())?)
            .await?
    } else {
        false
    };
    if has_queue {
        send_status(updates, "Starting queued follow-up…").await;
    }
    Ok(has_queue)
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
        TaskStatusPresentation::Running,
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
}

enum TurnLaunch {
    Input(String),
    Queued,
}

struct TurnDriver<'a> {
    session_observation: &'a mut SessionObservation,
    canonical_observation: &'a mut CanonicalObservation,
    commands: &'a Receiver<HostCommand>,
    updates: &'a Sender<AppUpdate>,
    next_queue_id: &'a mut u64,
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
                active_behavior,
            }) => match active_behavior {
                ActiveSubmitBehavior::Steer => turn
                    .steer(vec![CodexInput::text(text)])
                    .await
                    .map_err(|error| error.to_string())?,
                ActiveSubmitBehavior::Queue => {
                    let queue_id = *self.next_queue_id;
                    *self.next_queue_id = self
                        .next_queue_id
                        .checked_add(1)
                        .ok_or_else(|| "queue client identity exhausted".to_owned())?;
                    match thread
                        .queue_add(
                            vec![CodexInput::text(text)],
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
                handle_queue_event(thread, event).await?;
                publish_queue(thread, self.updates).await?;
            }
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
    options: &TurnOptions,
    mut driver: TurnDriver<'_>,
) -> Result<TurnOutcome, String> {
    send_status(driver.updates, "Running turn…").await;
    let launched_from_queue = matches!(&launch, TurnLaunch::Queued);
    let turn = match launch {
        TurnLaunch::Input(input) => {
            thread
                .start_turn(vec![CodexInput::text(input)], options.clone())
                .await
        }
        TurnLaunch::Queued => thread.queue_start(None).await,
    }
    .map_err(|error| error.to_string())?;
    driver.updates.send(AppUpdate::TurnActive(true)).await.ok();
    publish_queue(thread, driver.updates).await?;
    let turn_key = TurnKey {
        thread_id: thread_id.clone(),
        turn_id: turn.id().clone(),
    };
    let mut outcome = TurnOutcome {
        shutdown: false,
        pending_selection: None,
        pending_model: None,
        queue_changed: false,
        check_queue_after: launched_from_queue,
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
    let projection = TranscriptProjector::project(&state, thread_id, &StandardItemPolicy);
    updates
        .send(AppUpdate::Transcript(projection))
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
    Submit(String),
    Select(ThreadId),
    SelectModel(ModelSelectionEvent),
    Queue(QueueEvent),
    Shutdown,
}

async fn next_idle_action(
    client: &AppServerClient,
    commands: &Receiver<HostCommand>,
) -> Result<IdleAction, String> {
    loop {
        match commands.recv().await {
            Ok(HostCommand::Submit { text, .. }) => return Ok(IdleAction::Submit(text)),
            Ok(HostCommand::SelectThread(thread_id)) => {
                return Ok(IdleAction::Select(thread_id));
            }
            Ok(HostCommand::SelectModel(selection)) => {
                return Ok(IdleAction::SelectModel(selection));
            }
            Ok(HostCommand::Queue(event)) => return Ok(IdleAction::Queue(event)),
            Ok(HostCommand::Prompt(intent)) => handle_prompt(client, intent).await?,
            Ok(HostCommand::Interrupt) => {}
            Ok(HostCommand::Shutdown) | Err(_) => return Ok(IdleAction::Shutdown),
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

fn current_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use codex_app_server_client::ServerRequestKey;
    use codex_app_server_interaction::{InteractionScope, McpElicitationMode, UserQuestion};
    use codex_app_server_wire::JsonRpcId;

    use super::*;

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
