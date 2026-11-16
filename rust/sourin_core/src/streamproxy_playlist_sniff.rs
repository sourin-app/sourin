//! Bounded recognition for unlabelled, unencoded, full media responses.
use bytes::Bytes;
use futures_core::Stream;
use std::collections::VecDeque;
use std::pin::Pin;
use std::task::{Context, Poll};

const SIGNATURE: &[u8] = b"#EXTM3U";
const BOM: &[u8] = b"\xef\xbb\xbf";
// BOM + signature + newline: never scan arbitrary media bodies for a tag.
const PREFIX_BYTES: usize = 11;
const PREFIX_WAIT: std::time::Duration = std::time::Duration::from_millis(250);

enum Recognition {
    Possible,
    Playlist,
    Other,
}

fn recognize(prefix: &[u8], eof: bool) -> Recognition {
    let header = if prefix.first() == Some(&BOM[0]) {
        if prefix.len() < BOM.len() {
            return if !eof && BOM.starts_with(prefix) {
                Recognition::Possible
            } else {
                Recognition::Other
            };
        }
        let Some(header) = prefix.strip_prefix(BOM) else {
            return Recognition::Other;
        };
        header
    } else {
        prefix
    };
    if header.len() < SIGNATURE.len() {
        return if !eof && SIGNATURE.starts_with(header) {
            Recognition::Possible
        } else {
            Recognition::Other
        };
    }
    if !header.starts_with(SIGNATURE) {
        return Recognition::Other;
    }
    match header.get(SIGNATURE.len()) {
        Some(b'\r' | b'\n') => Recognition::Playlist,
        None if eof => Recognition::Playlist,
        None => Recognition::Possible,
        _ => Recognition::Other,
    }
}

pub(super) fn eligible(content_type: &str, encoding: &str) -> bool {
    let mime = content_type.split(';').next().unwrap_or("").trim();
    matches!(
        mime,
        "" | "application/octet-stream"
            | "binary/octet-stream"
            | "application/binary"
            | "text/plain"
    ) && (encoding.trim().is_empty() || encoding.trim().eq_ignore_ascii_case("identity"))
}

/// Keep each consumed HTTP frame for lossless replay; copy at most 11 bytes
/// for recognition. A negative/slow prefix never waits for the body EOF.
pub(super) async fn sniff(
    response: &mut reqwest::Response,
) -> Result<(bool, VecDeque<Bytes>), reqwest::Error> {
    let mut chunks = VecDeque::new();
    let mut prefix = Vec::with_capacity(PREFIX_BYTES);
    let deadline = tokio::time::Instant::now() + PREFIX_WAIT;
    loop {
        match recognize(&prefix, false) {
            Recognition::Playlist => return Ok((true, chunks)),
            Recognition::Other => return Ok((false, chunks)),
            Recognition::Possible => {}
        }
        let chunk = match tokio::time::timeout_at(deadline, response.chunk()).await {
            Ok(result) => result?,
            Err(_) => return Ok((false, chunks)),
        };
        let Some(chunk) = chunk else {
            return Ok((
                matches!(recognize(&prefix, true), Recognition::Playlist),
                chunks,
            ));
        };
        if chunk.is_empty() {
            continue;
        }
        let count = (PREFIX_BYTES - prefix.len()).min(chunk.len());
        prefix.extend_from_slice(&chunk[..count]);
        chunks.push_back(chunk);
    }
}

pub(super) struct Replay<S> {
    pub prefix: VecDeque<Bytes>,
    pub rest: Pin<Box<S>>,
}

impl<S: Stream<Item = Result<Bytes, reqwest::Error>>> Stream for Replay<S> {
    type Item = Result<Bytes, reqwest::Error>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if let Some(chunk) = self.prefix.pop_front() {
            return Poll::Ready(Some(Ok(chunk)));
        }
        self.rest.as_mut().poll_next(cx)
    }
}
