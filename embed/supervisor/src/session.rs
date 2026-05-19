//! Per-session state owned by the supervisor.
//!
//! A session represents one child process the host asked us to spawn. It
//! owns the parent ends of the child's stdio (a master pty fd in tty mode,
//! or two pipe halves in pipe mode), tracks the child's pid, and assigns a
//! monotonic seq number to every output chunk we ship to the host.

use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use ish_embed_protocol::PtySize;

#[derive(Debug)]
pub struct Session {
    pub reqid: u32,
    pub pid: libc::pid_t,
    pub stream: ish_embed_protocol::Stream,
    /// Parent end of the child's stdout (and stderr, merged). For tty
    /// sessions this is the pty master and is also the stdin write end.
    pub output: OwnedFd,
    /// Parent end of stdin for non-tty sessions when `pipe_stdin` was set.
    /// For tty sessions stdin is the master fd (== output); we set this to
    /// `None` and route writes through `output`.
    pub stdin_w: Option<OwnedFd>,
    pub next_seq: u64,
    /// Set once SIGCHLD reaped this child. We may still have buffered
    /// output to drain before we can send Closed.
    pub exit_code: Option<i32>,
    pub term_signal: Option<i32>,
    /// Set once we've sent Exited to the host.
    pub exited_announced: bool,
    /// Set once read() returned 0 / POLLHUP. We can't send Closed until
    /// both this and `exit_code.is_some()` are true.
    pub eof: bool,
}

impl Session {
    pub fn new(
        reqid: u32,
        pid: libc::pid_t,
        stream: ish_embed_protocol::Stream,
        output: OwnedFd,
        stdin_w: Option<OwnedFd>,
    ) -> Self {
        Self {
            reqid,
            pid,
            stream,
            output,
            stdin_w,
            next_seq: 1,
            exit_code: None,
            term_signal: None,
            exited_announced: false,
            eof: false,
        }
    }

    pub fn output_fd(&self) -> RawFd {
        self.output.as_raw_fd()
    }

    pub fn stdin_target(&self) -> Option<RawFd> {
        if let Some(fd) = &self.stdin_w {
            return Some(fd.as_raw_fd());
        }
        // tty: writes go to the master fd.
        if matches!(self.stream, ish_embed_protocol::Stream::Pty) {
            return Some(self.output.as_raw_fd());
        }
        None
    }

    pub fn resize_pty(&self, size: PtySize) -> std::io::Result<()> {
        if !matches!(self.stream, ish_embed_protocol::Stream::Pty) {
            return Ok(());
        }
        let winsize = libc::winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let rc = unsafe {
            libc::ioctl(
                self.output.as_raw_fd(),
                libc::TIOCSWINSZ as _,
                &winsize as *const libc::winsize,
            )
        };
        if rc < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}
