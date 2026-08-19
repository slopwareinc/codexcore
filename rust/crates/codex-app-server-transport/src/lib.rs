//! Bounded, ordered transport primitives for Codex App Server connections.
//!
//! Transports perform one write attempt and never retain or replay frames
//! across physical connections. Session-level retry policy belongs above this
//! crate.

use std::{
    collections::BTreeMap,
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex},
    time::Duration,
};

use bytes::{Bytes, BytesMut};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, Command},
    sync::mpsc,
    task::JoinHandle,
};

/// Resource limits applied at the physical transport boundary.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TransportLimits {
    /// Maximum size of one complete inbound frame.
    pub maximum_inbound_frame_bytes: usize,
    /// Maximum number of complete frames awaiting session ingress.
    pub maximum_buffered_inbound_frames: usize,
    /// Maximum retained subprocess stderr tail.
    pub maximum_captured_stderr_bytes: usize,
}

impl Default for TransportLimits {
    fn default() -> Self {
        Self {
            maximum_inbound_frame_bytes: 64 * 1_024 * 1_024,
            maximum_buffered_inbound_frames: 4_096,
            maximum_captured_stderr_bytes: 16 * 1_024,
        }
    }
}

impl TransportLimits {
    /// Validate custom limits before constructing a transport.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError::InvalidLimit`] when any limit is zero.
    pub fn validate(self) -> Result<Self, TransportError> {
        if self.maximum_inbound_frame_bytes == 0 {
            return Err(TransportError::InvalidLimit("maximum_inbound_frame_bytes"));
        }
        if self.maximum_buffered_inbound_frames == 0 {
            return Err(TransportError::InvalidLimit(
                "maximum_buffered_inbound_frames",
            ));
        }
        if self.maximum_captured_stderr_bytes == 0 {
            return Err(TransportError::InvalidLimit(
                "maximum_captured_stderr_bytes",
            ));
        }
        Ok(self)
    }
}

/// Physical transport or framing failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum TransportError {
    /// A configured resource limit is zero.
    #[error("transport limit {0} must be positive")]
    InvalidLimit(&'static str),
    /// An inbound frame exceeded the configured maximum.
    #[error("inbound frame exceeded {maximum_bytes} bytes (observed at least {observed_bytes})")]
    FrameTooLarge {
        /// Configured maximum.
        maximum_bytes: usize,
        /// Observed lower bound when rejection occurred.
        observed_bytes: usize,
    },
    /// Subprocess could not be launched or did not expose its configured pipe.
    #[error("failed to launch App Server transport: {0}")]
    LaunchFailed(String),
    /// A physical transport I/O operation failed.
    #[error("App Server transport I/O failed: {0}")]
    Io(String),
    /// Physical connection ended after all preceding frames were delivered.
    #[error("App Server transport connection closed{suffix}", suffix = stderr_suffix(.stderr.as_deref()))]
    ConnectionClosed {
        /// Bounded subprocess stderr tail, when present.
        stderr: Option<String>,
    },
}

fn stderr_suffix(stderr: Option<&str>) -> String {
    stderr.map_or_else(String::new, |stderr| format!("; stderr tail: {stderr}"))
}

/// Oversized-line failure that preserves already accepted prefix frames.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{error}")]
pub struct LineDecodeFailure {
    /// Complete frames accepted before the terminal framing error.
    pub accepted_frames: Vec<Bytes>,
    /// Terminal framing error.
    pub error: TransportError,
}

/// Incremental decoder for stdio JSONL frames.
#[derive(Debug)]
pub struct LineDecoder {
    maximum_line_bytes: usize,
    buffer: BytesMut,
}

impl LineDecoder {
    /// Create a decoder with the given per-frame byte limit.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError::InvalidLimit`] when the limit is zero.
    pub fn new(maximum_line_bytes: usize) -> Result<Self, TransportError> {
        if maximum_line_bytes == 0 {
            return Err(TransportError::InvalidLimit("maximum_line_bytes"));
        }
        Ok(Self {
            maximum_line_bytes,
            buffer: BytesMut::new(),
        })
    }

    /// Number of bytes retained for an incomplete trailing frame.
    #[must_use]
    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len()
    }

    /// Append bytes and return every newly completed frame in wire order.
    ///
    /// If a later line in the same chunk is oversized, the returned failure
    /// still contains every valid prefix frame so callers can deliver them
    /// before sealing the connection.
    ///
    /// # Errors
    ///
    /// Returns [`LineDecodeFailure`] when a complete or buffered line exceeds
    /// the configured maximum. The decoder resets after that terminal error.
    pub fn feed(&mut self, chunk: &[u8]) -> Result<Vec<Bytes>, LineDecodeFailure> {
        self.buffer.extend_from_slice(chunk);
        let mut accepted_frames = Vec::new();

        while let Some(newline_index) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let mut line = self.buffer.split_to(newline_index + 1);
            line.truncate(newline_index);
            if line.len() > self.maximum_line_bytes {
                self.buffer.clear();
                return Err(LineDecodeFailure {
                    accepted_frames,
                    error: TransportError::FrameTooLarge {
                        maximum_bytes: self.maximum_line_bytes,
                        observed_bytes: line.len(),
                    },
                });
            }
            accepted_frames.push(line.freeze());
        }

        if self.buffer.len() > self.maximum_line_bytes {
            let observed_bytes = self.buffer.len();
            self.buffer.clear();
            return Err(LineDecodeFailure {
                accepted_frames,
                error: TransportError::FrameTooLarge {
                    maximum_bytes: self.maximum_line_bytes,
                    observed_bytes,
                },
            });
        }

        Ok(accepted_frames)
    }
}

/// Configuration for one local App Server subprocess connection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StdioConfig {
    /// Codex executable to launch.
    pub executable: PathBuf,
    /// Arguments following the executable. Defaults should include
    /// `app-server --listen stdio://`.
    pub arguments: Vec<String>,
    /// Explicit environment additions or overrides.
    pub environment: BTreeMap<String, String>,
    /// Optional working directory for the child process.
    pub current_directory: Option<PathBuf>,
}

impl StdioConfig {
    /// Build the standard local App Server launch configuration.
    #[must_use]
    pub fn app_server(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            arguments: vec![
                "app-server".to_owned(),
                "--listen".to_owned(),
                "stdio://".to_owned(),
            ],
            environment: BTreeMap::new(),
            current_directory: None,
        }
    }
}

/// One physical, ordered subprocess connection.
///
/// The session engine owns this value. Dropping it kills the child as a final
/// safety net; callers should use [`Self::close`] for deterministic reaping.
pub struct StdioConnection {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: mpsc::Receiver<Result<Bytes, TransportError>>,
    reader_task: JoinHandle<()>,
    stderr_task: JoinHandle<()>,
}

impl StdioConnection {
    /// Launch a new App Server subprocess and start bounded pipe drains.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError`] when limits are invalid, the process cannot
    /// be launched, or a required stdio pipe is unavailable.
    pub fn spawn(config: &StdioConfig, limits: TransportLimits) -> Result<Self, TransportError> {
        let limits = limits.validate()?;
        let mut command = Command::new(&config.executable);
        command
            .args(&config.arguments)
            .envs(&config.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(current_directory) = &config.current_directory {
            command.current_dir(current_directory);
        }

        let mut child = command
            .spawn()
            .map_err(|error| TransportError::LaunchFailed(error.to_string()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| TransportError::LaunchFailed("stdin pipe unavailable".to_owned()))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| TransportError::LaunchFailed("stdout pipe unavailable".to_owned()))?;
        let mut stderr = child
            .stderr
            .take()
            .ok_or_else(|| TransportError::LaunchFailed("stderr pipe unavailable".to_owned()))?;

        let stderr_tail = Arc::new(Mutex::new(StderrTail::new(
            limits.maximum_captured_stderr_bytes,
        )));
        let stderr_tail_for_drain = Arc::clone(&stderr_tail);
        let stderr_task = tokio::spawn(async move {
            let mut chunk = vec![0_u8; 16 * 1_024];
            loop {
                match stderr.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(count) => stderr_tail_for_drain
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .append(&chunk[..count]),
                }
            }
        });

        let (sender, frames) = mpsc::channel(limits.maximum_buffered_inbound_frames);
        let mut decoder = LineDecoder::new(limits.maximum_inbound_frame_bytes)?;
        let reader_task = tokio::spawn(async move {
            let mut chunk = vec![0_u8; 64 * 1_024];
            loop {
                match stdout.read(&mut chunk).await {
                    Ok(0) => {
                        let tail = stderr_tail
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .snapshot();
                        let _ = sender
                            .send(Err(TransportError::ConnectionClosed { stderr: tail }))
                            .await;
                        break;
                    }
                    Ok(count) => match decoder.feed(&chunk[..count]) {
                        Ok(accepted) => {
                            if !send_frames(&sender, accepted).await {
                                break;
                            }
                        }
                        Err(failure) => {
                            if send_frames(&sender, failure.accepted_frames).await {
                                let _ = sender.send(Err(failure.error)).await;
                            }
                            break;
                        }
                    },
                    Err(error) => {
                        let _ = sender
                            .send(Err(TransportError::Io(error.to_string())))
                            .await;
                        break;
                    }
                }
            }
        });

        Ok(Self {
            child,
            stdin: Some(stdin),
            frames,
            reader_task,
            stderr_task,
        })
    }

    /// Perform exactly one newline-delimited write attempt.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError::ConnectionClosed`] when the write half has
    /// already closed, or [`TransportError::Io`] when writing/flushing fails.
    pub async fn write(&mut self, frame: &[u8]) -> Result<(), TransportError> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or(TransportError::ConnectionClosed { stderr: None })?;
        stdin
            .write_all(frame)
            .await
            .map_err(|error| TransportError::Io(error.to_string()))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|error| TransportError::Io(error.to_string()))?;
        stdin
            .flush()
            .await
            .map_err(|error| TransportError::Io(error.to_string()))
    }

    /// Receive the next complete frame or terminal physical error.
    pub async fn next_frame(&mut self) -> Option<Result<Bytes, TransportError>> {
        self.frames.recv().await
    }

    /// Close the write half, terminate the subprocess, and reap it.
    ///
    /// # Errors
    ///
    /// Returns [`TransportError::Io`] if the child cannot be killed or reaped.
    pub async fn close(mut self) -> Result<(), TransportError> {
        self.stdin.take();
        if self
            .child
            .try_wait()
            .map_err(|error| TransportError::Io(error.to_string()))?
            .is_none()
        {
            self.child
                .start_kill()
                .map_err(|error| TransportError::Io(error.to_string()))?;
        }
        tokio::time::timeout(Duration::from_secs(5), self.child.wait())
            .await
            .map_err(|_| TransportError::Io("timed out reaping App Server child".to_owned()))?
            .map_err(|error| TransportError::Io(error.to_string()))?;
        self.reader_task.abort();
        self.stderr_task.abort();
        Ok(())
    }
}

async fn send_frames(
    sender: &mpsc::Sender<Result<Bytes, TransportError>>,
    frames: Vec<Bytes>,
) -> bool {
    for frame in frames {
        if sender.send(Ok(frame)).await.is_err() {
            return false;
        }
    }
    true
}

#[derive(Debug)]
struct StderrTail {
    maximum_bytes: usize,
    bytes: Vec<u8>,
}

impl StderrTail {
    fn new(maximum_bytes: usize) -> Self {
        Self {
            maximum_bytes,
            bytes: Vec::with_capacity(maximum_bytes),
        }
    }

    fn append(&mut self, chunk: &[u8]) {
        if chunk.len() >= self.maximum_bytes {
            self.bytes.clear();
            self.bytes
                .extend_from_slice(&chunk[chunk.len() - self.maximum_bytes..]);
            return;
        }
        self.bytes.extend_from_slice(chunk);
        if self.bytes.len() > self.maximum_bytes {
            self.bytes.drain(..self.bytes.len() - self.maximum_bytes);
        }
    }

    fn snapshot(&self) -> Option<String> {
        let value = String::from_utf8_lossy(&self.bytes).trim().to_owned();
        (!value.is_empty()).then_some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_split_and_batched_lines_in_order() {
        let mut decoder = LineDecoder::new(64).expect("valid decoder");
        assert!(
            decoder
                .feed(b"{\"id\":1")
                .expect("prefix accepted")
                .is_empty()
        );
        assert_eq!(decoder.buffered_bytes(), 7);
        let frames = decoder.feed(b"}\n{\"id\":2}\n").expect("lines accepted");
        assert_eq!(
            frames,
            [
                Bytes::from_static(br#"{"id":1}"#),
                Bytes::from_static(br#"{"id":2}"#)
            ]
        );
        assert_eq!(decoder.buffered_bytes(), 0);
    }

    #[test]
    fn reports_oversized_unterminated_line_and_resets() {
        let mut decoder = LineDecoder::new(4).expect("valid decoder");
        let failure = decoder.feed(b"12345").expect_err("line must be rejected");
        assert!(failure.accepted_frames.is_empty());
        assert_eq!(
            failure.error,
            TransportError::FrameTooLarge {
                maximum_bytes: 4,
                observed_bytes: 5,
            }
        );
        assert_eq!(decoder.buffered_bytes(), 0);
        assert_eq!(
            decoder.feed(b"ok\n").expect("decoder reusable"),
            [Bytes::from_static(b"ok")]
        );
    }

    #[test]
    fn preserves_valid_prefix_before_later_oversized_line() {
        let mut decoder = LineDecoder::new(4).expect("valid decoder");
        let failure = decoder
            .feed(b"ok\n12345\n")
            .expect_err("second line must be rejected");
        assert_eq!(failure.accepted_frames, [Bytes::from_static(b"ok")]);
        assert_eq!(
            failure.error,
            TransportError::FrameTooLarge {
                maximum_bytes: 4,
                observed_bytes: 5,
            }
        );
    }

    #[test]
    fn custom_limits_must_be_positive() {
        let invalid = TransportLimits {
            maximum_inbound_frame_bytes: 0,
            ..TransportLimits::default()
        };
        assert_eq!(
            invalid.validate(),
            Err(TransportError::InvalidLimit("maximum_inbound_frame_bytes"))
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stdio_connection_writes_and_reads_one_frame() {
        let config = StdioConfig {
            executable: PathBuf::from("/bin/sh"),
            arguments: vec![
                "-c".to_owned(),
                "IFS= read -r line; printf '%s\\n' \"$line\"".to_owned(),
            ],
            environment: BTreeMap::new(),
            current_directory: None,
        };
        let mut connection =
            StdioConnection::spawn(&config, TransportLimits::default()).expect("spawn shell");
        connection
            .write(br#"{"method":"initialized","params":{}}"#)
            .await
            .expect("write frame");
        let frame = connection
            .next_frame()
            .await
            .expect("reader remains open")
            .expect("valid frame");
        assert_eq!(
            frame,
            Bytes::from_static(br#"{"method":"initialized","params":{}}"#)
        );
        connection.close().await.expect("close and reap");
    }
}
