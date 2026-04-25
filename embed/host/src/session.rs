//! `IshSession` — handle for a long-lived in-iSH process.
//!
//! Owned shape: callers hold an `Arc<IshSession>`; the instance's reader
//! thread holds a `Weak<SessionInner>` keyed by session id. Once the
//! caller drops their Arc *and* the supervisor has emitted `Closed`, the
//! inner state is collected.

use std::collections::VecDeque;
use std::sync::{Arc, Weak};
use std::time::Duration;

use bytes::Bytes;
use ish_embed_protocol::HostToSupervisor;
use parking_lot::Mutex;
use tokio::sync::{broadcast, Notify};

use crate::error::IshError;
use crate::instance::InstanceInner;

pub type SessionId = u32;

const DEFAULT_RETAINED_BYTES: usize = 1 * 1024 * 1024; // 1 MiB
const EVENT_BROADCAST_DEPTH: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stream {
    Stdout,
    Stderr,
    Pty,
}

impl From<ish_embed_protocol::Stream> for Stream {
    fn from(s: ish_embed_protocol::Stream) -> Self {
        match s {
            ish_embed_protocol::Stream::Stdout => Stream::Stdout,
            ish_embed_protocol::Stream::Stderr => Stream::Stderr,
            ish_embed_protocol::Stream::Pty    => Stream::Pty,
        }
    }
}

#[derive(Debug, Clone)]
pub struct OutputChunk {
    pub seq:    u64,
    pub stream: Stream,
    pub bytes:  Bytes,
}

#[derive(Debug, Clone)]
pub enum SessionEvent {
    Opened   { pid: i32 },
    Output   { seq: u64, stream: Stream, bytes: Bytes },
    Exited   { exit_code: i32, term_signal: i32 },
    Closed,
    Failed   { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteStatus {
    Accepted,
    UnknownSession,
    StdinClosed,
    Starting,
}

#[derive(Debug, Default)]
pub struct ReadOutput {
    pub chunks:      Vec<OutputChunk>,
    pub next_seq:    u64,
    pub exited:      bool,
    pub exit_code:   Option<i32>,
    pub term_signal: Option<i32>,
    pub closed:      bool,
    /// True iff the caller passed an `after_seq` older than what we still
    /// retain. The chunks in this response start at the current floor seq.
    pub missed_older_bytes: bool,
}

#[derive(Default)]
struct RetainedBuf {
    chunks: VecDeque<OutputChunk>,
    bytes:  usize,
    floor:  u64, // smallest seq we still hold
    next:   u64, // next seq the supervisor will assign
}

#[derive(Default)]
struct SessionState {
    pid:           Option<i32>,
    opened:        bool,
    exited:        bool,
    exit_code:     Option<i32>,
    term_signal:   Option<i32>,
    closed:        bool,
    failure:       Option<String>,
}

pub struct SessionInner {
    pub(crate) id:        SessionId,
    pub(crate) instance:  Weak<InstanceInner>,
    state:                Mutex<SessionState>,
    retained:             Mutex<RetainedBuf>,
    retained_capacity:    usize,
    notify:               Notify,
    events:               broadcast::Sender<SessionEvent>,
}

impl SessionInner {
    pub(crate) fn new(id: SessionId, instance: Weak<InstanceInner>) -> Self {
        let (events, _) = broadcast::channel(EVENT_BROADCAST_DEPTH);
        Self {
            id,
            instance,
            state: Mutex::new(SessionState::default()),
            retained: Mutex::new(RetainedBuf {
                chunks: VecDeque::new(),
                bytes:  0,
                floor:  1,
                next:   1,
            }),
            retained_capacity: DEFAULT_RETAINED_BYTES,
            notify: Notify::new(),
            events,
        }
    }

    pub(crate) fn on_opened(&self, pid: i32) {
        {
            let mut s = self.state.lock();
            s.pid = Some(pid);
            s.opened = true;
        }
        let _ = self.events.send(SessionEvent::Opened { pid });
        self.notify.notify_waiters();
    }

    pub(crate) fn on_output(&self, seq: u64, stream: Stream, bytes: Bytes) {
        {
            let mut buf = self.retained.lock();
            // Sanity: drop stale duplicates if the supervisor ever resends.
            if seq < buf.next {
                return;
            }
            buf.bytes += bytes.len();
            buf.chunks.push_back(OutputChunk { seq, stream, bytes: bytes.clone() });
            buf.next = seq + 1;

            // Evict oldest chunks until we're under the cap.
            while buf.bytes > self.retained_capacity {
                if let Some(front) = buf.chunks.pop_front() {
                    buf.bytes -= front.bytes.len();
                    buf.floor = front.seq + 1;
                } else {
                    break;
                }
            }
        }
        let _ = self.events.send(SessionEvent::Output { seq, stream, bytes });
        self.notify.notify_waiters();
    }

    pub(crate) fn on_exited(&self, exit_code: i32, term_signal: i32) {
        {
            let mut s = self.state.lock();
            s.exited = true;
            s.exit_code = Some(exit_code);
            s.term_signal = Some(term_signal);
        }
        let _ = self.events.send(SessionEvent::Exited { exit_code, term_signal });
        self.notify.notify_waiters();
    }

    pub(crate) fn on_closed(&self) {
        {
            let mut s = self.state.lock();
            s.closed = true;
            // Make sure exited=true so readers don't await forever if the
            // supervisor ever closes without an Exited (shouldn't happen
            // but be defensive).
            s.exited = true;
        }
        let _ = self.events.send(SessionEvent::Closed);
        self.notify.notify_waiters();
    }

    pub(crate) fn on_failed(&self, message: String) {
        {
            let mut s = self.state.lock();
            s.failure = Some(message.clone());
            s.exited = true;
        }
        let _ = self.events.send(SessionEvent::Failed { message });
        self.notify.notify_waiters();
    }

    fn snapshot_state(&self) -> SessionState {
        let s = self.state.lock();
        SessionState {
            pid:         s.pid,
            opened:      s.opened,
            exited:      s.exited,
            exit_code:   s.exit_code,
            term_signal: s.term_signal,
            closed:      s.closed,
            failure:     s.failure.clone(),
        }
    }
}

pub struct IshSession {
    inner: Arc<SessionInner>,
}

impl IshSession {
    pub(crate) fn from_inner(inner: Arc<SessionInner>) -> Self {
        Self { inner }
    }

    pub fn id(&self) -> SessionId {
        self.inner.id
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.inner.events.subscribe()
    }

    /// Pull retained output. See `ReadOutput` for semantics. Matches
    /// codex-rs's `ReadParams { after_seq, max_bytes, wait_ms }` shape.
    pub async fn read(
        &self,
        after_seq: Option<u64>,
        max_bytes: Option<usize>,
        wait_ms: Option<u64>,
    ) -> Result<ReadOutput, IshError> {
        let after = after_seq.unwrap_or(0);
        let cap = max_bytes.unwrap_or(usize::MAX);

        // First non-waiting pull.
        let mut out = self.try_collect(after, cap);
        if !out.chunks.is_empty() || out.closed {
            return Ok(out);
        }

        // Block waiting for new data, exit, or close. The supervisor may
        // still emit Output frames after Exited (final drain) — only
        // `closed` is the canonical "no more data" signal. If we wake from
        // an Exited notification, loop back and re-check whether more
        // output has arrived since.
        if let Some(ms) = wait_ms.filter(|ms| *ms > 0) {
            let deadline = std::time::Instant::now() + Duration::from_millis(ms);
            loop {
                let now = std::time::Instant::now();
                if now >= deadline {
                    break;
                }
                let remaining = deadline - now;
                let _ = tokio::time::timeout(remaining, self.inner.notify.notified()).await;
                out = self.try_collect(after, cap);
                if !out.chunks.is_empty() || out.closed {
                    break;
                }
            }
        }
        Ok(out)
    }

    fn try_collect(&self, after: u64, cap: usize) -> ReadOutput {
        let buf = self.inner.retained.lock();
        let state = self.inner.snapshot_state();
        let mut out = ReadOutput {
            chunks:      Vec::new(),
            next_seq:    buf.next,
            exited:      state.exited,
            exit_code:   state.exit_code,
            term_signal: state.term_signal,
            closed:      state.closed,
            missed_older_bytes: false,
        };
        if after + 1 < buf.floor {
            out.missed_older_bytes = true;
        }
        let mut taken = 0usize;
        for chunk in buf.chunks.iter() {
            if chunk.seq <= after {
                continue;
            }
            if taken + chunk.bytes.len() > cap && !out.chunks.is_empty() {
                break;
            }
            taken += chunk.bytes.len();
            out.chunks.push(chunk.clone());
            if taken >= cap {
                break;
            }
        }
        out
    }

    pub async fn write(&self, chunk: &[u8]) -> Result<WriteStatus, IshError> {
        let state = self.inner.snapshot_state();
        if state.closed || state.exited {
            return Ok(WriteStatus::StdinClosed);
        }
        let inst = self.inner.instance.upgrade().ok_or(IshError::ShuttingDown)?;
        if !state.opened {
            // The supervisor will queue Writes against an unopened reqid
            // until OPENED — but we don't currently buffer in the host;
            // surface "Starting" so callers know to retry.
            return Ok(WriteStatus::Starting);
        }
        inst.send_frame(HostToSupervisor::Write {
            reqid: self.inner.id,
            bytes: chunk.to_vec(),
        })?;
        Ok(WriteStatus::Accepted)
    }

    pub async fn signal(&self, signum: i32) -> Result<(), IshError> {
        let inst = self.inner.instance.upgrade().ok_or(IshError::ShuttingDown)?;
        inst.send_frame(HostToSupervisor::Signal { reqid: self.inner.id, signum })
    }

    pub async fn terminate(&self) -> Result<(), IshError> {
        let inst = self.inner.instance.upgrade().ok_or(IshError::ShuttingDown)?;
        inst.send_frame(HostToSupervisor::Term { reqid: self.inner.id })
    }
}
