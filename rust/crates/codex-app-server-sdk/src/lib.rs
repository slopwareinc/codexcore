//! Ergonomic thread/turn facade over the ordered App Server client.

use std::{collections::BTreeMap, path::PathBuf};

use codex_app_server_client::{
    AppServerClient, LocalSessionConfig, RequestResult, SessionError, ThreadLease,
};
use codex_app_server_lease::LeaseReason;
use codex_app_server_state::{ThreadId, TurnId};
use serde_json::{Map, Value, json};
use thiserror::Error;

/// SDK facade or response-shape failure.
#[derive(Debug, Error)]
pub enum SdkError {
    /// Ordered session failure.
    #[error(transparent)]
    Session(#[from] SessionError),
    /// Successful response omitted a required identity.
    #[error("{method} response is missing {field}")]
    MissingResponseField {
        /// Request method.
        method: &'static str,
        /// Dotted field path.
        field: &'static str,
    },
}

/// Supported image detail request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ImageDetail {
    /// Let the runtime choose.
    Auto,
    /// Lower token/detail budget.
    Low,
    /// Higher token/detail budget.
    High,
}

impl ImageDetail {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Low => "low",
            Self::High => "high",
        }
    }
}

/// Convenience builder for App Server `UserInput` variants.
#[derive(Clone, Debug, PartialEq)]
pub enum CodexInput {
    /// User text.
    Text(String),
    /// Remote/data image URL.
    Image {
        url: String,
        detail: Option<ImageDetail>,
    },
    /// Absolute or host-resolved local image path.
    LocalImage {
        path: PathBuf,
        detail: Option<ImageDetail>,
    },
    /// Remote/data audio URL.
    Audio(String),
    /// Local audio path.
    LocalAudio(PathBuf),
    /// Skill invocation/reference.
    Skill { name: String, path: PathBuf },
    /// File mention/reference.
    Mention { name: String, path: PathBuf },
    /// Lossless escape hatch for future input variants.
    Raw(Value),
}

impl CodexInput {
    /// Text input.
    #[must_use]
    pub fn text(value: impl Into<String>) -> Self {
        Self::Text(value.into())
    }

    /// Convert into the exact wire object.
    #[must_use]
    pub fn into_value(self) -> Value {
        match self {
            Self::Text(text) => json!({"type": "text", "text": text}),
            Self::Image { url, detail } => image_value("image", "url", url, detail),
            Self::LocalImage { path, detail } => image_value(
                "localImage",
                "path",
                path.to_string_lossy().into_owned(),
                detail,
            ),
            Self::Audio(url) => json!({"type": "audio", "url": url}),
            Self::LocalAudio(path) => {
                json!({"type": "localAudio", "path": path.to_string_lossy()})
            }
            Self::Skill { name, path } => {
                json!({"type": "skill", "name": name, "path": path.to_string_lossy()})
            }
            Self::Mention { name, path } => {
                json!({"type": "mention", "name": name, "path": path.to_string_lossy()})
            }
            Self::Raw(value) => value,
        }
    }
}

fn image_value(
    kind: &str,
    location_key: &str,
    location: String,
    detail: Option<ImageDetail>,
) -> Value {
    let mut value = Map::from_iter([
        ("type".to_owned(), Value::String(kind.to_owned())),
        (location_key.to_owned(), Value::String(location)),
    ]);
    if let Some(detail) = detail {
        value.insert(
            "detail".to_owned(),
            Value::String(detail.as_str().to_owned()),
        );
    }
    Value::Object(value)
}

/// New thread overrides. Unspecified fields remain App Server defaults.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct StartThreadOptions {
    /// Initial working directory.
    pub cwd: Option<PathBuf>,
    /// Model override.
    pub model: Option<String>,
    /// Named permission profile.
    pub permissions: Option<String>,
    /// Service tier override.
    pub service_tier: Option<String>,
    /// Create an in-memory/non-persisted thread.
    pub ephemeral: Option<bool>,
    /// Additional exact protocol fields.
    pub extra: BTreeMap<String, Value>,
}

/// Resume options. Thread identity is supplied separately.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ResumeThreadOptions {
    /// Do not include turn bodies in the response.
    pub exclude_turns: Option<bool>,
    /// Named permission profile.
    pub permissions: Option<String>,
    /// Additional exact protocol fields.
    pub extra: BTreeMap<String, Value>,
}

/// Per-turn overrides.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TurnOptions {
    /// Model override.
    pub model: Option<String>,
    /// Reasoning effort wire value.
    pub effort: Option<String>,
    /// Named permission profile.
    pub permissions: Option<String>,
    /// Service tier override.
    pub service_tier: Option<String>,
    /// Stable local submission identity for echo reconciliation.
    pub client_user_message_id: Option<String>,
    /// Optional output JSON Schema.
    pub output_schema: Option<Value>,
    /// Additional exact protocol fields.
    pub extra: BTreeMap<String, Value>,
}

/// Root SDK facade.
#[derive(Clone)]
pub struct Codex {
    client: AppServerClient,
}

impl Codex {
    /// Launch and initialize a local App Server.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] when session initialization fails.
    pub async fn connect_local(config: LocalSessionConfig) -> Result<Self, SdkError> {
        Ok(Self {
            client: AppServerClient::connect_local(config).await?,
        })
    }

    /// Wrap an already initialized ordered client.
    #[must_use]
    pub const fn from_client(client: AppServerClient) -> Self {
        Self { client }
    }

    /// Raw client escape hatch.
    #[must_use]
    pub const fn client(&self) -> &AppServerClient {
        &self.client
    }

    /// Start and retain a new thread.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] for request, response-shape, or lease failures.
    pub async fn start_thread(&self, options: StartThreadOptions) -> Result<CodexThread, SdkError> {
        let result = self
            .client
            .request("thread/start", start_params(options))
            .await?;
        self.adopt_thread_result("thread/start", result).await
    }

    /// Resume and retain an existing thread.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] for request, response-shape, or lease failures.
    pub async fn resume_thread(
        &self,
        thread_id: ThreadId,
        options: ResumeThreadOptions,
    ) -> Result<CodexThread, SdkError> {
        let mut params = options.extra;
        params.insert("threadId".to_owned(), Value::String(thread_id.to_string()));
        insert_option(&mut params, "excludeTurns", options.exclude_turns);
        insert_option(&mut params, "permissions", options.permissions);
        let result = self
            .client
            .request("thread/resume", Value::Object(params.into_iter().collect()))
            .await?;
        self.adopt_thread_result("thread/resume", result).await
    }

    async fn adopt_thread_result(
        &self,
        method: &'static str,
        result: RequestResult,
    ) -> Result<CodexThread, SdkError> {
        let id = result
            .value
            .pointer("/thread/id")
            .and_then(Value::as_str)
            .ok_or(SdkError::MissingResponseField {
                method,
                field: "thread.id",
            })?;
        let id = ThreadId::new(id);
        let lease = self
            .client
            .adopt_thread(id.clone(), LeaseReason::Selected)
            .await?;
        Ok(CodexThread {
            client: self.client.clone(),
            id,
            lease: Some(lease),
        })
    }

    /// Close the ordered session.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] if deterministic process shutdown fails.
    pub async fn close(&self) -> Result<(), SdkError> {
        self.client.close().await.map_err(Into::into)
    }
}

/// Retained thread facade.
pub struct CodexThread {
    client: AppServerClient,
    id: ThreadId,
    lease: Option<ThreadLease>,
}

impl CodexThread {
    /// Thread identity.
    #[must_use]
    pub fn id(&self) -> &ThreadId {
        &self.id
    }

    /// Start a turn and retain the thread for its active lifetime.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] for request, response-shape, or lease failures.
    pub async fn start_turn(
        &self,
        input: Vec<CodexInput>,
        options: TurnOptions,
    ) -> Result<CodexTurn, SdkError> {
        let result = self
            .client
            .request("turn/start", turn_params(&self.id, input, options))
            .await?;
        let turn_id = result
            .value
            .pointer("/turn/id")
            .and_then(Value::as_str)
            .ok_or(SdkError::MissingResponseField {
                method: "turn/start",
                field: "turn.id",
            })?;
        let lease = self
            .client
            .acquire_thread(self.id.clone(), LeaseReason::ActiveTurn)
            .await?;
        Ok(CodexTurn {
            client: self.client.clone(),
            thread_id: self.id.clone(),
            turn_id: TurnId::new(turn_id),
            lease: Some(lease),
        })
    }

    /// Release selected-thread retention.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] if release control fails.
    pub async fn close(mut self) -> Result<(), SdkError> {
        if let Some(lease) = self.lease.take() {
            lease.close().await?;
        }
        Ok(())
    }
}

/// Active turn capability.
pub struct CodexTurn {
    client: AppServerClient,
    thread_id: ThreadId,
    turn_id: TurnId,
    lease: Option<ThreadLease>,
}

impl CodexTurn {
    /// Turn identity.
    #[must_use]
    pub fn id(&self) -> &TurnId {
        &self.turn_id
    }

    /// Interrupt this exact turn.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] when the request fails.
    pub async fn interrupt(&self) -> Result<(), SdkError> {
        self.client
            .request(
                "turn/interrupt",
                json!({
                    "threadId": self.thread_id.as_str(), "turnId": self.turn_id.as_str()
                }),
            )
            .await?;
        Ok(())
    }

    /// Add input to this exact active turn.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] when steering fails.
    pub async fn steer(&self, input: Vec<CodexInput>) -> Result<(), SdkError> {
        self.client
            .request(
                "turn/steer",
                json!({
                    "threadId": self.thread_id.as_str(),
                    "expectedTurnId": self.turn_id.as_str(),
                    "input": input.into_iter().map(CodexInput::into_value).collect::<Vec<_>>(),
                }),
            )
            .await?;
        Ok(())
    }

    /// Release active-turn retention.
    ///
    /// # Errors
    ///
    /// Returns [`SdkError`] if release control fails.
    pub async fn close(mut self) -> Result<(), SdkError> {
        if let Some(lease) = self.lease.take() {
            lease.close().await?;
        }
        Ok(())
    }
}

fn start_params(options: StartThreadOptions) -> Value {
    let mut params = options.extra;
    insert_option(
        &mut params,
        "cwd",
        options
            .cwd
            .map(|value| value.to_string_lossy().into_owned()),
    );
    insert_option(&mut params, "model", options.model);
    insert_option(&mut params, "permissions", options.permissions);
    insert_option(&mut params, "serviceTier", options.service_tier);
    insert_option(&mut params, "ephemeral", options.ephemeral);
    Value::Object(params.into_iter().collect())
}

fn turn_params(thread_id: &ThreadId, input: Vec<CodexInput>, options: TurnOptions) -> Value {
    let mut params = options.extra;
    params.insert("threadId".to_owned(), Value::String(thread_id.to_string()));
    params.insert(
        "input".to_owned(),
        Value::Array(input.into_iter().map(CodexInput::into_value).collect()),
    );
    insert_option(&mut params, "model", options.model);
    insert_option(&mut params, "effort", options.effort);
    insert_option(&mut params, "permissions", options.permissions);
    insert_option(&mut params, "serviceTier", options.service_tier);
    insert_option(
        &mut params,
        "clientUserMessageId",
        options.client_user_message_id,
    );
    if let Some(schema) = options.output_schema {
        params.insert("outputSchema".to_owned(), schema);
    }
    Value::Object(params.into_iter().collect())
}

fn insert_option<T: Into<Value>>(map: &mut BTreeMap<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        map.insert(key.to_owned(), value.into());
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use codex_app_server_transport::{StdioConfig, TransportLimits};

    use super::*;

    const INITIALIZE_RESPONSE: &str = r#"{"id":0,"result":{"userAgent":"test-server","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"test"}}"#;

    #[test]
    fn input_builders_preserve_protocol_shapes() {
        assert_eq!(
            CodexInput::text("hello").into_value(),
            json!({"type":"text","text":"hello"})
        );
        assert_eq!(
            CodexInput::LocalImage {
                path: PathBuf::from("/tmp/image.png"),
                detail: Some(ImageDetail::High)
            }
            .into_value(),
            json!({"type":"localImage","path":"/tmp/image.png","detail":"high"})
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn start_adopts_live_thread_without_redundant_resume() {
        let script = format!(
            "read init; printf '%s\\n' '{INITIALIZE_RESPONSE}'; read initialized; read start; case \"$start\" in *'thread/start'*) ;; *) exit 31 ;; esac; printf '%s\\n' '{{\"id\":1,\"result\":{{\"thread\":{{\"id\":\"thread\"}}}}}}'; read unsubscribe; case \"$unsubscribe\" in *'thread/unsubscribe'*) ;; *) exit 32 ;; esac; printf '%s\\n' '{{\"id\":2,\"result\":{{}}}}'; sleep 1"
        );
        let mut config = LocalSessionConfig::app_server("/bin/sh");
        config.stdio = StdioConfig {
            executable: PathBuf::from("/bin/sh"),
            arguments: vec!["-c".to_owned(), script],
            environment: BTreeMap::new(),
            current_directory: None,
        };
        config.transport_limits = TransportLimits::default();
        let codex = Codex::connect_local(config).await.expect("connect");
        let thread = codex
            .start_thread(StartThreadOptions::default())
            .await
            .expect("start");
        assert_eq!(thread.id(), &ThreadId::from("thread"));
        thread.close().await.expect("close thread");
        codex.close().await.expect("close session");
    }
}
