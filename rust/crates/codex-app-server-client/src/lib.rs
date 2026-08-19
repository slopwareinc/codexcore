//! Ordered App Server session runtime.
//!
//! One actor owns physical ingress, request correlation, handshake buffering,
//! server-request identity, and revision publication. Callers never reduce raw
//! frames concurrently with this owner.

use std::collections::{BTreeMap, HashMap, VecDeque};

use codex_app_server_state::StateRevision;
use codex_app_server_transport::{StdioConfig, StdioConnection, TransportError, TransportLimits};
use codex_app_server_wire::{
    Envelope, JsonRpcErrorObject, JsonRpcId, NotificationEnvelope, ResponseOutcome,
    ServerRequestEnvelope, WireCursor, decode_frame, encode_error, encode_notification,
    encode_request, encode_result,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::sync::{mpsc, oneshot, watch};

/// Bounded actor and handshake configuration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionLimits {
    /// Commands waiting for the single session actor.
    pub maximum_buffered_commands: usize,
    /// Non-initialize frames retained until the handshake completes.
    pub maximum_buffered_handshake_frames: usize,
}

impl Default for SessionLimits {
    fn default() -> Self {
        Self {
            maximum_buffered_commands: 1_024,
            maximum_buffered_handshake_frames: 4_096,
        }
    }
}

impl SessionLimits {
    fn validate(self) -> Result<Self, SessionError> {
        if self.maximum_buffered_commands == 0 {
            return Err(SessionError::InvalidLimit("maximum_buffered_commands"));
        }
        if self.maximum_buffered_handshake_frames == 0 {
            return Err(SessionError::InvalidLimit(
                "maximum_buffered_handshake_frames",
            ));
        }
        Ok(self)
    }
}

/// Metadata sent during `initialize`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClientInfo {
    /// Stable compliance/logging identifier.
    pub name: String,
    /// Human-readable product title.
    pub title: String,
    /// Client package version.
    pub version: String,
}

/// Local session launch configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalSessionConfig {
    /// Physical subprocess configuration.
    pub stdio: StdioConfig,
    /// Transport resource bounds.
    pub transport_limits: TransportLimits,
    /// Session actor resource bounds.
    pub session_limits: SessionLimits,
    /// Initialize metadata.
    pub client_info: ClientInfo,
    /// Enables methods and fields marked experimental by App Server.
    pub experimental_api: bool,
    /// Enables upstream attestation server requests.
    pub request_attestation: bool,
}

impl LocalSessionConfig {
    /// Standard local configuration for an exact Codex executable.
    #[must_use]
    pub fn app_server(executable: impl Into<std::path::PathBuf>) -> Self {
        Self {
            stdio: StdioConfig::app_server(executable),
            transport_limits: TransportLimits::default(),
            session_limits: SessionLimits::default(),
            client_info: ClientInfo {
                name: "codexcore_rust".to_owned(),
                title: "CodexCore Rust".to_owned(),
                version: env!("CARGO_PKG_VERSION").to_owned(),
            },
            experimental_api: true,
            request_attestation: false,
        }
    }
}

/// Validated initialize response projected into stable SDK-owned metadata.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectedServer {
    /// Server user agent.
    pub user_agent: String,
    /// Exact server-side Codex home.
    pub codex_home: String,
    /// Broad platform family such as `unix`.
    pub platform_family: String,
    /// Operating system such as `linux` or `macos`.
    pub platform_os: String,
}

/// Physical connection/session lifecycle.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ConnectionPhase {
    /// Initialize and initialized completed.
    Connected,
    /// Connection ended unexpectedly.
    Disconnected,
    /// Host explicitly closed the session.
    Closed,
}

/// Exact identity for one pending server-initiated request.
#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct ServerRequestKey {
    /// Physical connection generation.
    pub connection_epoch: u64,
    /// Server-provided JSON-RPC identity.
    pub request_id: JsonRpcId,
}

/// Lossless pending interaction retained by the ordered actor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingServerRequest {
    /// Exact epoch-qualified identity.
    pub key: ServerRequestKey,
    /// App Server method.
    pub method: String,
    /// Raw object parameters retained for typed or fallback host policy.
    pub params: BTreeMap<String, Value>,
}

/// Immutable current session facts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSnapshot {
    /// Latest canonical local revision.
    pub revision: StateRevision,
    /// Current physical connection generation.
    pub connection_epoch: u64,
    /// Highest observed wire coordinate.
    pub last_wire_cursor: Option<WireCursor>,
    /// Current connection lifecycle.
    pub phase: ConnectionPhase,
    /// Validated server metadata.
    pub server: ConnectedServer,
    /// Count of committed notifications, useful until typed reduction lands.
    pub committed_notification_count: u64,
    /// Pending server requests in stable identity order.
    pub pending_server_requests: Vec<PendingServerRequest>,
}

/// Successful raw request result after the actor committed its response frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestResult {
    /// JSON result payload.
    pub value: Value,
    /// Session revision already published before this value reached the caller.
    pub committed_revision: StateRevision,
}

/// Host decision for one pending server request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerRequestResolution {
    /// Successful result payload.
    Result(Value),
    /// Structured JSON-RPC failure.
    Error(JsonRpcErrorObject),
}

/// Session lifecycle, protocol, or correlation failure.
#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum SessionError {
    /// Configured bound is zero.
    #[error("session limit {0} must be positive")]
    InvalidLimit(&'static str),
    /// Physical transport failure.
    #[error("transport failure: {0}")]
    Transport(String),
    /// Inbound frame failed envelope validation.
    #[error("protocol failure: {0}")]
    Protocol(String),
    /// App Server returned a structured error.
    #[error(transparent)]
    Rpc(JsonRpcErrorObject),
    /// Initialize response was missing or invalid.
    #[error("initialize failed: {0}")]
    Initialize(String),
    /// Handshake buffer reached its explicit bound.
    #[error("initialize handshake frame buffer overflowed")]
    HandshakeBufferOverflow,
    /// Actor command channel ended or session was explicitly closed.
    #[error("App Server session is closed")]
    Closed,
    /// Request may have reached App Server and is never safe to replay blindly.
    #[error("request {method} ({id:?}) has indeterminate outcome after write attempt")]
    IndeterminateRequest {
        /// Method whose write began.
        method: String,
        /// Exact request identity.
        id: JsonRpcId,
    },
    /// Host attempted to resolve an absent or old-epoch server request.
    #[error("pending server request was not found")]
    PendingServerRequestNotFound,
    /// Same epoch/ID arrived with conflicting method or parameters.
    #[error("conflicting duplicate server request identity")]
    ConflictingServerRequest,
    /// Local canonical revision exhausted rather than wrapping.
    #[error("session revision exhausted")]
    RevisionExhausted,
}

impl From<TransportError> for SessionError {
    fn from(error: TransportError) -> Self {
        Self::Transport(error.to_string())
    }
}

/// Atomic seed plus newest-one invalidation stream.
pub struct SessionObservation {
    seed: SessionSnapshot,
    revisions: watch::Receiver<StateRevision>,
}

impl SessionObservation {
    /// Initial snapshot captured atomically with observation registration.
    #[must_use]
    pub fn seed(&self) -> &SessionSnapshot {
        &self.seed
    }

    /// Wait until a newer revision is available and return it.
    ///
    /// Signals mean “reread current state”; intermediate revisions may
    /// intentionally coalesce.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Closed`] after the actor seals publication.
    pub async fn changed(&mut self) -> Result<StateRevision, SessionError> {
        self.revisions
            .changed()
            .await
            .map_err(|_| SessionError::Closed)?;
        Ok(*self.revisions.borrow_and_update())
    }
}

/// Cloneable public capability for one ordered session actor.
#[derive(Clone)]
pub struct AppServerClient {
    commands: mpsc::Sender<Command>,
    revisions: watch::Receiver<StateRevision>,
}

impl AppServerClient {
    /// Launch, initialize, and start an ordered local App Server session.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] when process launch, handshake, typed initialize
    /// validation, or bounded handshake buffering fails.
    pub async fn connect_local(config: LocalSessionConfig) -> Result<Self, SessionError> {
        let session_limits = config.session_limits.validate()?;
        let mut connection = StdioConnection::spawn(&config.stdio, config.transport_limits)?;
        let bootstrap = bootstrap(&mut connection, &config, session_limits).await;
        let (snapshot, buffered) = match bootstrap {
            Ok(value) => value,
            Err(error) => {
                let _ = connection.close().await;
                return Err(error);
            }
        };

        let (commands, receiver) = mpsc::channel(session_limits.maximum_buffered_commands);
        let (revision_sender, revisions) = watch::channel(snapshot.revision);
        tokio::spawn(run_actor(
            connection,
            receiver,
            revision_sender,
            snapshot,
            buffered,
        ));
        Ok(Self {
            commands,
            revisions,
        })
    }

    /// Send a raw typed-method request and await its committed response.
    ///
    /// # Errors
    ///
    /// Returns protocol/RPC/session errors, including an indeterminate outcome
    /// when the physical write began before connection loss.
    pub async fn request(
        &self,
        method: impl Into<String>,
        params: Value,
    ) -> Result<RequestResult, SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::Request {
            method: method.into(),
            params,
            reply,
        })
        .await?;
        response.await.map_err(|_| SessionError::Closed)?
    }

    /// Send a client notification.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] when encoding, queueing, or writing fails.
    pub async fn notify(
        &self,
        method: impl Into<String>,
        params: Value,
    ) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::Notify {
            method: method.into(),
            params,
            reply,
        })
        .await?;
        response.await.map_err(|_| SessionError::Closed)?
    }

    /// Read one immutable current snapshot through the ordered owner.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Closed`] when the actor is gone.
    pub async fn snapshot(&self) -> Result<SessionSnapshot, SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::Snapshot { reply }).await?;
        response.await.map_err(|_| SessionError::Closed)
    }

    /// Register an atomic snapshot seed plus coalesced revision invalidations.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Closed`] when the actor is gone.
    pub async fn observe(&self) -> Result<SessionObservation, SessionError> {
        Ok(SessionObservation {
            seed: self.snapshot().await?,
            revisions: self.revisions.clone(),
        })
    }

    /// Resolve one exact pending server request once.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] for missing/old identity, encoding, or physical
    /// write failure.
    pub async fn resolve_server_request(
        &self,
        key: ServerRequestKey,
        resolution: ServerRequestResolution,
    ) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::ResolveServerRequest {
            key,
            resolution,
            reply,
        })
        .await?;
        response.await.map_err(|_| SessionError::Closed)?
    }

    /// Close and reap the physical session.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] when deterministic transport shutdown fails.
    pub async fn close(&self) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::Close { reply }).await?;
        response.await.map_err(|_| SessionError::Closed)?
    }

    async fn send_command(&self, command: Command) -> Result<(), SessionError> {
        self.commands
            .send(command)
            .await
            .map_err(|_| SessionError::Closed)
    }
}

enum Command {
    Request {
        method: String,
        params: Value,
        reply: oneshot::Sender<Result<RequestResult, SessionError>>,
    },
    Notify {
        method: String,
        params: Value,
        reply: oneshot::Sender<Result<(), SessionError>>,
    },
    Snapshot {
        reply: oneshot::Sender<SessionSnapshot>,
    },
    ResolveServerRequest {
        key: ServerRequestKey,
        resolution: ServerRequestResolution,
        reply: oneshot::Sender<Result<(), SessionError>>,
    },
    Close {
        reply: oneshot::Sender<Result<(), SessionError>>,
    },
}

struct PendingClientRequest {
    method: String,
    id: JsonRpcId,
    write_attempted: bool,
    reply: oneshot::Sender<Result<RequestResult, SessionError>>,
}

struct BufferedEnvelope {
    cursor: WireCursor,
    envelope: Envelope,
}

struct ActorState {
    snapshot: SessionSnapshot,
    pending_client_requests: HashMap<JsonRpcId, PendingClientRequest>,
    pending_server_requests: BTreeMap<ServerRequestKey, PendingServerRequest>,
    next_request_id: i64,
}

impl ActorState {
    fn commit(&mut self, cursor: Option<WireCursor>) -> Result<StateRevision, SessionError> {
        self.snapshot.revision = self
            .snapshot
            .revision
            .successor()
            .ok_or(SessionError::RevisionExhausted)?;
        if let Some(cursor) = cursor
            && self
                .snapshot
                .last_wire_cursor
                .is_none_or(|current| cursor > current)
        {
            self.snapshot.last_wire_cursor = Some(cursor);
        }
        Ok(self.snapshot.revision)
    }

    fn rebuild_pending_projection(&mut self) {
        self.snapshot.pending_server_requests =
            self.pending_server_requests.values().cloned().collect();
    }
}

async fn bootstrap(
    connection: &mut StdioConnection,
    config: &LocalSessionConfig,
    limits: SessionLimits,
) -> Result<(SessionSnapshot, VecDeque<BufferedEnvelope>), SessionError> {
    let initialize_id = JsonRpcId::Integer(0);
    let initialize = encode_request(
        initialize_id.clone(),
        "initialize",
        Some(json!({
            "clientInfo": {
                "name": config.client_info.name,
                "title": config.client_info.title,
                "version": config.client_info.version,
            },
            "capabilities": {
                "experimentalApi": config.experimental_api,
                "requestAttestation": config.request_attestation,
            }
        })),
    )
    .map_err(|error| SessionError::Protocol(error.to_string()))?;
    connection.write(&initialize).await?;

    let mut buffered = VecDeque::new();
    let mut ordinal = 0_u64;
    let server = loop {
        let frame = connection
            .next_frame()
            .await
            .ok_or_else(|| SessionError::Initialize("connection ended".to_owned()))??;
        ordinal = ordinal
            .checked_add(1)
            .ok_or(SessionError::RevisionExhausted)?;
        let cursor = WireCursor {
            connection_epoch: 1,
            ordinal,
        };
        let envelope =
            decode_frame(&frame).map_err(|error| SessionError::Protocol(error.to_string()))?;
        if let Envelope::Response(response) = &envelope
            && response.id == initialize_id
        {
            match &response.outcome {
                ResponseOutcome::Result(value) => {
                    let typed: ConnectedServer = serde_json::from_value(value.clone())
                        .map_err(|error| SessionError::Initialize(error.to_string()))?;
                    break typed;
                }
                ResponseOutcome::Error(error) => return Err(SessionError::Rpc(error.clone())),
            }
        }
        if buffered.len() == limits.maximum_buffered_handshake_frames {
            return Err(SessionError::HandshakeBufferOverflow);
        }
        buffered.push_back(BufferedEnvelope { cursor, envelope });
    };

    let initialized = encode_notification("initialized", Some(json!({})))
        .map_err(|error| SessionError::Protocol(error.to_string()))?;
    connection.write(&initialized).await?;

    Ok((
        SessionSnapshot {
            revision: StateRevision::new(1),
            connection_epoch: 1,
            last_wire_cursor: Some(WireCursor {
                connection_epoch: 1,
                ordinal,
            }),
            phase: ConnectionPhase::Connected,
            server,
            committed_notification_count: 0,
            pending_server_requests: Vec::new(),
        },
        buffered,
    ))
}

async fn run_actor(
    mut connection: StdioConnection,
    mut commands: mpsc::Receiver<Command>,
    revisions: watch::Sender<StateRevision>,
    snapshot: SessionSnapshot,
    mut buffered: VecDeque<BufferedEnvelope>,
) {
    let mut state = ActorState {
        snapshot,
        pending_client_requests: HashMap::new(),
        pending_server_requests: BTreeMap::new(),
        next_request_id: 1,
    };

    while let Some(buffered) = buffered.pop_front() {
        if apply_envelope(&mut state, buffered.cursor, buffered.envelope).is_err() {
            seal_pending(
                &mut state,
                &SessionError::Protocol("buffered handshake frame failed".into()),
            );
            let _ = connection.close().await;
            return;
        }
    }
    if *revisions.borrow() != state.snapshot.revision {
        let _ = revisions.send(state.snapshot.revision);
    }

    let mut ordinal = state
        .snapshot
        .last_wire_cursor
        .map_or(0, |cursor| cursor.ordinal);
    let mut close_reply = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { break };
                match handle_command(&mut state, &mut connection, command).await {
                    CommandOutcome::Continue => {}
                    CommandOutcome::Committed => {
                        let _ = revisions.send(state.snapshot.revision);
                    }
                    CommandOutcome::Close(reply) => {
                        close_reply = Some(reply);
                        state.snapshot.phase = ConnectionPhase::Closed;
                        if state.commit(None).is_ok() {
                            let _ = revisions.send(state.snapshot.revision);
                        }
                        break;
                    }
                    CommandOutcome::Fatal(error) => {
                        seal_pending(&mut state, &error);
                        state.snapshot.phase = ConnectionPhase::Disconnected;
                        if state.commit(None).is_ok() {
                            let _ = revisions.send(state.snapshot.revision);
                        }
                        break;
                    }
                }
            }
            frame = connection.next_frame() => {
                let result = match frame {
                    Some(Ok(frame)) => {
                        ordinal = match ordinal.checked_add(1) {
                            Some(value) => value,
                            None => break,
                        };
                        let cursor = WireCursor { connection_epoch: state.snapshot.connection_epoch, ordinal };
                        decode_frame(&frame)
                            .map_err(|error| SessionError::Protocol(error.to_string()))
                            .and_then(|envelope| apply_envelope(&mut state, cursor, envelope))
                    }
                    Some(Err(error)) => Err(SessionError::Transport(error.to_string())),
                    None => Err(SessionError::Transport("transport ingress ended".to_owned())),
                };
                match result {
                    Ok(()) => { let _ = revisions.send(state.snapshot.revision); }
                    Err(error) => {
                        seal_pending(&mut state, &error);
                        state.snapshot.phase = ConnectionPhase::Disconnected;
                        if state.commit(None).is_ok() { let _ = revisions.send(state.snapshot.revision); }
                        break;
                    }
                }
            }
        }
    }

    let close_result = connection.close().await.map_err(SessionError::from);
    if let Some(reply) = close_reply {
        let _ = reply.send(close_result);
    }
}

enum CommandOutcome {
    Continue,
    Committed,
    Close(oneshot::Sender<Result<(), SessionError>>),
    Fatal(SessionError),
}

async fn handle_command(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    command: Command,
) -> CommandOutcome {
    match command {
        Command::Request {
            method,
            params,
            reply,
        } => {
            let id = JsonRpcId::Integer(state.next_request_id);
            state.next_request_id = if let Some(value) = state.next_request_id.checked_add(1) {
                value
            } else {
                let _ = reply.send(Err(SessionError::RevisionExhausted));
                return CommandOutcome::Continue;
            };
            let frame = match encode_request(id.clone(), &method, Some(params)) {
                Ok(frame) => frame,
                Err(error) => {
                    let _ = reply.send(Err(SessionError::Protocol(error.to_string())));
                    return CommandOutcome::Continue;
                }
            };
            state.pending_client_requests.insert(
                id.clone(),
                PendingClientRequest {
                    method: method.clone(),
                    id: id.clone(),
                    write_attempted: true,
                    reply,
                },
            );
            if connection.write(&frame).await.is_err() {
                let error = SessionError::IndeterminateRequest { method, id };
                seal_pending(state, &error);
                return CommandOutcome::Fatal(error);
            }
            CommandOutcome::Continue
        }
        Command::Notify {
            method,
            params,
            reply,
        } => {
            let result = encode_notification(&method, Some(params))
                .map_err(|error| SessionError::Protocol(error.to_string()));
            let result = match result {
                Ok(frame) => connection.write(&frame).await.map_err(SessionError::from),
                Err(error) => Err(error),
            };
            let fatal = result.as_ref().err().cloned();
            let _ = reply.send(result);
            fatal.map_or(CommandOutcome::Continue, CommandOutcome::Fatal)
        }
        Command::Snapshot { reply } => {
            let _ = reply.send(state.snapshot.clone());
            CommandOutcome::Continue
        }
        Command::ResolveServerRequest {
            key,
            resolution,
            reply,
        } => {
            if !state.pending_server_requests.contains_key(&key) {
                let _ = reply.send(Err(SessionError::PendingServerRequestNotFound));
                return CommandOutcome::Continue;
            }
            let frame = match resolution {
                ServerRequestResolution::Result(result) => {
                    encode_result(key.request_id.clone(), result)
                }
                ServerRequestResolution::Error(error) => {
                    encode_error(key.request_id.clone(), error)
                }
            };
            let frame = match frame {
                Ok(frame) => frame,
                Err(error) => {
                    let _ = reply.send(Err(SessionError::Protocol(error.to_string())));
                    return CommandOutcome::Continue;
                }
            };
            if let Err(error) = connection.write(&frame).await {
                let error = SessionError::Transport(error.to_string());
                let _ = reply.send(Err(error.clone()));
                return CommandOutcome::Fatal(error);
            }
            state.pending_server_requests.remove(&key);
            state.rebuild_pending_projection();
            if let Err(error) = state.commit(None) {
                let _ = reply.send(Err(error.clone()));
                return CommandOutcome::Fatal(error);
            }
            let _ = reply.send(Ok(()));
            CommandOutcome::Committed
        }
        Command::Close { reply } => CommandOutcome::Close(reply),
    }
}

fn apply_envelope(
    state: &mut ActorState,
    cursor: WireCursor,
    envelope: Envelope,
) -> Result<(), SessionError> {
    match envelope {
        Envelope::Response(response) => {
            let pending = state.pending_client_requests.remove(&response.id);
            let revision = state.commit(Some(cursor))?;
            if let Some(pending) = pending {
                let result = match response.outcome {
                    ResponseOutcome::Result(value) => Ok(RequestResult {
                        value,
                        committed_revision: revision,
                    }),
                    ResponseOutcome::Error(error) => Err(SessionError::Rpc(error)),
                };
                let _ = pending.reply.send(result);
            }
        }
        Envelope::Notification(NotificationEnvelope { .. }) => {
            state.snapshot.committed_notification_count = state
                .snapshot
                .committed_notification_count
                .checked_add(1)
                .ok_or(SessionError::RevisionExhausted)?;
            state.commit(Some(cursor))?;
        }
        Envelope::ServerRequest(ServerRequestEnvelope { id, method, params }) => {
            let key = ServerRequestKey {
                connection_epoch: state.snapshot.connection_epoch,
                request_id: id,
            };
            let request = PendingServerRequest {
                key: key.clone(),
                method,
                params,
            };
            if let Some(existing) = state.pending_server_requests.get(&key) {
                if existing != &request {
                    return Err(SessionError::ConflictingServerRequest);
                }
                return Ok(());
            }
            state.pending_server_requests.insert(key, request);
            state.rebuild_pending_projection();
            state.commit(Some(cursor))?;
        }
    }
    Ok(())
}

fn seal_pending(state: &mut ActorState, cause: &SessionError) {
    for (_, pending) in state.pending_client_requests.drain() {
        let error = if pending.write_attempted {
            SessionError::IndeterminateRequest {
                method: pending.method,
                id: pending.id,
            }
        } else {
            cause.clone()
        };
        let _ = pending.reply.send(Err(error));
    }
    state.pending_server_requests.clear();
    state.rebuild_pending_projection();
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn shell_config(script: &str) -> LocalSessionConfig {
        let mut config = LocalSessionConfig::app_server("/bin/sh");
        config.stdio = StdioConfig {
            executable: PathBuf::from("/bin/sh"),
            arguments: vec!["-c".to_owned(), script.to_owned()],
            environment: BTreeMap::new(),
            current_directory: None,
        };
        config
    }

    const INITIALIZE_RESPONSE: &str = r#"{"id":0,"result":{"userAgent":"test-server","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"test"}}"#;

    #[cfg(unix)]
    #[tokio::test]
    async fn response_is_committed_before_request_resumes() {
        let script = format!(
            "read init; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; read request; printf '%s\\n' '{{\"id\":1,\"result\":{{\"ok\":true}}}}'; sleep 1"
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let result = client
            .request("model/list", json!({}))
            .await
            .expect("request succeeds");
        let snapshot = client.snapshot().await.expect("read snapshot");
        assert_eq!(snapshot.revision, result.committed_revision);
        assert_eq!(result.value, json!({"ok": true}));
        client.close().await.expect("close session");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn handshake_buffers_and_drains_prior_notification() {
        let script = format!(
            "read init; printf '%s\\n' '{{\"method\":\"thread/started\",\"params\":{{}}}}'; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; sleep 1"
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let snapshot = client.snapshot().await.expect("read snapshot");
        assert_eq!(snapshot.committed_notification_count, 1);
        assert_eq!(snapshot.revision, StateRevision::new(2));
        assert_eq!(
            snapshot.last_wire_cursor.map(|cursor| cursor.ordinal),
            Some(2)
        );
        client.close().await.expect("close session");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn server_request_enters_exact_epoch_inbox_and_resolves_once() {
        let script = format!(
            "read init; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; printf '%s\\n' '{{\"id\":\"approval-1\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{{\"reason\":\"test\"}}}}'; read resolution; sleep 1"
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let mut observation = client.observe().await.expect("observe session");
        if observation.seed().pending_server_requests.is_empty() {
            observation.changed().await.expect("request arrives");
        }
        let snapshot = client.snapshot().await.expect("read inbox");
        let request = snapshot
            .pending_server_requests
            .first()
            .expect("pending request")
            .clone();
        assert_eq!(request.key.connection_epoch, 1);
        client
            .resolve_server_request(
                request.key.clone(),
                ServerRequestResolution::Result(json!({})),
            )
            .await
            .expect("resolve once");
        assert_eq!(
            client
                .resolve_server_request(request.key, ServerRequestResolution::Result(json!({})))
                .await,
            Err(SessionError::PendingServerRequestNotFound)
        );
        client.close().await.expect("close session");
    }
}
