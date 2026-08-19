//! Ordered App Server session runtime.
//!
//! One actor owns physical ingress, request correlation, handshake buffering,
//! server-request identity, and revision publication. Callers never reduce raw
//! frames concurrently with this owner.

use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    time::Duration,
};

use codex_app_server_adapter::{NotificationDisposition, adapt_notification};
use codex_app_server_lease::{
    LeaseAction, LeaseId, LeaseOperationId, LeaseReason, ThreadLeaseRegistry,
};
use codex_app_server_state::ThreadId;
use codex_app_server_state::{CanonicalState, CanonicalStateReducer, StateRevision};
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

/// Bounded physical reconnection policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReconnectPolicy {
    /// Maximum new physical connections after one connection is lost.
    pub maximum_attempts: u32,
    /// Delay before the first reconnect attempt.
    pub initial_delay: Duration,
    /// Upper bound for exponential delay.
    pub maximum_delay: Duration,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            maximum_attempts: 3,
            initial_delay: Duration::from_millis(100),
            maximum_delay: Duration::from_secs(2),
        }
    }
}

impl ReconnectPolicy {
    fn validate(self) -> Result<Self, SessionError> {
        if self.maximum_attempts > 0 && self.initial_delay > self.maximum_delay {
            return Err(SessionError::InvalidReconnectPolicy);
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
    /// Bounded reconnect behavior after transport loss.
    pub reconnect_policy: ReconnectPolicy,
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
            reconnect_policy: ReconnectPolicy::default(),
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
    /// Notifications preserved but not yet projected canonically.
    pub unhandled_notification_count: u64,
    /// Current canonical replica revision.
    pub canonical_revision: StateRevision,
    /// Pending server requests in stable identity order.
    pub pending_server_requests: Vec<PendingServerRequest>,
    /// Threads retained by at least one semantic lease reason.
    pub retained_thread_count: usize,
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
    /// Reconnect delay bounds are inconsistent.
    #[error("initial reconnect delay exceeds maximum delay")]
    InvalidReconnectPolicy,
    /// Physical transport failure.
    #[error("transport failure: {0}")]
    Transport(String),
    /// Inbound frame failed envelope validation.
    #[error("protocol failure: {0}")]
    Protocol(String),
    /// Known protocol notification failed typed canonical adaptation.
    #[error("canonical protocol adaptation failed: {0}")]
    Adapter(String),
    /// Canonical reducer rejected an otherwise typed transaction.
    #[error("canonical reduction failed: {0}")]
    Canonical(String),
    /// Lease registry or reconciliation failure.
    #[error("thread lease reconciliation failed: {0}")]
    Lease(String),
    /// App Server returned a structured error.
    #[error(transparent)]
    Rpc(JsonRpcErrorObject),
    /// Initialize response was missing or invalid.
    #[error("initialize failed: {0}")]
    Initialize(String),
    /// Handshake buffer reached its explicit bound.
    #[error("initialize handshake frame buffer overflowed")]
    HandshakeBufferOverflow,
    /// Every bounded reconnect attempt failed.
    #[error("reconnect attempts exhausted: {0}")]
    ReconnectExhausted(String),
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

impl SessionError {
    fn permits_reconnect(&self) -> bool {
        matches!(self, Self::Transport(_) | Self::IndeterminateRequest { .. })
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
        config.reconnect_policy.validate()?;
        let mut connection = StdioConnection::spawn(&config.stdio, config.transport_limits)?;
        let bootstrap = bootstrap(&mut connection, &config, session_limits, 1).await;
        let bootstrap = match bootstrap {
            Ok(value) => value,
            Err(error) => {
                let _ = connection.close().await;
                return Err(error);
            }
        };
        let snapshot = SessionSnapshot {
            revision: StateRevision::new(1),
            connection_epoch: 1,
            last_wire_cursor: Some(bootstrap.initialize_cursor),
            phase: ConnectionPhase::Connected,
            server: bootstrap.server,
            committed_notification_count: 0,
            unhandled_notification_count: 0,
            canonical_revision: StateRevision::ZERO,
            pending_server_requests: Vec::new(),
            retained_thread_count: 0,
        };

        let (commands, receiver) = mpsc::channel(session_limits.maximum_buffered_commands);
        let (revision_sender, revisions) = watch::channel(snapshot.revision);
        tokio::spawn(run_actor(
            config,
            connection,
            receiver,
            revision_sender,
            snapshot,
            bootstrap.buffered,
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

    /// Read the framework-neutral canonical replica through its sole owner.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Closed`] when the actor is gone.
    pub async fn canonical_snapshot(&self) -> Result<CanonicalState, SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::CanonicalSnapshot { reply })
            .await?;
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

    /// Acquire a semantic thread subscription/retention lease.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] when registry allocation or the required
    /// subscribe write fails.
    pub async fn acquire_thread(
        &self,
        thread_id: ThreadId,
        reason: LeaseReason,
    ) -> Result<ThreadLease, SessionError> {
        let (reply, response) = oneshot::channel();
        self.send_command(Command::AcquireLease {
            thread_id: thread_id.clone(),
            reason,
            reply,
        })
        .await?;
        let lease_id = response.await.map_err(|_| SessionError::Closed)??;
        Ok(ThreadLease {
            client: self.clone(),
            thread_id,
            lease_id: Some(lease_id),
        })
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

/// Unique semantic retention capability for one thread.
///
/// Call [`Self::close`] for deterministic unsubscribe. `Drop` only enqueues a
/// best-effort release and cannot await the resulting control request.
pub struct ThreadLease {
    client: AppServerClient,
    thread_id: ThreadId,
    lease_id: Option<LeaseId>,
}

impl ThreadLease {
    /// Retained thread identity.
    #[must_use]
    pub fn thread_id(&self) -> &ThreadId {
        &self.thread_id
    }

    /// Release this reason and await any required unsubscribe write.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError`] when the actor or control write fails.
    pub async fn close(mut self) -> Result<(), SessionError> {
        let Some(lease_id) = self.lease_id.take() else {
            return Ok(());
        };
        let (reply, response) = oneshot::channel();
        self.client
            .send_command(Command::ReleaseLease {
                lease_id,
                reply: Some(reply),
            })
            .await?;
        response.await.map_err(|_| SessionError::Closed)?
    }
}

impl Drop for ThreadLease {
    fn drop(&mut self) {
        let Some(lease_id) = self.lease_id.take() else {
            return;
        };
        let _ = self.client.commands.try_send(Command::ReleaseLease {
            lease_id,
            reply: None,
        });
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
    CanonicalSnapshot {
        reply: oneshot::Sender<CanonicalState>,
    },
    ResolveServerRequest {
        key: ServerRequestKey,
        resolution: ServerRequestResolution,
        reply: oneshot::Sender<Result<(), SessionError>>,
    },
    AcquireLease {
        thread_id: ThreadId,
        reason: LeaseReason,
        reply: oneshot::Sender<Result<LeaseId, SessionError>>,
    },
    ReleaseLease {
        lease_id: LeaseId,
        reply: Option<oneshot::Sender<Result<(), SessionError>>>,
    },
    Close {
        reply: oneshot::Sender<Result<(), SessionError>>,
    },
}

struct PendingClientRequest {
    method: String,
    id: JsonRpcId,
    write_attempted: bool,
    completion: PendingCompletion,
}

enum PendingCompletion {
    Public(oneshot::Sender<Result<RequestResult, SessionError>>),
    Lease {
        thread_id: ThreadId,
        operation_id: LeaseOperationId,
        subscribing: bool,
    },
}

struct BufferedEnvelope {
    cursor: WireCursor,
    envelope: Envelope,
}

struct BootstrapResult {
    server: ConnectedServer,
    initialize_cursor: WireCursor,
    buffered: VecDeque<BufferedEnvelope>,
}

struct ActorState {
    snapshot: SessionSnapshot,
    canonical: CanonicalStateReducer,
    leases: ThreadLeaseRegistry,
    queued_lease_actions: VecDeque<LeaseAction>,
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

    fn enqueue_lease_actions(&mut self, actions: Vec<LeaseAction>) {
        self.queued_lease_actions.extend(actions);
        self.snapshot.retained_thread_count = self.leases.retained_thread_count();
    }
}

async fn bootstrap(
    connection: &mut StdioConnection,
    config: &LocalSessionConfig,
    limits: SessionLimits,
    connection_epoch: u64,
) -> Result<BootstrapResult, SessionError> {
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
        let frame = connection.next_frame().await.ok_or_else(|| {
            SessionError::Transport("connection ended during initialize".to_owned())
        })??;
        ordinal = ordinal
            .checked_add(1)
            .ok_or(SessionError::RevisionExhausted)?;
        let cursor = WireCursor {
            connection_epoch,
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

    Ok(BootstrapResult {
        server,
        initialize_cursor: WireCursor {
            connection_epoch,
            ordinal,
        },
        buffered,
    })
}

async fn run_actor(
    config: LocalSessionConfig,
    mut connection: StdioConnection,
    mut commands: mpsc::Receiver<Command>,
    revisions: watch::Sender<StateRevision>,
    snapshot: SessionSnapshot,
    mut buffered: VecDeque<BufferedEnvelope>,
) {
    let mut state = ActorState {
        snapshot,
        canonical: CanonicalStateReducer::default(),
        leases: ThreadLeaseRegistry::new(true),
        queued_lease_actions: VecDeque::new(),
        pending_client_requests: HashMap::new(),
        pending_server_requests: BTreeMap::new(),
        next_request_id: 1,
    };

    if drain_buffered(&mut state, &mut buffered).is_err() {
        let _ = connection.close().await;
        return;
    }
    if *revisions.borrow() != state.snapshot.revision {
        let _ = revisions.send(state.snapshot.revision);
    }

    loop {
        match drive_connection(&mut state, &mut connection, &mut commands, &revisions).await {
            ConnectionExit::Close(reply) => {
                transition_phase(
                    &mut state,
                    ConnectionPhase::Closed,
                    &SessionError::Closed,
                    &revisions,
                );
                let result = connection.close().await.map_err(SessionError::from);
                let _ = reply.send(result);
                return;
            }
            ConnectionExit::CommandsClosed => {
                transition_phase(
                    &mut state,
                    ConnectionPhase::Closed,
                    &SessionError::Closed,
                    &revisions,
                );
                let _ = connection.close().await;
                return;
            }
            ConnectionExit::Disconnected(error) => {
                transition_phase(
                    &mut state,
                    ConnectionPhase::Disconnected,
                    &error,
                    &revisions,
                );
                let _ = connection.close().await;
                if !error.permits_reconnect() {
                    return;
                }
                match reconnect(&config, &mut state, &revisions).await {
                    Ok(reconnected) => connection = reconnected,
                    Err(_) => return,
                }
            }
        }
    }
}

enum ConnectionExit {
    Close(oneshot::Sender<Result<(), SessionError>>),
    CommandsClosed,
    Disconnected(SessionError),
}

async fn drive_connection(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    commands: &mut mpsc::Receiver<Command>,
    revisions: &watch::Sender<StateRevision>,
) -> ConnectionExit {
    let mut ordinal = state
        .snapshot
        .last_wire_cursor
        .filter(|cursor| cursor.connection_epoch == state.snapshot.connection_epoch)
        .map_or(0, |cursor| cursor.ordinal);
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { return ConnectionExit::CommandsClosed };
                match handle_command(state, connection, command).await {
                    CommandOutcome::Continue => {}
                    CommandOutcome::Committed => { let _ = revisions.send(state.snapshot.revision); }
                    CommandOutcome::Close(reply) => return ConnectionExit::Close(reply),
                    CommandOutcome::Fatal(error) => return ConnectionExit::Disconnected(error),
                }
            }
            frame = connection.next_frame() => {
                let result = match frame {
                    Some(Ok(frame)) => {
                        ordinal = match ordinal.checked_add(1) {
                            Some(value) => value,
                            None => return ConnectionExit::Disconnected(SessionError::RevisionExhausted),
                        };
                        let cursor = WireCursor {
                            connection_epoch: state.snapshot.connection_epoch,
                            ordinal,
                        };
                        decode_frame(&frame)
                            .map_err(|error| SessionError::Protocol(error.to_string()))
                            .and_then(|envelope| apply_envelope(state, cursor, envelope))
                    }
                    Some(Err(error)) => Err(SessionError::Transport(error.to_string())),
                    None => Err(SessionError::Transport("transport ingress ended".to_owned())),
                };
                match result {
                    Ok(()) => {
                        if let Err(error) = flush_lease_actions(state, connection).await {
                            return ConnectionExit::Disconnected(error);
                        }
                        let _ = revisions.send(state.snapshot.revision);
                    }
                    Err(error) => return ConnectionExit::Disconnected(error),
                }
            }
        }
    }
}

fn transition_phase(
    state: &mut ActorState,
    phase: ConnectionPhase,
    cause: &SessionError,
    revisions: &watch::Sender<StateRevision>,
) {
    state.snapshot.phase = phase;
    state.leases.connection_lost();
    state.queued_lease_actions.clear();
    state.snapshot.retained_thread_count = state.leases.retained_thread_count();
    state.pending_server_requests.clear();
    state.rebuild_pending_projection();
    if state.commit(None).is_ok() {
        let _ = revisions.send(state.snapshot.revision);
    }
    seal_pending(state, cause);
}

async fn reconnect(
    config: &LocalSessionConfig,
    state: &mut ActorState,
    revisions: &watch::Sender<StateRevision>,
) -> Result<StdioConnection, SessionError> {
    let policy = config.reconnect_policy;
    let mut delay = policy.initial_delay;
    let mut next_epoch = state.snapshot.connection_epoch;
    let mut last_error = SessionError::Closed;

    for _ in 0..policy.maximum_attempts {
        if !delay.is_zero() {
            tokio::time::sleep(delay).await;
        }
        next_epoch = next_epoch
            .checked_add(1)
            .ok_or(SessionError::RevisionExhausted)?;
        let mut connection = match StdioConnection::spawn(&config.stdio, config.transport_limits) {
            Ok(connection) => connection,
            Err(error) => {
                last_error = SessionError::from(error);
                delay = delay.saturating_mul(2).min(policy.maximum_delay);
                continue;
            }
        };
        match bootstrap(&mut connection, config, config.session_limits, next_epoch).await {
            Ok(mut bootstrap) => {
                state.snapshot.connection_epoch = next_epoch;
                state.snapshot.last_wire_cursor = Some(bootstrap.initialize_cursor);
                state.snapshot.server = bootstrap.server;
                state.snapshot.phase = ConnectionPhase::Connected;
                state.commit(None)?;
                drain_buffered(state, &mut bootstrap.buffered)?;
                let actions = state
                    .leases
                    .connection_restored()
                    .map_err(|error| SessionError::Lease(error.to_string()))?;
                state.enqueue_lease_actions(actions);
                flush_lease_actions(state, &mut connection).await?;
                let _ = revisions.send(state.snapshot.revision);
                return Ok(connection);
            }
            Err(error) => {
                if !error.permits_reconnect() {
                    let _ = connection.close().await;
                    return Err(error);
                }
                last_error = error;
                let _ = connection.close().await;
            }
        }
        delay = delay.saturating_mul(2).min(policy.maximum_delay);
    }
    Err(SessionError::ReconnectExhausted(last_error.to_string()))
}

fn drain_buffered(
    state: &mut ActorState,
    buffered: &mut VecDeque<BufferedEnvelope>,
) -> Result<(), SessionError> {
    while let Some(buffered) = buffered.pop_front() {
        apply_envelope(state, buffered.cursor, buffered.envelope)?;
    }
    Ok(())
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
        } => handle_request_command(state, connection, method, params, reply).await,
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
        Command::CanonicalSnapshot { reply } => {
            let _ = reply.send(state.canonical.snapshot().clone());
            CommandOutcome::Continue
        }
        Command::ResolveServerRequest {
            key,
            resolution,
            reply,
        } => handle_server_resolution(state, connection, key, resolution, reply).await,
        Command::AcquireLease {
            thread_id,
            reason,
            reply,
        } => handle_acquire_lease(state, connection, thread_id, reason, reply).await,
        Command::ReleaseLease { lease_id, reply } => {
            handle_release_lease(state, connection, lease_id, reply).await
        }
        Command::Close { reply } => CommandOutcome::Close(reply),
    }
}

async fn handle_acquire_lease(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    thread_id: ThreadId,
    reason: LeaseReason,
    reply: oneshot::Sender<Result<LeaseId, SessionError>>,
) -> CommandOutcome {
    let (lease_id, actions) = match state.leases.acquire(thread_id, reason) {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(SessionError::Lease(error.to_string())));
            return CommandOutcome::Continue;
        }
    };
    state.enqueue_lease_actions(actions);
    if let Err(error) = flush_lease_actions(state, connection).await {
        let _ = reply.send(Err(error.clone()));
        return CommandOutcome::Fatal(error);
    }
    if let Err(error) = state.commit(None) {
        let _ = reply.send(Err(error.clone()));
        return CommandOutcome::Fatal(error);
    }
    let _ = reply.send(Ok(lease_id));
    CommandOutcome::Committed
}

async fn handle_release_lease(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    lease_id: LeaseId,
    reply: Option<oneshot::Sender<Result<(), SessionError>>>,
) -> CommandOutcome {
    let actions = match state.leases.release(lease_id) {
        Ok(actions) => actions,
        Err(error) => {
            let error = SessionError::Lease(error.to_string());
            if let Some(reply) = reply {
                let _ = reply.send(Err(error));
            }
            return CommandOutcome::Continue;
        }
    };
    state.enqueue_lease_actions(actions);
    if let Err(error) = flush_lease_actions(state, connection).await {
        if let Some(reply) = reply {
            let _ = reply.send(Err(error.clone()));
        }
        return CommandOutcome::Fatal(error);
    }
    if let Err(error) = state.commit(None) {
        if let Some(reply) = reply {
            let _ = reply.send(Err(error.clone()));
        }
        return CommandOutcome::Fatal(error);
    }
    if let Some(reply) = reply {
        let _ = reply.send(Ok(()));
    }
    CommandOutcome::Committed
}

async fn handle_request_command(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    method: String,
    params: Value,
    reply: oneshot::Sender<Result<RequestResult, SessionError>>,
) -> CommandOutcome {
    let id = match allocate_request_id(state) {
        Ok(id) => id,
        Err(error) => {
            let _ = reply.send(Err(error));
            return CommandOutcome::Continue;
        }
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
            completion: PendingCompletion::Public(reply),
        },
    );
    if connection.write(&frame).await.is_err() {
        let error = SessionError::IndeterminateRequest { method, id };
        return CommandOutcome::Fatal(error);
    }
    CommandOutcome::Continue
}

async fn handle_server_resolution(
    state: &mut ActorState,
    connection: &mut StdioConnection,
    key: ServerRequestKey,
    resolution: ServerRequestResolution,
    reply: oneshot::Sender<Result<(), SessionError>>,
) -> CommandOutcome {
    if !state.pending_server_requests.contains_key(&key) {
        let _ = reply.send(Err(SessionError::PendingServerRequestNotFound));
        return CommandOutcome::Continue;
    }
    let frame = match resolution {
        ServerRequestResolution::Result(result) => encode_result(key.request_id.clone(), result),
        ServerRequestResolution::Error(error) => encode_error(key.request_id.clone(), error),
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

async fn flush_lease_actions(
    state: &mut ActorState,
    connection: &mut StdioConnection,
) -> Result<(), SessionError> {
    while let Some(action) = state.queued_lease_actions.pop_front() {
        let (thread_id, operation_id, subscribing, method) = match action {
            LeaseAction::Subscribe {
                thread_id,
                operation_id,
            } => (thread_id, operation_id, true, "thread/resume"),
            LeaseAction::Unsubscribe {
                thread_id,
                operation_id,
            } => (thread_id, operation_id, false, "thread/unsubscribe"),
        };
        let id = allocate_request_id(state)?;
        let frame = encode_request(
            id.clone(),
            method,
            Some(json!({"threadId": thread_id.as_str()})),
        )
        .map_err(|error| SessionError::Protocol(error.to_string()))?;
        state.pending_client_requests.insert(
            id.clone(),
            PendingClientRequest {
                method: method.to_owned(),
                id,
                write_attempted: true,
                completion: PendingCompletion::Lease {
                    thread_id,
                    operation_id,
                    subscribing,
                },
            },
        );
        connection.write(&frame).await?;
    }
    Ok(())
}

fn allocate_request_id(state: &mut ActorState) -> Result<JsonRpcId, SessionError> {
    let id = JsonRpcId::Integer(state.next_request_id);
    state.next_request_id = state
        .next_request_id
        .checked_add(1)
        .ok_or(SessionError::RevisionExhausted)?;
    Ok(id)
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
                match pending.completion {
                    PendingCompletion::Public(reply) => {
                        let result = match response.outcome {
                            ResponseOutcome::Result(value) => Ok(RequestResult {
                                value,
                                committed_revision: revision,
                            }),
                            ResponseOutcome::Error(error) => Err(SessionError::Rpc(error)),
                        };
                        let _ = reply.send(result);
                    }
                    PendingCompletion::Lease {
                        thread_id,
                        operation_id,
                        subscribing,
                    } => {
                        let succeeded = matches!(response.outcome, ResponseOutcome::Result(_));
                        let actions = if subscribing {
                            state
                                .leases
                                .complete_subscribe(&thread_id, operation_id, succeeded)
                        } else {
                            state
                                .leases
                                .complete_unsubscribe(&thread_id, operation_id, succeeded)
                        }
                        .map_err(|error| SessionError::Lease(error.to_string()))?;
                        state.enqueue_lease_actions(actions);
                    }
                }
            }
        }
        Envelope::Notification(NotificationEnvelope { method, params }) => {
            match adapt_notification(&method, &params)
                .map_err(|error| SessionError::Adapter(error.to_string()))?
            {
                NotificationDisposition::Mutations(mutations) => {
                    if let Some(batch) = state
                        .canonical
                        .apply(&mutations)
                        .map_err(|error| SessionError::Canonical(error.to_string()))?
                    {
                        state.snapshot.canonical_revision = batch.revision;
                    }
                }
                NotificationDisposition::Unhandled { .. } => {
                    state.snapshot.unhandled_notification_count = state
                        .snapshot
                        .unhandled_notification_count
                        .checked_add(1)
                        .ok_or(SessionError::RevisionExhausted)?;
                }
            }
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
        if let PendingCompletion::Public(reply) = pending.completion {
            let error = if pending.write_attempted {
                SessionError::IndeterminateRequest {
                    method: pending.method,
                    id: pending.id,
                }
            } else {
                cause.clone()
            };
            let _ = reply.send(Err(error));
        }
    }
    state.pending_server_requests.clear();
    state.rebuild_pending_projection();
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

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

    async fn wait_for_file(path: &Path) -> String {
        for _ in 0..100 {
            if let Ok(value) = std::fs::read_to_string(path) {
                return value;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("timed out waiting for {}", path.display());
    }

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
            "read init; printf '%s\\n' '{{\"method\":\"test/notification\",\"params\":{{}}}}'; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; sleep 1"
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let snapshot = client.snapshot().await.expect("read snapshot");
        assert_eq!(snapshot.committed_notification_count, 1);
        assert_eq!(snapshot.unhandled_notification_count, 1);
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

    #[cfg(unix)]
    #[tokio::test]
    async fn known_notification_reduces_before_revision_signal() {
        let script = format!(
            "read init; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; printf '%s\\n' '{{\"method\":\"item/agentMessage/delta\",\"params\":{{\"threadId\":\"thread\",\"turnId\":\"turn\",\"itemId\":\"item\",\"delta\":\"hello\"}}}}'; sleep 1"
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let mut observation = client.observe().await.expect("observe session");
        let mut snapshot = observation.seed().clone();
        while snapshot.canonical_revision == StateRevision::ZERO {
            observation.changed().await.expect("canonical invalidation");
            snapshot = client.snapshot().await.expect("reread session");
        }
        let canonical = client
            .canonical_snapshot()
            .await
            .expect("read canonical state");
        assert_eq!(snapshot.canonical_revision, canonical.revision);
        assert_eq!(canonical.revision, StateRevision::new(1));
        client.close().await.expect("close session");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reconnects_without_replaying_written_request() {
        let directory = tempfile::tempdir().expect("temporary marker directory");
        let marker = directory.path().join("first-connection-finished");
        let script = format!(
            r#"
read init
printf '%s\n' '{INITIALIZE_RESPONSE}'
read initialized
if [ ! -e '{marker}' ]; then
  touch '{marker}'
  read first_request
  exit 9
fi
read second_request
case "$second_request" in
  *'"id":2'*) printf '%s\n' '{{"id":2,"result":{{"recovered":true}}}}' ;;
  *) exit 10 ;;
esac
sleep 1
"#,
            marker = marker.display(),
        );
        let mut config = shell_config(&script);
        config.reconnect_policy = ReconnectPolicy {
            maximum_attempts: 2,
            initial_delay: Duration::from_millis(10),
            maximum_delay: Duration::from_millis(20),
        };
        let client = AppServerClient::connect_local(config)
            .await
            .expect("connect first physical session");

        let first = client
            .request("thread/start", json!({}))
            .await
            .expect_err("written request becomes indeterminate");
        assert!(matches!(
            first,
            SessionError::IndeterminateRequest {
                id: JsonRpcId::Integer(1),
                ..
            }
        ));

        let reconnected = client.snapshot().await.expect("actor reconnected");
        assert_eq!(reconnected.connection_epoch, 2);
        assert_eq!(reconnected.phase, ConnectionPhase::Connected);

        let second = client
            .request("model/list", json!({}))
            .await
            .expect("new explicit request succeeds");
        assert_eq!(second.value, json!({"recovered": true}));
        client.close().await.expect("close reconnected session");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn malformed_known_notification_is_fatal_without_reconnect() {
        let directory = tempfile::tempdir().expect("temporary marker directory");
        let marker = directory.path().join("launches");
        let script = format!(
            r#"
printf 'launch\n' >> '{marker}'
read init
printf '%s\n' '{INITIALIZE_RESPONSE}'
read initialized
printf '%s\n' '{{"method":"item/agentMessage/delta","params":{{"threadId":"thread"}}}}'
sleep 1
"#,
            marker = marker.display(),
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("initial handshake succeeds");
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            std::fs::read_to_string(marker).expect("read launch count"),
            "launch\n"
        );
        assert_eq!(client.snapshot().await, Err(SessionError::Closed));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn thread_lease_executes_internal_resume_and_unsubscribe() {
        let directory = tempfile::tempdir().expect("temporary marker directory");
        let marker = directory.path().join("unsubscribed");
        let script = format!(
            r#"
read init
printf '%s\n' '{INITIALIZE_RESPONSE}'
read initialized
read resume
case "$resume" in *'thread/resume'*) ;; *) exit 11 ;; esac
printf '%s\n' '{{"id":1,"result":{{}}}}'
read unsubscribe
case "$unsubscribe" in *'thread/unsubscribe'*) ;; *) exit 12 ;; esac
printf 'done\n' > '{marker}'
printf '%s\n' '{{"id":2,"result":{{}}}}'
sleep 1
"#,
            marker = marker.display(),
        );
        let client = AppServerClient::connect_local(shell_config(&script))
            .await
            .expect("connect session");
        let lease = client
            .acquire_thread(ThreadId::from("thread"), LeaseReason::Selected)
            .await
            .expect("acquire lease");
        assert_eq!(lease.thread_id(), &ThreadId::from("thread"));
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            client
                .snapshot()
                .await
                .expect("retained snapshot")
                .retained_thread_count,
            1
        );
        lease.close().await.expect("release lease");
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            std::fs::read_to_string(marker).expect("unsubscribe observed"),
            "done\n"
        );
        assert_eq!(
            client
                .snapshot()
                .await
                .expect("released snapshot")
                .retained_thread_count,
            0
        );
        client.close().await.expect("close session");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn retained_thread_resubscribes_on_new_connection_epoch() {
        let directory = tempfile::tempdir().expect("temporary marker directory");
        let first = directory.path().join("first");
        let resumed = directory.path().join("resumed");
        let unsubscribed = directory.path().join("unsubscribed");
        let script = format!(
            r#"
if [ ! -e '{first}' ]; then touch '{first}'; generation=first; else generation=second; fi
read init
printf '%s\n' '{INITIALIZE_RESPONSE}'
read initialized
read resume
case "$resume" in *'thread/resume'*) ;; *) exit 21 ;; esac
if [ "$generation" = first ]; then
  printf '%s\n' '{{"id":1,"result":{{}}}}'
  exit 9
fi
case "$resume" in *'"id":2'*) ;; *) exit 22 ;; esac
printf 'resumed\n' > '{resumed}'
printf '%s\n' '{{"id":2,"result":{{}}}}'
read unsubscribe
case "$unsubscribe" in *'thread/unsubscribe'*) ;; *) exit 23 ;; esac
case "$unsubscribe" in *'"id":3'*) ;; *) exit 24 ;; esac
printf 'unsubscribed\n' > '{unsubscribed}'
printf '%s\n' '{{"id":3,"result":{{}}}}'
sleep 1
"#,
            first = first.display(),
            resumed = resumed.display(),
            unsubscribed = unsubscribed.display(),
        );
        let mut config = shell_config(&script);
        config.reconnect_policy = ReconnectPolicy {
            maximum_attempts: 2,
            initial_delay: Duration::from_millis(10),
            maximum_delay: Duration::from_millis(20),
        };
        let client = AppServerClient::connect_local(config)
            .await
            .expect("connect session");
        let lease = client
            .acquire_thread(ThreadId::from("thread"), LeaseReason::ActiveTurn)
            .await
            .expect("acquire retained thread");

        let mut observation = client.observe().await.expect("observe reconnect");
        let mut reconnected = observation.seed().clone();
        while reconnected.connection_epoch < 2 {
            observation.changed().await.expect("reconnect invalidation");
            reconnected = client.snapshot().await.expect("reconnected snapshot");
        }
        assert_eq!(reconnected.connection_epoch, 2);
        assert_eq!(wait_for_file(&resumed).await, "resumed\n");

        lease.close().await.expect("release retained thread");
        assert_eq!(wait_for_file(&unsubscribed).await, "unsubscribed\n");
        client.close().await.expect("close session");
    }
}
