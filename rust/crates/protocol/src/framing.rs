//! Frame format (ADR 0004): `u32 BE length | JSON payload | u32 BE CRC-32 of payload`.

use thiserror::Error;

use crate::Message;

/// Largest payload accepted. Anything bigger closes the connection.
pub const MAX_PAYLOAD_LEN: usize = 1 << 20;

const HEADER_LEN: usize = 4;
const TRAILER_LEN: usize = 4;

#[derive(Debug, Error)]
pub enum FrameError {
    #[error("payload of {0} bytes exceeds the {MAX_PAYLOAD_LEN}-byte limit")]
    TooLarge(usize),
    #[error("CRC mismatch: frame says {expected:#010x}, payload is {actual:#010x}")]
    BadCrc { expected: u32, actual: u32 },
    #[error("invalid JSON message: {0}")]
    Json(#[from] serde_json::Error),
}

/// Serializes a message into a complete frame.
pub fn encode(message: &Message) -> Result<Vec<u8>, FrameError> {
    let payload = serde_json::to_vec(message)?;
    encode_payload(&payload)
}

/// Wraps an already-serialized payload in a frame.
pub fn encode_payload(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    if payload.len() > MAX_PAYLOAD_LEN {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let mut frame = Vec::with_capacity(HEADER_LEN + payload.len() + TRAILER_LEN);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    frame.extend_from_slice(&crc32fast::hash(payload).to_be_bytes());
    Ok(frame)
}

/// Incremental decoder for a byte stream. Feed bytes as they arrive and pull
/// complete payloads out. Any error means the stream is unusable and the
/// connection should be closed.
#[derive(Debug, Default)]
pub struct Decoder {
    buffer: Vec<u8>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// Returns the next complete, CRC-checked payload, or `None` if more bytes are needed.
    pub fn next_payload(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        if self.buffer.len() < HEADER_LEN {
            return Ok(None);
        }
        let len =
            u32::from_be_bytes(self.buffer[..HEADER_LEN].try_into().expect("4 bytes")) as usize;
        if len > MAX_PAYLOAD_LEN {
            return Err(FrameError::TooLarge(len));
        }
        let total = HEADER_LEN + len + TRAILER_LEN;
        if self.buffer.len() < total {
            return Ok(None);
        }
        let payload = self.buffer[HEADER_LEN..HEADER_LEN + len].to_vec();
        let expected = u32::from_be_bytes(
            self.buffer[HEADER_LEN + len..total]
                .try_into()
                .expect("4 bytes"),
        );
        let actual = crc32fast::hash(&payload);
        if expected != actual {
            return Err(FrameError::BadCrc { expected, actual });
        }
        self.buffer.drain(..total);
        Ok(Some(payload))
    }

    /// Returns the next complete message, or `None` if more bytes are needed.
    pub fn next_message(&mut self) -> Result<Option<Message>, FrameError> {
        match self.next_payload()? {
            Some(payload) => Ok(Some(serde_json::from_slice(&payload)?)),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Bye, ByeReason, PROTOCOL_VERSION};

    fn bye() -> Message {
        Message::Bye(Bye {
            protocol_version: PROTOCOL_VERSION,
            session_id: "11111111-1111-4111-8111-111111111111".into(),
            device_id: "22222222-2222-4222-8222-222222222222".into(),
            last_seq: Some(7),
            reason: ByeReason::OperatorStop,
        })
    }

    #[test]
    fn crc_matches_the_zlib_check_value() {
        // CRC-32/ISO-HDLC check value; the Swift implementation tests the same.
        assert_eq!(crc32fast::hash(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn round_trips_across_arbitrary_chunk_boundaries() {
        let mut stream = encode(&bye()).unwrap();
        stream.extend(encode(&bye()).unwrap());
        for chunk in 1..=stream.len() {
            let mut decoder = Decoder::new();
            let mut out = Vec::new();
            for piece in stream.chunks(chunk) {
                decoder.push(piece);
                while let Some(m) = decoder.next_message().unwrap() {
                    out.push(m);
                }
            }
            assert_eq!(out, vec![bye(), bye()], "chunk size {chunk}");
        }
    }

    #[test]
    fn rejects_corrupted_payload() {
        let mut frame = encode(&bye()).unwrap();
        frame[HEADER_LEN + 3] ^= 0x01;
        let mut decoder = Decoder::new();
        decoder.push(&frame);
        assert!(matches!(
            decoder.next_payload(),
            Err(FrameError::BadCrc { .. })
        ));
    }

    #[test]
    fn rejects_oversized_length_before_buffering_it() {
        let mut decoder = Decoder::new();
        decoder.push(&((MAX_PAYLOAD_LEN as u32) + 1).to_be_bytes());
        assert!(matches!(
            decoder.next_payload(),
            Err(FrameError::TooLarge(_))
        ));
    }
}
