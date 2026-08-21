use std::{fmt, path::PathBuf};

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
#[cfg(unix)]
use tokio::net::UnixStream;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, client_async_with_config, connect_async_with_config,
    tungstenite::{
        Message,
        client::IntoClientRequest,
        http::{HeaderValue, header::AUTHORIZATION},
        protocol::WebSocketConfig,
    },
};

use crate::{TransportError, TransportLimits};

/// TCP/TLS WebSocket configuration. Debug output redacts the credential.
#[derive(Clone, Eq, PartialEq)]
pub struct WebSocketConnectConfig {
    pub url: String,
    pub bearer_token: Option<String>,
    pub limits: TransportLimits,
}

impl fmt::Debug for WebSocketConnectConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WebSocketConnectConfig")
            .field("url", &self.url)
            .field(
                "bearer_token",
                &self.bearer_token.as_ref().map(|_| "<redacted>"),
            )
            .field("limits", &self.limits)
            .finish()
    }
}

/// WebSocket-over-Unix-socket configuration.
#[cfg(unix)]
#[derive(Clone, Eq, PartialEq)]
pub struct UnixWebSocketConnectConfig {
    pub socket_path: PathBuf,
    pub request_url: String,
    pub bearer_token: Option<String>,
    pub limits: TransportLimits,
}

#[cfg(unix)]
impl fmt::Debug for UnixWebSocketConnectConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UnixWebSocketConnectConfig")
            .field("socket_path", &self.socket_path)
            .field("request_url", &self.request_url)
            .field(
                "bearer_token",
                &self.bearer_token.as_ref().map(|_| "<redacted>"),
            )
            .field("limits", &self.limits)
            .finish()
    }
}

/// One physical WebSocket connection over an async byte stream.
pub struct WebSocketConnection<S> {
    stream: WebSocketStream<S>,
    maximum_frame_bytes: usize,
}

/// TCP/TLS WebSocket connection type.
pub type TcpWebSocketConnection = WebSocketConnection<MaybeTlsStream<TcpStream>>;

/// Unix-socket WebSocket connection type.
#[cfg(unix)]
pub type UnixWebSocketConnection = WebSocketConnection<UnixStream>;

/// Connect to a `ws://` or `wss://` App Server endpoint.
///
/// # Errors
///
/// Returns [`TransportError`] for invalid configuration, upgrade, TLS, or I/O failure.
pub async fn connect_websocket(
    config: &WebSocketConnectConfig,
) -> Result<WebSocketConnection<MaybeTlsStream<TcpStream>>, TransportError> {
    let limits = config.limits.validate()?;
    let request = request(&config.url, config.bearer_token.as_deref())?;
    let (stream, _) = connect_async_with_config(
        request,
        Some(socket_config(limits.maximum_inbound_frame_bytes)),
        false,
    )
    .await
    .map_err(|error| ws_error(&error))?;
    Ok(WebSocketConnection {
        stream,
        maximum_frame_bytes: limits.maximum_inbound_frame_bytes,
    })
}

/// Connect through App Server's WebSocket-over-Unix-socket endpoint.
///
/// # Errors
///
/// Returns [`TransportError`] for socket, upgrade, or I/O failure.
#[cfg(unix)]
pub async fn connect_unix_websocket(
    config: &UnixWebSocketConnectConfig,
) -> Result<WebSocketConnection<UnixStream>, TransportError> {
    let limits = config.limits.validate()?;
    let stream = UnixStream::connect(&config.socket_path)
        .await
        .map_err(|error| TransportError::Io(error.to_string()))?;
    let request = request(&config.request_url, config.bearer_token.as_deref())?;
    let (stream, _) = client_async_with_config(
        request,
        stream,
        Some(socket_config(limits.maximum_inbound_frame_bytes)),
    )
    .await
    .map_err(|error| ws_error(&error))?;
    Ok(WebSocketConnection {
        stream,
        maximum_frame_bytes: limits.maximum_inbound_frame_bytes,
    })
}

impl<S> WebSocketConnection<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    /// Perform exactly one text-frame write attempt.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError`] for non-UTF-8 data or WebSocket I/O failure.
    pub async fn write(&mut self, frame: &[u8]) -> Result<(), TransportError> {
        let text = std::str::from_utf8(frame)
            .map_err(|error| TransportError::Io(format!("outbound frame is not UTF-8: {error}")))?;
        self.stream
            .send(Message::Text(text.to_owned().into()))
            .await
            .map_err(|error| ws_error(&error))
    }

    /// Receive the next App Server text frame, answering ping frames inline.
    pub async fn next_frame(&mut self) -> Option<Result<Bytes, TransportError>> {
        loop {
            match self.stream.next().await? {
                Ok(Message::Text(text)) => {
                    if text.len() > self.maximum_frame_bytes {
                        return Some(Err(TransportError::FrameTooLarge {
                            maximum_bytes: self.maximum_frame_bytes,
                            observed_bytes: text.len(),
                        }));
                    }
                    return Some(Ok(Bytes::copy_from_slice(text.as_bytes())));
                }
                Ok(Message::Ping(payload)) => {
                    if let Err(error) = self.stream.send(Message::Pong(payload)).await {
                        return Some(Err(ws_error(&error)));
                    }
                }
                Ok(Message::Pong(_) | Message::Frame(_)) => {}
                Ok(Message::Close(_)) => {
                    return Some(Err(TransportError::ConnectionClosed { stderr: None }));
                }
                Ok(Message::Binary(payload)) => {
                    return Some(Err(TransportError::Io(format!(
                        "App Server WebSocket sent binary frame ({} bytes)",
                        payload.len()
                    ))));
                }
                Err(error) => return Some(Err(ws_error(&error))),
            }
        }
    }

    /// Send a normal close frame.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError`] when the close write fails.
    pub async fn close(mut self) -> Result<(), TransportError> {
        self.stream
            .close(None)
            .await
            .map_err(|error| ws_error(&error))
    }
}

fn request(
    url: &str,
    bearer: Option<&str>,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>, TransportError> {
    let mut request = url
        .into_client_request()
        .map_err(|error| ws_error(&error))?;
    if let Some(token) = bearer {
        let value = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|error| TransportError::Io(format!("invalid bearer credential: {error}")))?;
        request.headers_mut().insert(AUTHORIZATION, value);
    }
    Ok(request)
}

fn socket_config(maximum: usize) -> WebSocketConfig {
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(maximum);
    config.max_frame_size = Some(maximum);
    config
}

fn ws_error(error: &tokio_tungstenite::tungstenite::Error) -> TransportError {
    TransportError::Io(format!("WebSocket: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;

    #[tokio::test]
    async fn tcp_round_trip() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut socket = accept_async(stream).await.expect("upgrade");
            let message = socket.next().await.expect("message").expect("valid");
            socket.send(message).await.expect("echo");
            let _ = socket.next().await;
        });
        let mut client = connect_websocket(&WebSocketConnectConfig {
            url: format!("ws://{address}"),
            bearer_token: None,
            limits: TransportLimits::default(),
        })
        .await
        .expect("connect");
        client.write(br#"{"id":1}"#).await.expect("write");
        assert_eq!(
            client.next_frame().await.expect("frame").expect("valid"),
            Bytes::from_static(br#"{"id":1}"#)
        );
        client.close().await.expect("close");
        server.await.expect("server");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_round_trip() {
        use tokio::net::UnixListener;
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("app-server.sock");
        let listener = UnixListener::bind(&path).expect("bind");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut socket = accept_async(stream).await.expect("upgrade");
            let message = socket.next().await.expect("message").expect("valid");
            socket.send(message).await.expect("echo");
            let _ = socket.next().await;
        });
        let mut client = connect_unix_websocket(&UnixWebSocketConnectConfig {
            socket_path: path,
            request_url: "ws://localhost/".to_owned(),
            bearer_token: None,
            limits: TransportLimits::default(),
        })
        .await
        .expect("connect");
        client.write(br#"{"id":2}"#).await.expect("write");
        assert_eq!(
            client.next_frame().await.expect("frame").expect("valid"),
            Bytes::from_static(br#"{"id":2}"#)
        );
        client.close().await.expect("close");
        server.await.expect("server");
    }
}
