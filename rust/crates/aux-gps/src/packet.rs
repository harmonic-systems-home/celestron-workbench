//! AUX packets: `0x3B`, length, source, destination, message ID, data,
//! checksum. The length counts source, destination, ID and data; the
//! checksum is the two's complement of the sum from the length on
//! (docs/references.md, ADR 0018).

pub const PREAMBLE: u8 = 0x3B;
/// Longest length byte accepted; longer is treated as noise (as the
/// AUX Listener does).
pub const MAX_LENGTH: usize = 40;

pub fn checksum(body: &[u8]) -> u8 {
    body.iter()
        .fold(0u8, |sum, b| sum.wrapping_add(*b))
        .wrapping_neg()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub src: u8,
    pub dst: u8,
    pub id: u8,
    pub data: Vec<u8>,
}

impl Packet {
    pub fn encode(&self) -> Vec<u8> {
        let mut body = vec![(3 + self.data.len()) as u8, self.src, self.dst, self.id];
        body.extend_from_slice(&self.data);
        let sum = checksum(&body);
        let mut bytes = vec![PREAMBLE];
        bytes.extend(body);
        bytes.push(sum);
        bytes
    }

    pub fn hex(&self) -> String {
        hex(&self.encode())
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Frames packets out of a byte stream that may split or join them, and
/// drops bytes that don't make a valid packet.
#[derive(Default)]
pub struct Framer {
    buf: Vec<u8>,
}

impl Framer {
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Packet> {
        self.buf.extend_from_slice(bytes);
        let mut out = Vec::new();
        loop {
            match self.buf.iter().position(|&b| b == PREAMBLE) {
                None => {
                    self.buf.clear();
                    break;
                }
                Some(i) => {
                    self.buf.drain(..i);
                }
            }
            if self.buf.len() < 2 {
                break;
            }
            let len = self.buf[1] as usize;
            if !(3..=MAX_LENGTH).contains(&len) {
                self.buf.remove(0);
                continue;
            }
            let total = len + 3;
            if self.buf.len() < total {
                break;
            }
            let body = &self.buf[1..total - 1];
            if checksum(body) == self.buf[total - 1] {
                out.push(Packet {
                    src: body[1],
                    dst: body[2],
                    id: body[3],
                    data: body[4..].to_vec(),
                });
                self.buf.drain(..total);
            } else {
                self.buf.remove(0);
            }
        }
        out
    }
}
