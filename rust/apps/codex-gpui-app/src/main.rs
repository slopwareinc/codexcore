use std::{
    env,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use async_channel::{Receiver, Sender};
use codex_app_server_client::{AppServerClient, LocalSessionConfig};
use codex_app_server_interaction::{
    ServerRequestBody, ServerRequestReply, TypedServerRequest, default_resolution, parse_pending,
};
use codex_app_server_sdk::{Codex, CodexInput, StartThreadOptions, TurnOptions};
use codex_app_server_state::{ThreadId, TurnKey};
use codex_app_server_wire::JsonRpcErrorObject;
use codex_gpui::{CodexPrompt, CodexTranscript, PromptIntent};
use codex_presentation::{
    PromptActionKind, PromptPresentation, StandardItemPolicy, TranscriptPresentation,
    TranscriptProjector, project_prompt,
};
use gpui::{
    App, AppContext, Bounds, Context, Entity, Render, Subscription, Task, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, rgb, size,
};
use gpui_platform::application;
use gpui_tokio::Tokio;
use serde_json::json;

const UPDATE_CAPACITY: usize = 32;
const COMMAND_CAPACITY: usize = 16;

fn main() {
    let config = match RunConfiguration::parse(env::args().skip(1)) {
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct RunConfiguration {
    codex_binary: PathBuf,
    cwd: PathBuf,
    prompt: String,
    ephemeral: bool,
    headless: bool,
}

impl RunConfiguration {
    fn parse(arguments: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut codex_binary =
            env::var_os("CODEX_BINARY").map_or_else(|| PathBuf::from("codex"), PathBuf::from);
        let mut cwd = env::current_dir().map_err(|error| error.to_string())?;
        let mut prompt = "Introduce yourself in one short sentence. Do not use tools.".to_owned();
        let mut ephemeral = true;
        let mut headless = false;
        let mut arguments = arguments.into_iter();
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--codex-binary" => {
                    codex_binary = PathBuf::from(next_value(&mut arguments, &argument)?);
                }
                "--cwd" => cwd = PathBuf::from(next_value(&mut arguments, &argument)?),
                "--prompt" => prompt = next_value(&mut arguments, &argument)?,
                "--persist" => ephemeral = false,
                "--headless" => headless = true,
                "--help" | "-h" => return Err(usage().to_owned()),
                value => return Err(format!("unknown argument {value:?}\n{}", usage())),
            }
        }
        if prompt.trim().is_empty() {
            return Err("--prompt must not be empty".to_owned());
        }
        Ok(Self {
            codex_binary,
            cwd,
            prompt,
            ephemeral,
            headless,
        })
    }
}

fn next_value(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, String> {
    arguments
        .next()
        .ok_or_else(|| format!("{option} requires a value"))
}

const fn usage() -> &'static str {
    "usage: codex-gpui-app [--codex-binary PATH] [--cwd PATH] [--prompt TEXT] [--persist] [--headless]"
}

fn run_headless(config: RunConfiguration) -> Result<(), String> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?
        .block_on(async move {
            let (updates, receiver) = async_channel::bounded(UPDATE_CAPACITY);
            let (_commands, command_receiver) = async_channel::bounded(COMMAND_CAPACITY);
            let printer = tokio::spawn(print_updates(receiver));
            let result = run_session(config, updates, command_receiver).await;
            printer.await.map_err(|error| error.to_string())?;
            result
        })
}

async fn print_updates(receiver: Receiver<AppUpdate>) {
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
            AppUpdate::Failed(error) => eprintln!("session failed: {error}"),
        }
    }
}

enum AppUpdate {
    Status(String),
    Transcript(TranscriptPresentation),
    Prompt(Option<PromptPresentation>),
    Failed(String),
}

#[derive(Clone, Debug)]
enum HostCommand {
    Prompt(PromptIntent),
}

struct CodexApp {
    transcript: Entity<CodexTranscript>,
    prompt: Option<Entity<CodexPrompt>>,
    prompt_subscription: Option<Subscription>,
    status: String,
    command_sender: Sender<HostCommand>,
    _session_task: Task<Result<(), gpui_tokio::JoinError>>,
    _update_task: Task<()>,
}

impl CodexApp {
    fn new(config: RunConfiguration, cx: &mut Context<Self>) -> Self {
        let pending = TranscriptPresentation {
            revision: codex_app_server_state::StateRevision::ZERO,
            thread_id: ThreadId::from("pending"),
            turns: Vec::new(),
        };
        let transcript = cx.new(|_| CodexTranscript::new(&pending));
        let (update_sender, update_receiver) = async_channel::bounded(UPDATE_CAPACITY);
        let (command_sender, command_receiver) = async_channel::bounded(COMMAND_CAPACITY);
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
            prompt: None,
            prompt_subscription: None,
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
            let prompt = cx.new(|_| CodexPrompt::new(presentation));
            let sender = self.command_sender.clone();
            self.prompt_subscription = Some(cx.subscribe(
                &prompt,
                move |_this, _prompt, intent: &PromptIntent, _cx| {
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
                    .overflow_hidden()
                    .child(self.transcript.clone()),
            )
            .when_some(self.prompt.clone(), |view, prompt| {
                view.child(div().flex_shrink_0().w_full().px_5().pb_5().child(prompt))
            })
    }
}

async fn run_session(
    config: RunConfiguration,
    updates: Sender<AppUpdate>,
    commands: Receiver<HostCommand>,
) -> Result<(), String> {
    send_status(&updates, "Connecting to Codex App Server…").await;
    let codex = Codex::connect_local(LocalSessionConfig::app_server(config.codex_binary))
        .await
        .map_err(|error| error.to_string())?;
    send_status(&updates, "Starting thread…").await;
    let thread = codex
        .start_thread(StartThreadOptions {
            cwd: Some(config.cwd),
            ephemeral: Some(config.ephemeral),
            ..StartThreadOptions::default()
        })
        .await
        .map_err(|error| error.to_string())?;
    let thread_id = thread.id().clone();
    let mut observation = codex
        .client()
        .observe()
        .await
        .map_err(|error| error.to_string())?;
    send_status(&updates, "Running turn…").await;
    let turn = thread
        .start_turn(
            vec![CodexInput::text(config.prompt)],
            TurnOptions::default(),
        )
        .await
        .map_err(|error| error.to_string())?;
    let turn_key = TurnKey {
        thread_id: thread_id.clone(),
        turn_id: turn.id().clone(),
    };

    loop {
        let terminal = publish_current(codex.client(), &thread_id, &turn_key, &updates).await?;
        if terminal {
            break;
        }
        tokio::select! {
            changed = observation.changed() => {
                changed.map_err(|error| error.to_string())?;
            }
            command = commands.recv() => {
                if let Ok(command) = command {
                    handle_command(codex.client(), command).await?;
                }
            }
        }
    }

    send_status(&updates, "Turn complete").await;
    updates.send(AppUpdate::Prompt(None)).await.ok();
    turn.close().await.map_err(|error| error.to_string())?;
    thread.close().await.map_err(|error| error.to_string())?;
    codex.close().await.map_err(|error| error.to_string())?;
    Ok(())
}

async fn publish_current(
    client: &AppServerClient,
    thread_id: &ThreadId,
    turn_key: &TurnKey,
    updates: &Sender<AppUpdate>,
) -> Result<bool, String> {
    resolve_defaults(client).await?;
    let session = client.snapshot().await.map_err(|error| error.to_string())?;
    let pending = parse_pending(&session).map_err(|error| error.to_string())?;
    updates
        .send(AppUpdate::Prompt(pending.first().map(project_prompt)))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    let state = client
        .canonical_snapshot()
        .await
        .map_err(|error| error.to_string())?;
    let terminal = state
        .turns
        .get(turn_key)
        .is_some_and(|turn| turn.status.is_terminal());
    let projection = TranscriptProjector::project(&state, thread_id, &StandardItemPolicy);
    updates
        .send(AppUpdate::Transcript(projection))
        .await
        .map_err(|_| "GPUI update receiver closed".to_owned())?;
    Ok(terminal)
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

async fn handle_command(client: &AppServerClient, command: HostCommand) -> Result<(), String> {
    let HostCommand::Prompt(intent) = command;
    let snapshot = client.snapshot().await.map_err(|error| error.to_string())?;
    let request = parse_pending(&snapshot)
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|request| request.key == intent.key)
        .ok_or_else(|| "prompt was already resolved".to_owned())?;
    let Some(reply) = reply_for_intent(&request, intent.action) else {
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
    use codex_app_server_interaction::InteractionScope;
    use codex_app_server_wire::JsonRpcId;

    use super::*;

    #[test]
    fn parses_safe_ephemeral_defaults_and_explicit_overrides() {
        let config = RunConfiguration::parse([
            "--codex-binary".to_owned(),
            "/bin/codex".to_owned(),
            "--cwd".to_owned(),
            "/workspace".to_owned(),
            "--prompt".to_owned(),
            "hello".to_owned(),
            "--persist".to_owned(),
            "--headless".to_owned(),
        ])
        .expect("configuration");
        assert_eq!(config.codex_binary, PathBuf::from("/bin/codex"));
        assert_eq!(config.cwd, PathBuf::from("/workspace"));
        assert_eq!(config.prompt, "hello");
        assert!(!config.ephemeral);
        assert!(config.headless);
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
            reply_for_intent(&request, PromptActionKind::Approve),
            Some(ServerRequestReply::CommandDecision(json!("accept")))
        );
        assert_eq!(reply_for_intent(&request, PromptActionKind::Respond), None);
    }
}
