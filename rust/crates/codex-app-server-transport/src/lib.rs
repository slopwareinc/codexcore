//! Bounded, ordered transport primitives for Codex App Server connections.
//!
//! Transports perform one write attempt and never retain or replay frames
//! across physical connections. Session-level retry policy belongs above this
//! crate.

use bytes::{Bytes, BytesMut};
use thiserror::Error;

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
}
