//! Wire protocol between the host (`ish-embed-host`) and the supervisor
//! (`ish-supervisor`) running as PID 1 inside iSH.
//!
//! Frame on the wire: `u32_le length | postcard-encoded enum`. Length is the
//! byte count of the postcard payload that follows; postcard is not
//! self-delimiting on a stream, so we frame it ourselves.
//!
//! Both sides depend on the exact same `PROTOCOL_VERSION`. The supervisor
//! sends `Ready { protocol_version }` immediately after exec; the host bails
//! with `IshError::ProtocolMismatch` if that doesn't match.

#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

use alloc::{string::String, vec::Vec};
use serde::{Deserialize, Serialize};

/// Bumped on any breaking change to the wire enums below.
pub const PROTOCOL_VERSION: u32 = 2;

/// Maximum bytes of postcard payload we'll accept in one frame. Output
/// chunks are capped well below this in the supervisor; this is just a
/// guard against a corrupt length prefix DoSing the reader.
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpawnOpts {
    pub argv: Vec<String>,
    /// `None` means "inherit init's environment" (which is the env the host
    /// passed when execve'ing the supervisor).
    pub envp: Option<Vec<(String, String)>>,
    pub cwd: Option<String>,
    pub tty: bool,
    /// Initial PTY window size. Ignored unless `tty` is true.
    pub size: Option<PtySize>,
    pub pipe_stdin: bool,
    pub arg0: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PtySize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Stream {
    Stdout,
    Stderr,
    /// Read from the master side of a forkpty(); stdout and stderr are
    /// merged into one stream by the kernel pty layer.
    Pty,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum HostToSupervisor {
    Open {
        reqid: u32,
        opts: SpawnOpts,
    },
    Write {
        reqid: u32,
        bytes: Vec<u8>,
    },
    /// Resize a tty session's PTY. No-op for pipe-backed sessions.
    Resize {
        reqid: u32,
        size: PtySize,
    },
    /// Send any signal to the session's process group.
    Signal {
        reqid: u32,
        signum: i32,
    },
    /// SIGKILL the pgid and reap. Idempotent.
    Term {
        reqid: u32,
    },
    /// Tear down all sessions, then `_exit(0)` so iSH's halt_system fires.
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SupervisorToHost {
    /// Sent once, immediately after the supervisor finishes its own setup.
    Ready { protocol_version: u32 },
    /// Sent once per session, after a successful fork+execve.
    Opened { reqid: u32, pid: i32 },
    /// One chunk of merged child output. `seq` is monotonic per session,
    /// starts at 1 on the first chunk.
    Output {
        reqid: u32,
        seq: u64,
        stream: Stream,
        bytes: Vec<u8>,
    },
    /// Child process has been reaped. May still be followed by trailing
    /// `Output` frames if there were buffered bytes; the *final* event for
    /// a session is always `Closed`.
    Exited {
        reqid: u32,
        exit_code: i32,
        term_signal: i32,
    },
    /// All output drained; safe for the host to free the session.
    Closed { reqid: u32 },
    /// Either a session-scoped error (reqid: Some) or an instance-level
    /// failure (reqid: None) that should poison the whole instance.
    Err {
        reqid: Option<u32>,
        code: u32,
        msg: String,
    },
}

#[derive(Debug)]
pub enum FrameError {
    Truncated,
    LengthOverflow,
    Decode,
}

#[cfg(feature = "std")]
mod io {
    use super::*;
    use std::io::{Read, Write};

    /// Read one length-prefixed frame from a blocking reader. Returns
    /// `Ok(None)` only on a clean EOF *between* frames; a half-frame at EOF
    /// is `Truncated`.
    pub fn read_frame<R: Read, T: for<'de> Deserialize<'de>>(
        r: &mut R,
    ) -> Result<Option<T>, FrameError> {
        let mut len_buf = [0u8; 4];
        match r.read_exact(&mut len_buf) {
            Ok(()) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(_) => return Err(FrameError::Truncated),
        }
        let len = u32::from_le_bytes(len_buf) as usize;
        if len > MAX_FRAME_BYTES {
            return Err(FrameError::LengthOverflow);
        }
        let mut buf = vec![0u8; len];
        r.read_exact(&mut buf).map_err(|_| FrameError::Truncated)?;
        let value = postcard::from_bytes::<T>(&buf).map_err(|_| FrameError::Decode)?;
        Ok(Some(value))
    }

    /// Encode + length-prefix + write one frame. Caller serializes access if
    /// multiple producers share the writer.
    pub fn write_frame<W: Write, T: Serialize>(w: &mut W, value: &T) -> std::io::Result<()> {
        let payload = postcard::to_allocvec(value).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::Other, format!("postcard encode: {e:?}"))
        })?;
        let len = u32::try_from(payload.len())
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"))?;
        w.write_all(&len.to_le_bytes())?;
        w.write_all(&payload)?;
        Ok(())
    }
}

#[cfg(feature = "std")]
pub use io::{read_frame, write_frame};

/// `no_std`-friendly variants. Caller supplies the byte stream however they
/// got it; useful for the supervisor where we already own the read loop and
/// don't want to drag in std::io. Returns the number of input bytes consumed
/// (so callers can shift their buffer).
pub fn try_decode_frame<T: for<'de> Deserialize<'de>>(
    buf: &[u8],
) -> Result<Option<(T, usize)>, FrameError> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let mut lb = [0u8; 4];
    lb.copy_from_slice(&buf[..4]);
    let len = u32::from_le_bytes(lb) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(FrameError::LengthOverflow);
    }
    let total = 4usize.checked_add(len).ok_or(FrameError::LengthOverflow)?;
    if buf.len() < total {
        return Ok(None);
    }
    let value = postcard::from_bytes::<T>(&buf[4..total]).map_err(|_| FrameError::Decode)?;
    Ok(Some((value, total)))
}

/// Encode a frame into a freshly-allocated Vec<u8>. Caller writes the bytes
/// however it wants. Used by the supervisor (no std::io::Write needed).
pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, postcard::Error> {
    let payload = postcard::to_allocvec(value)?;
    let len = payload.len() as u32;
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&payload);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    extern crate std;

    #[test]
    fn roundtrip_open() {
        let frame = HostToSupervisor::Open {
            reqid: 42,
            opts: SpawnOpts {
                argv: std::vec!["/bin/sh".into(), "-c".into(), "echo hi".into()],
                envp: Some(std::vec![("PATH".into(), "/bin".into())]),
                cwd: Some("/tmp".into()),
                tty: false,
                size: None,
                pipe_stdin: true,
                arg0: None,
            },
        };
        let bytes = encode_frame(&frame).unwrap();
        let (decoded, n) = try_decode_frame::<HostToSupervisor>(&bytes)
            .unwrap()
            .unwrap();
        assert_eq!(n, bytes.len());
        assert_eq!(decoded, frame);
    }

    #[test]
    fn partial_frame_returns_none() {
        let frame = SupervisorToHost::Ready {
            protocol_version: PROTOCOL_VERSION,
        };
        let bytes = encode_frame(&frame).unwrap();
        let truncated = &bytes[..bytes.len() - 1];
        let result: Option<(SupervisorToHost, usize)> = try_decode_frame(truncated).unwrap();
        assert!(
            result.is_none(),
            "truncated frame should return Ok(None), not Err"
        );
    }

    #[test]
    fn output_frame_seq_is_preserved() {
        let frame = SupervisorToHost::Output {
            reqid: 7,
            seq: 123,
            stream: Stream::Stdout,
            bytes: std::vec![1, 2, 3, 4, 5],
        };
        let bytes = encode_frame(&frame).unwrap();
        let (decoded, _) = try_decode_frame::<SupervisorToHost>(&bytes)
            .unwrap()
            .unwrap();
        assert_eq!(decoded, frame);
    }
}
