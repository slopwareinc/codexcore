//! Typed declarations and cancellation-safe dispatch for host dynamic tools.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    future::Future,
    pin::Pin,
    sync::Arc,
};

use codex_app_server_client::ServerRequestResolution;
pub use codex_app_server_interaction::DynamicToolContent;
use codex_app_server_interaction::{ServerRequestBody, ServerRequestReply, TypedServerRequest};
use codex_app_server_state::{ThreadId, TurnId};
use serde_json::{Map, Value};
use thiserror::Error;

const DYNAMIC_TOOL_METHOD: &str = "item/tool/call";

/// Validated JSON Schema used for one dynamic tool's arguments.
///
/// Construction compiles the schema with automatic draft detection. External
/// schema resolution is disabled both in dependency features and by an
/// explicit rejecting retriever, so registration and dispatch cannot read a
/// schema from the network or filesystem.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DynamicToolInputSchema {
    value: Value,
}

impl DynamicToolInputSchema {
    /// Validate and retain a JSON Schema.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolDeclarationError::InvalidInputSchema`] when the
    /// value cannot be compiled as a JSON Schema.
    pub fn new(value: Value) -> Result<Self, DynamicToolDeclarationError> {
        compile_input_schema(&value)?;
        Ok(Self { value })
    }

    /// The exact schema value advertised to App Server.
    #[must_use]
    pub const fn as_value(&self) -> &Value {
        &self.value
    }

    /// Consume this wrapper and return its exact schema value.
    #[must_use]
    pub fn into_value(self) -> Value {
        self.value
    }
}

impl TryFrom<Value> for DynamicToolInputSchema {
    type Error = DynamicToolDeclarationError;

    fn try_from(value: Value) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

fn compile_input_schema(
    schema: &Value,
) -> Result<jsonschema::Validator, DynamicToolDeclarationError> {
    jsonschema::options()
        .with_retriever(NoExternalSchemaRetriever)
        .build(schema)
        .map_err(|error| DynamicToolDeclarationError::InvalidInputSchema {
            message: error.to_string(),
        })
}

#[derive(Clone, Copy, Debug)]
struct NoExternalSchemaRetriever;

impl jsonschema::Retrieve for NoExternalSchemaRetriever {
    fn retrieve(
        &self,
        uri: &jsonschema::Uri<String>,
    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("external dynamic-tool schema reference is disabled: {uri}"),
        )))
    }
}

/// One function entry, either standalone or inside a namespace declaration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DynamicToolFunction {
    name: String,
    description: String,
    input_schema: DynamicToolInputSchema,
    defer_loading: Option<bool>,
}

impl DynamicToolFunction {
    /// Create a function declaration.
    #[must_use]
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        input_schema: DynamicToolInputSchema,
    ) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            input_schema,
            defer_loading: None,
        }
    }

    /// Set the optional `deferLoading` protocol field.
    #[must_use]
    pub const fn with_defer_loading(mut self, defer_loading: bool) -> Self {
        self.defer_loading = Some(defer_loading);
        self
    }

    /// Function name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Human-readable function description.
    #[must_use]
    pub fn description(&self) -> &str {
        &self.description
    }

    /// Validated argument schema.
    #[must_use]
    pub const fn input_schema(&self) -> &DynamicToolInputSchema {
        &self.input_schema
    }

    /// Whether App Server may defer loading this function.
    #[must_use]
    pub const fn defer_loading(&self) -> Option<bool> {
        self.defer_loading
    }

    fn wire_value(&self) -> Value {
        let mut value = Map::from_iter([
            ("type".to_owned(), Value::String("function".to_owned())),
            ("name".to_owned(), Value::String(self.name.clone())),
            (
                "description".to_owned(),
                Value::String(self.description.clone()),
            ),
            ("inputSchema".to_owned(), self.input_schema.value.clone()),
        ]);
        if let Some(defer_loading) = self.defer_loading {
            value.insert("deferLoading".to_owned(), Value::Bool(defer_loading));
        }
        Value::Object(value)
    }
}

/// A named group of dynamic functions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DynamicToolNamespace {
    name: String,
    description: String,
    tools: Vec<DynamicToolFunction>,
}

impl DynamicToolNamespace {
    /// Create a namespace, rejecting duplicate child function names.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolDeclarationError::DuplicateNamespaceTool`] when
    /// two child functions have the same name.
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        tools: Vec<DynamicToolFunction>,
    ) -> Result<Self, DynamicToolDeclarationError> {
        let name = name.into();
        let mut child_names = BTreeSet::new();
        for tool in &tools {
            if !child_names.insert(tool.name.clone()) {
                return Err(DynamicToolDeclarationError::DuplicateNamespaceTool {
                    namespace: name,
                    tool: tool.name.clone(),
                });
            }
        }
        Ok(Self {
            name,
            description: description.into(),
            tools,
        })
    }

    /// Namespace name sent with matching calls.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Human-readable namespace description.
    #[must_use]
    pub fn description(&self) -> &str {
        &self.description
    }

    /// Functions declared inside this namespace.
    #[must_use]
    pub fn tools(&self) -> &[DynamicToolFunction] {
        &self.tools
    }

    fn wire_value(&self) -> Value {
        Value::Object(Map::from_iter([
            ("type".to_owned(), Value::String("namespace".to_owned())),
            ("name".to_owned(), Value::String(self.name.clone())),
            (
                "description".to_owned(),
                Value::String(self.description.clone()),
            ),
            (
                "tools".to_owned(),
                Value::Array(
                    self.tools
                        .iter()
                        .map(DynamicToolFunction::wire_value)
                        .collect(),
                ),
            ),
        ]))
    }
}

/// Exact 0.148.0 `DynamicToolSpec` declaration variants.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DynamicToolDeclaration {
    /// A top-level function. Its calls carry no namespace.
    Function(DynamicToolFunction),
    /// A namespace whose calls carry the namespace name and a child tool name.
    Namespace(DynamicToolNamespace),
}

impl DynamicToolDeclaration {
    /// Top-level declaration name.
    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Function(function) => function.name(),
            Self::Namespace(namespace) => namespace.name(),
        }
    }

    /// Encode and validate the exact generated App Server declaration shape.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolDeclarationError::ProtocolSchema`] if the SDK's
    /// stable declaration no longer matches the pinned generated schema.
    pub fn to_wire_value(&self) -> Result<Value, DynamicToolDeclarationError> {
        let value = match self {
            Self::Function(function) => function.wire_value(),
            Self::Namespace(namespace) => namespace.wire_value(),
        };
        serde_json::from_value::<codex_app_server_types::DynamicToolSpec>(value.clone())
            .map(drop)
            .map_err(|error| DynamicToolDeclarationError::ProtocolSchema {
                message: error.to_string(),
            })?;
        Ok(value)
    }

    fn entries(&self) -> Vec<(DynamicToolKey, DynamicToolInputSchema)> {
        match self {
            Self::Function(function) => vec![(
                DynamicToolKey::new(None, function.name.clone()),
                function.input_schema.clone(),
            )],
            Self::Namespace(namespace) => namespace
                .tools
                .iter()
                .map(|tool| {
                    (
                        DynamicToolKey::new(Some(namespace.name.clone()), tool.name.clone()),
                        tool.input_schema.clone(),
                    )
                })
                .collect(),
        }
    }
}

impl From<DynamicToolFunction> for DynamicToolDeclaration {
    fn from(value: DynamicToolFunction) -> Self {
        Self::Function(value)
    }
}

impl From<DynamicToolNamespace> for DynamicToolDeclaration {
    fn from(value: DynamicToolNamespace) -> Self {
        Self::Namespace(value)
    }
}

/// Dynamic-tool declaration construction failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DynamicToolDeclarationError {
    /// Argument schema could not be compiled.
    #[error("invalid dynamic-tool input schema: {message}")]
    InvalidInputSchema { message: String },
    /// Two functions in one namespace share a name.
    #[error("dynamic-tool namespace {namespace} contains duplicate tool {tool}")]
    DuplicateNamespaceTool { namespace: String, tool: String },
    /// Stable SDK declaration drifted from the generated protocol schema.
    #[error("dynamic-tool declaration failed generated-schema validation: {message}")]
    ProtocolSchema { message: String },
}

/// Exact key used to match a declared tool with an App Server call.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct DynamicToolKey {
    namespace: Option<String>,
    tool: String,
}

impl DynamicToolKey {
    /// Construct an exact namespace/tool key.
    #[must_use]
    pub fn new(namespace: Option<String>, tool: impl Into<String>) -> Self {
        Self {
            namespace,
            tool: tool.into(),
        }
    }

    /// Optional namespace. Standalone functions return `None`.
    #[must_use]
    pub fn namespace(&self) -> Option<&str> {
        self.namespace.as_deref()
    }

    /// Function name within the optional namespace.
    #[must_use]
    pub fn tool(&self) -> &str {
        &self.tool
    }
}

impl fmt::Display for DynamicToolKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(namespace) = &self.namespace {
            write!(formatter, "{namespace}.{}", self.tool)
        } else {
            formatter.write_str(&self.tool)
        }
    }
}

/// Owned, schema-validated call passed to a host handler.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DynamicToolCall {
    /// Owning thread.
    pub thread_id: ThreadId,
    /// Owning turn. This is required by the 0.148.0 call schema.
    pub turn_id: TurnId,
    /// App Server call identity.
    pub call_id: String,
    /// Optional namespace for namespaced declarations.
    pub namespace: Option<String>,
    /// Standalone or namespace-child function name.
    pub tool: String,
    /// Arguments already validated against the declaration's input schema.
    pub arguments: Value,
}

impl DynamicToolCall {
    /// Exact dispatch key for this call.
    #[must_use]
    pub fn key(&self) -> DynamicToolKey {
        DynamicToolKey::new(self.namespace.clone(), self.tool.clone())
    }
}

/// Owned handler failure. The registry never writes this message to App Server
/// automatically; the host retains control over user-visible error disclosure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{message}")]
pub struct DynamicToolHandlerError {
    message: String,
}

impl DynamicToolHandlerError {
    /// Construct an owned handler error.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Host-owned diagnostic message.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

/// Sendable future returned by a dynamic-tool handler.
pub type DynamicToolHandlerFuture<'a> =
    Pin<Box<dyn Future<Output = Result<DynamicToolResult, DynamicToolHandlerError>> + Send + 'a>>;

/// Asynchronous host implementation for one declaration.
///
/// A namespace registration uses the same handler for every child function;
/// inspect [`DynamicToolCall::tool`] to branch within the namespace.
pub trait DynamicToolHandler: Send + Sync {
    /// Execute one owned, schema-validated call.
    fn handle(&self, call: DynamicToolCall) -> DynamicToolHandlerFuture<'_>;
}

impl<F, Fut> DynamicToolHandler for F
where
    F: Fn(DynamicToolCall) -> Fut + Send + Sync,
    Fut: Future<Output = Result<DynamicToolResult, DynamicToolHandlerError>> + Send + 'static,
{
    fn handle(&self, call: DynamicToolCall) -> DynamicToolHandlerFuture<'_> {
        Box::pin(self(call))
    }
}

/// Shareable type-erased dynamic-tool handler.
pub type BoxedDynamicToolHandler = Arc<dyn DynamicToolHandler>;

/// Typed result accepted by the pinned dynamic-tool response schema.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DynamicToolResult {
    success: bool,
    content_items: Vec<DynamicToolContent>,
}

impl DynamicToolResult {
    /// Successful result with exact text/image/audio content variants.
    #[must_use]
    pub fn success(content_items: impl IntoIterator<Item = DynamicToolContent>) -> Self {
        Self {
            success: true,
            content_items: content_items.into_iter().collect(),
        }
    }

    /// Tool-level failure represented by the normal protocol result shape.
    #[must_use]
    pub fn failure(content_items: impl IntoIterator<Item = DynamicToolContent>) -> Self {
        Self {
            success: false,
            content_items: content_items.into_iter().collect(),
        }
    }

    /// Whether the tool reports success.
    #[must_use]
    pub const fn is_success(&self) -> bool {
        self.success
    }

    /// Exact ordered output content.
    #[must_use]
    pub fn content_items(&self) -> &[DynamicToolContent] {
        &self.content_items
    }

    /// Convert to the stable interaction reply consumed by the ordered client.
    #[must_use]
    pub fn into_reply(self) -> ServerRequestReply {
        ServerRequestReply::DynamicTool {
            success: self.success,
            content_items: self.content_items,
        }
    }

    fn validate(&self) -> Result<(), String> {
        let ServerRequestResolution::Result(value) = self.clone().into_reply().into_resolution()
        else {
            unreachable!("a typed dynamic-tool result always becomes a result resolution")
        };
        codex_app_server_types::validate_server_response(DYNAMIC_TOOL_METHOD, &value)
            .map_err(|error| error.to_string())
            .and_then(|known| {
                known
                    .then_some(())
                    .ok_or_else(|| "pinned schema does not recognize item/tool/call".to_owned())
            })
    }
}

#[derive(Clone)]
struct RegisteredDynamicTool {
    validator: Arc<jsonschema::Validator>,
    handler: BoxedDynamicToolHandler,
}

/// Deterministic declaration registry and typed request dispatcher.
///
/// Dispatch never resolves the ordered client's request itself. If its future
/// is cancelled, the actor inbox is therefore unchanged and the exact request
/// can be retried or resolved by host policy.
#[derive(Clone, Default)]
pub struct DynamicToolRegistry {
    declarations: BTreeMap<String, DynamicToolDeclaration>,
    tools: BTreeMap<DynamicToolKey, RegisteredDynamicTool>,
}

impl fmt::Debug for DynamicToolRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DynamicToolRegistry")
            .field("declarations", &self.declarations)
            .field("tool_keys", &self.tools.keys().collect::<Vec<_>>())
            .finish_non_exhaustive()
    }
}

impl DynamicToolRegistry {
    /// Create an empty registry.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            declarations: BTreeMap::new(),
            tools: BTreeMap::new(),
        }
    }

    /// Register a declaration with one async handler.
    ///
    /// Namespace declarations route all child functions to this handler.
    /// Registration is atomic: any duplicate or validation failure leaves the
    /// registry unchanged.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolRegistryError`] for duplicate names or generated
    /// declaration-schema drift.
    pub fn register<H>(
        &mut self,
        declaration: DynamicToolDeclaration,
        handler: H,
    ) -> Result<(), DynamicToolRegistryError>
    where
        H: DynamicToolHandler + 'static,
    {
        let handler: BoxedDynamicToolHandler = Arc::new(handler);
        self.register_boxed(declaration, &handler)
    }

    /// Register a declaration with an already type-erased handler.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolRegistryError`] for duplicate names or generated
    /// declaration-schema drift.
    pub fn register_boxed(
        &mut self,
        declaration: DynamicToolDeclaration,
        handler: &BoxedDynamicToolHandler,
    ) -> Result<(), DynamicToolRegistryError> {
        declaration
            .to_wire_value()
            .map_err(DynamicToolRegistryError::Declaration)?;
        if self.declarations.contains_key(declaration.name()) {
            return Err(DynamicToolRegistryError::DuplicateDeclaration {
                name: declaration.name().to_owned(),
            });
        }

        let entries = declaration
            .entries()
            .into_iter()
            .map(|(key, input_schema)| {
                let validator = compile_input_schema(input_schema.as_value())
                    .map_err(DynamicToolRegistryError::Declaration)?;
                Ok((key, Arc::new(validator)))
            })
            .collect::<Result<Vec<_>, DynamicToolRegistryError>>()?;
        if let Some((key, _)) = entries.iter().find(|(key, _)| self.tools.contains_key(key)) {
            return Err(DynamicToolRegistryError::DuplicateTool { key: key.clone() });
        }

        for (key, validator) in entries {
            self.tools.insert(
                key,
                RegisteredDynamicTool {
                    validator,
                    handler: Arc::clone(handler),
                },
            );
        }
        self.declarations
            .insert(declaration.name().to_owned(), declaration);
        Ok(())
    }

    /// Registered top-level declarations in deterministic name order.
    #[must_use]
    pub fn declarations(&self) -> Vec<DynamicToolDeclaration> {
        self.declarations.values().cloned().collect()
    }

    /// Number of exact callable namespace/tool keys.
    #[must_use]
    pub fn len(&self) -> usize {
        self.tools.len()
    }

    /// Whether no callable tool keys are registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }

    /// Dispatch one typed dynamic-tool server request.
    ///
    /// Arguments are validated before the handler runs, and the typed handler
    /// result is validated against the pinned generated response schema before
    /// it is returned. Dropping this future has no registry or client side
    /// effects; the caller remains responsible for resolving the exact request.
    ///
    /// # Errors
    ///
    /// Returns [`DynamicToolDispatchError`] for a different request family, an
    /// undeclared key, malformed typed scope, invalid arguments, handler
    /// failure, or response-schema drift.
    pub async fn dispatch(
        &self,
        request: &TypedServerRequest,
    ) -> Result<ServerRequestReply, DynamicToolDispatchError> {
        let ServerRequestBody::DynamicToolCall {
            scope,
            call_id,
            namespace,
            tool,
            arguments,
        } = &request.body
        else {
            return Err(DynamicToolDispatchError::NotDynamicToolRequest);
        };

        let key = DynamicToolKey::new(namespace.clone(), tool.clone());
        let registered = self
            .tools
            .get(&key)
            .ok_or_else(|| DynamicToolDispatchError::UndeclaredTool { key: key.clone() })?;
        registered
            .validator
            .validate(arguments)
            .map_err(|error| error.to_string())
            .map_err(|message| DynamicToolDispatchError::InvalidArguments {
                key: key.clone(),
                message,
            })?;

        let turn_id = scope
            .turn_id
            .clone()
            .ok_or(DynamicToolDispatchError::MissingTurnId)?;
        let call = DynamicToolCall {
            thread_id: scope.thread_id.clone(),
            turn_id,
            call_id: call_id.clone(),
            namespace: namespace.clone(),
            tool: tool.clone(),
            arguments: arguments.clone(),
        };
        let handler = Arc::clone(&registered.handler);
        let result =
            handler
                .handle(call)
                .await
                .map_err(|error| DynamicToolDispatchError::Handler {
                    key,
                    message: error.message,
                })?;
        result
            .validate()
            .map_err(|message| DynamicToolDispatchError::InvalidResult { message })?;
        Ok(result.into_reply())
    }
}

/// Registry construction failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DynamicToolRegistryError {
    /// A top-level function or namespace name is already registered.
    #[error("duplicate dynamic-tool declaration name: {name}")]
    DuplicateDeclaration { name: String },
    /// An exact dispatch key is already registered.
    #[error("duplicate dynamic-tool dispatch key: {key}")]
    DuplicateTool { key: DynamicToolKey },
    /// Declaration failed its own validation.
    #[error(transparent)]
    Declaration(DynamicToolDeclarationError),
}

/// Dynamic-tool dispatch failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DynamicToolDispatchError {
    /// Caller supplied another server-request family.
    #[error("typed server request is not a dynamic-tool call")]
    NotDynamicToolRequest,
    /// Typed interaction unexpectedly omitted the schema-required turn id.
    #[error("dynamic-tool call is missing its required turn id")]
    MissingTurnId,
    /// No declaration owns the exact namespace/tool pair.
    #[error("undeclared dynamic tool: {key}")]
    UndeclaredTool { key: DynamicToolKey },
    /// Arguments did not satisfy the registered input schema.
    #[error("arguments for dynamic tool {key} failed validation: {message}")]
    InvalidArguments {
        key: DynamicToolKey,
        message: String,
    },
    /// Host handler returned an owned failure.
    #[error("dynamic tool {key} failed: {message}")]
    Handler {
        key: DynamicToolKey,
        message: String,
    },
    /// Typed result failed the generated response schema.
    #[error("dynamic-tool result failed generated-schema validation: {message}")]
    InvalidResult { message: String },
}

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeMap,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use codex_app_server_client::{PendingServerRequest, ServerRequestKey};
    use codex_app_server_interaction::parse_request;
    use codex_app_server_wire::JsonRpcId;
    use serde_json::json;

    use super::*;

    fn schema(value: Value) -> DynamicToolInputSchema {
        DynamicToolInputSchema::new(value).expect("valid test schema")
    }

    fn function(name: &str) -> DynamicToolFunction {
        DynamicToolFunction::new(
            name,
            format!("Run {name}"),
            schema(json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"],
                "additionalProperties": false
            })),
        )
    }

    fn request(namespace: Option<&str>, tool: &str, arguments: Value) -> TypedServerRequest {
        let mut params = BTreeMap::from([
            ("threadId".to_owned(), json!("thread")),
            ("turnId".to_owned(), json!("turn")),
            ("callId".to_owned(), json!("call")),
            ("tool".to_owned(), json!(tool)),
            ("arguments".to_owned(), arguments),
        ]);
        if let Some(namespace) = namespace {
            params.insert("namespace".to_owned(), json!(namespace));
        }
        parse_request(&PendingServerRequest {
            key: ServerRequestKey {
                connection_epoch: 1,
                request_id: JsonRpcId::Integer(7),
            },
            method: DYNAMIC_TOOL_METHOD.to_owned(),
            params,
        })
        .expect("valid typed dynamic-tool request")
    }

    #[test]
    fn input_schema_rejects_invalid_json_schema() {
        assert!(matches!(
            DynamicToolInputSchema::new(json!({ "type": "not-a-json-type" })),
            Err(DynamicToolDeclarationError::InvalidInputSchema { .. })
        ));
    }

    #[test]
    fn input_schema_cannot_resolve_network_or_file_references() {
        for reference in [
            "https://example.invalid/dynamic-tool-schema.json",
            "file:///private/tmp/codexcore-dynamic-tool-schema.json",
        ] {
            assert!(matches!(
                DynamicToolInputSchema::new(json!({ "$ref": reference })),
                Err(DynamicToolDeclarationError::InvalidInputSchema { .. })
            ));
        }
    }

    #[test]
    fn declarations_encode_only_pinned_function_and_namespace_fields() {
        let standalone = DynamicToolDeclaration::from(function("lookup").with_defer_loading(true));
        assert_eq!(
            standalone.to_wire_value().expect("standalone declaration"),
            json!({
                "type": "function",
                "name": "lookup",
                "description": "Run lookup",
                "inputSchema": {
                    "type": "object",
                    "properties": { "id": { "type": "string" } },
                    "required": ["id"],
                    "additionalProperties": false
                },
                "deferLoading": true
            })
        );

        let namespace = DynamicToolDeclaration::from(
            DynamicToolNamespace::new("records", "Record operations", vec![function("read")])
                .expect("namespace"),
        );
        assert_eq!(
            namespace.to_wire_value().expect("namespace declaration"),
            json!({
                "type": "namespace",
                "name": "records",
                "description": "Record operations",
                "tools": [{
                    "type": "function",
                    "name": "read",
                    "description": "Run read",
                    "inputSchema": {
                        "type": "object",
                        "properties": { "id": { "type": "string" } },
                        "required": ["id"],
                        "additionalProperties": false
                    }
                }]
            })
        );
    }

    #[test]
    fn duplicate_names_are_rejected_without_partial_registration() {
        let duplicate_namespace = DynamicToolNamespace::new(
            "records",
            "Records",
            vec![function("read"), function("read")],
        );
        assert!(matches!(
            duplicate_namespace,
            Err(DynamicToolDeclarationError::DuplicateNamespaceTool { .. })
        ));

        let mut registry = DynamicToolRegistry::new();
        registry
            .register(
                DynamicToolDeclaration::from(function("lookup")),
                |_| async { Ok(DynamicToolResult::success([])) },
            )
            .expect("first registration");
        assert!(matches!(
            registry.register(
                DynamicToolDeclaration::from(function("lookup")),
                |_| async { Ok(DynamicToolResult::success([])) },
            ),
            Err(DynamicToolRegistryError::DuplicateDeclaration { .. })
        ));
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.declarations().len(), 1);
    }

    #[test]
    fn declarations_are_returned_in_deterministic_name_order() {
        let mut registry = DynamicToolRegistry::new();
        for name in ["zeta", "alpha"] {
            registry
                .register(DynamicToolDeclaration::from(function(name)), |_| async {
                    Ok(DynamicToolResult::success([]))
                })
                .expect("registration");
        }

        assert_eq!(
            registry
                .declarations()
                .iter()
                .map(DynamicToolDeclaration::name)
                .collect::<Vec<_>>(),
            ["alpha", "zeta"]
        );
    }

    #[test]
    fn registry_is_send_and_sync() {
        const fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<DynamicToolRegistry>();
        assert_send_sync::<BoxedDynamicToolHandler>();
    }

    #[tokio::test]
    async fn dispatch_matches_exact_key_and_validates_before_handler() {
        let calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = Arc::clone(&calls);
        let namespace =
            DynamicToolNamespace::new("records", "Record operations", vec![function("read")])
                .expect("namespace");
        let mut registry = DynamicToolRegistry::new();
        registry
            .register(
                DynamicToolDeclaration::from(namespace),
                move |call: DynamicToolCall| {
                    observed_calls.fetch_add(1, Ordering::SeqCst);
                    async move {
                        assert_eq!(
                            call.key(),
                            DynamicToolKey::new(Some("records".into()), "read")
                        );
                        Ok(DynamicToolResult::success([DynamicToolContent::Text(
                            call.arguments["id"].as_str().expect("id").to_owned(),
                        )]))
                    }
                },
            )
            .expect("registration");

        let invalid = registry
            .dispatch(&request(Some("records"), "read", json!({ "id": 4 })))
            .await;
        assert!(matches!(
            invalid,
            Err(DynamicToolDispatchError::InvalidArguments { .. })
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let reply = registry
            .dispatch(&request(
                Some("records"),
                "read",
                json!({ "id": "record-7" }),
            ))
            .await
            .expect("dispatch");
        let ServerRequestResolution::Result(value) = reply.into_resolution() else {
            panic!("typed reply must be a result");
        };
        assert_eq!(
            value,
            json!({
                "success": true,
                "contentItems": [{"type": "inputText", "text": "record-7"}]
            })
        );
        assert!(
            codex_app_server_types::validate_server_response(DYNAMIC_TOOL_METHOD, &value)
                .expect("generated response validation")
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn exact_namespace_is_required() {
        let namespace =
            DynamicToolNamespace::new("records", "Record operations", vec![function("read")])
                .expect("namespace");
        let mut registry = DynamicToolRegistry::new();
        registry
            .register(DynamicToolDeclaration::from(namespace), |_| async {
                Ok(DynamicToolResult::success([]))
            })
            .expect("registration");

        assert!(matches!(
            registry
                .dispatch(&request(None, "read", json!({ "id": "x" })))
                .await,
            Err(DynamicToolDispatchError::UndeclaredTool { .. })
        ));
    }

    #[tokio::test]
    async fn cancelled_dispatch_does_not_consume_registration() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let observed_attempts = Arc::clone(&attempts);
        let mut registry = DynamicToolRegistry::new();
        registry
            .register(
                DynamicToolDeclaration::from(function("lookup")),
                move |_| {
                    let attempt = observed_attempts.fetch_add(1, Ordering::SeqCst);
                    async move {
                        if attempt == 0 {
                            std::future::pending().await
                        } else {
                            Ok(DynamicToolResult::success([]))
                        }
                    }
                },
            )
            .expect("registration");
        let typed = request(None, "lookup", json!({ "id": "x" }));

        assert!(
            tokio::time::timeout(Duration::from_millis(10), registry.dispatch(&typed))
                .await
                .is_err()
        );
        assert_eq!(registry.len(), 1);
        assert!(registry.dispatch(&typed).await.is_ok());
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }
}
