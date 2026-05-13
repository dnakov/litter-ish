//! iSH PID-1 supervisor.
//!
//! Runs as init inside iSH. Talks to the host over fd 0 (requests) and
//! fd 1 (responses) using the framed binary protocol from
//! `ish-embed-protocol`. Forks one child per `Open` request, multiplexes
//! their stdio back to the host, and reaps via signalfd(SIGCHLD).
//!
//! Single-threaded. We don't need work stealing: ≤64 concurrent children
//! in the worst case, a poll loop is cheaper and smaller than tokio.

use std::collections::HashMap;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::process::ExitCode;

use ish_embed_protocol::{
    encode_frame, try_decode_frame, HostToSupervisor, SupervisorToHost, PROTOCOL_VERSION,
};

mod session;
mod spawn;

use crate::session::Session;

const OUTPUT_CHUNK: usize = 32 * 1024;
const REQUEST_BUF_INITIAL: usize = 64 * 1024;

fn main() -> ExitCode {
    let exit_code = match run() {
        Ok(()) => 0,
        Err(e) => {
            // Surface the failure as an Err frame on fd 1 only. We must
            // NEVER write non-frame text on stdout/stderr — they're merged
            // into the host's binary response stream and any text would
            // corrupt the framing.
            let frame = SupervisorToHost::Err {
                reqid: None,
                code: 1,
                msg: format!("{e}"),
            };
            if let Ok(bytes) = encode_frame(&frame) {
                let _ = io::stdout().write_all(&bytes);
                let _ = io::stdout().flush();
            }
            1
        }
    };
    ExitCode::from(exit_code)
}

/// Self-pipe write fd, used by the SIGCHLD handler to wake up the poll
/// loop. iSH doesn't implement signalfd, so this is the portable fallback.
static SIGCHLD_WAKE_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

extern "C" fn sigchld_handler(_: libc::c_int) {
    let fd = SIGCHLD_WAKE_FD.load(std::sync::atomic::Ordering::Relaxed);
    if fd >= 0 {
        // Async-signal-safe: write a single byte to the self-pipe.
        let buf = [b'.'];
        unsafe {
            libc::write(fd, buf.as_ptr() as *const libc::c_void, 1);
        }
    }
}

fn run() -> io::Result<()> {
    // Send the readiness handshake before doing anything else; the host's
    // reader thread is already blocked on it.
    write_frame(&SupervisorToHost::Ready {
        protocol_version: PROTOCOL_VERSION,
    })?;

    // SIGCHLD self-pipe (signalfd isn't implemented by iSH).
    let mut sig_pipe = [-1i32; 2];
    if unsafe { libc::pipe(sig_pipe.as_mut_ptr()) } < 0 {
        return Err(io::Error::last_os_error());
    }
    set_nonblocking(sig_pipe[0]);
    set_nonblocking(sig_pipe[1]);
    let sig_read = unsafe { OwnedFd::from_raw_fd(sig_pipe[0]) };
    SIGCHLD_WAKE_FD.store(sig_pipe[1], std::sync::atomic::Ordering::Relaxed);

    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = sigchld_handler as usize;
    sa.sa_flags = libc::SA_NOCLDSTOP | libc::SA_RESTART;
    unsafe {
        libc::sigemptyset(&mut sa.sa_mask);
        libc::sigaction(libc::SIGCHLD, &sa, std::ptr::null_mut());
    }

    // Ignore SIGPIPE so a writer error on fd 1 surfaces as EPIPE rather
    // than a crash.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    // Make stdin nonblocking so partial reads don't wedge the loop.
    set_nonblocking(libc::STDIN_FILENO);

    let mut sessions: HashMap<u32, Session> = HashMap::new();
    let mut request_buf: Vec<u8> = Vec::with_capacity(REQUEST_BUF_INITIAL);
    let mut shutdown_requested = false;

    loop {
        // Build pollfds: stdin, signalfd, every session's output fd.
        let mut pollfds: Vec<libc::pollfd> = Vec::with_capacity(2 + sessions.len());
        pollfds.push(libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        });
        pollfds.push(libc::pollfd {
            fd: sig_read.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        // Stable iteration order so we can map indices back to session ids.
        let session_ids: Vec<u32> = sessions.keys().copied().collect();
        for &id in &session_ids {
            let s = sessions.get(&id).unwrap();
            pollfds.push(libc::pollfd {
                fd: s.output_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
        }

        let timeout = if shutdown_requested && sessions.is_empty() {
            0 // drain mode complete
        } else if sessions.is_empty() {
            -1
        } else {
            50
        };
        let n = unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as _, timeout) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        if n == 0 && shutdown_requested && sessions.is_empty() {
            return Ok(());
        }

        // 1) Drain stdin → request frames.
        if pollfds[0].revents & libc::POLLIN != 0 {
            drain_stdin(&mut request_buf)?;
            while let Some((frame, consumed)) = decode_one(&request_buf)? {
                request_buf.drain(..consumed);
                handle_request(frame, &mut sessions, &mut shutdown_requested)?;
            }
        }
        if pollfds[0].revents & (libc::POLLHUP | libc::POLLERR) != 0 {
            // Host closed the request stream; treat as shutdown.
            shutdown_requested = true;
            kill_all(&sessions, libc::SIGTERM);
        }

        // 2) Reap zombies.
        if pollfds[1].revents & libc::POLLIN != 0 {
            drain_self_pipe(sig_read.as_raw_fd())?;
            reap_children(&mut sessions)?;
        }

        // 3) Drain session outputs. Poll readiness is not reliable for every
        //    iSH pipe path, so live sessions use a short timeout and a
        //    nonblocking drain pass even when revents is empty.
        for &id in &session_ids {
            drain_session_output(&mut sessions, id)?;
        }

        // 4) Emit Closed for any session that has both reaped and EOFed,
        //    and remove it from the table.
        finalize_done_sessions(&mut sessions)?;

        // 5) During shutdown, escalate SIGTERM to SIGKILL after the first
        //    pass. This is a coarse policy — the host can wait or hard-kill
        //    iSH if it really wants out.
        if shutdown_requested && !sessions.is_empty() {
            kill_all(&sessions, libc::SIGKILL);
        }
    }
}

// ---------------------------------------------------------------------------
// Frame I/O helpers
// ---------------------------------------------------------------------------

fn write_frame(frame: &SupervisorToHost) -> io::Result<()> {
    let bytes = encode_frame(frame)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("encode: {e:?}")))?;
    // stdout is held by std; take stdout once per write to keep things
    // simple, since we're single-threaded and contention isn't a concern.
    let mut out = io::stdout().lock();
    out.write_all(&bytes)?;
    out.flush()?;
    Ok(())
}

fn decode_one(buf: &[u8]) -> io::Result<Option<(HostToSupervisor, usize)>> {
    match try_decode_frame::<HostToSupervisor>(buf) {
        Ok(opt) => Ok(opt),
        Err(e) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("decode: {e:?}"),
        )),
    }
}

fn drain_stdin(buf: &mut Vec<u8>) -> io::Result<()> {
    let mut tmp = [0u8; 8192];
    loop {
        let n = unsafe {
            libc::read(
                libc::STDIN_FILENO,
                tmp.as_mut_ptr() as *mut libc::c_void,
                tmp.len(),
            )
        };
        match n {
            n if n > 0 => buf.extend_from_slice(&tmp[..n as usize]),
            0 => return Ok(()), // EOF — caller picks up POLLHUP
            n if n < 0 => {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::WouldBlock {
                    return Ok(());
                }
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            _ => unreachable!(),
        }
    }
}

fn drain_self_pipe(fd: RawFd) -> io::Result<()> {
    let mut buf = [0u8; 64];
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::WouldBlock {
                return Ok(());
            }
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        if n == 0 {
            return Ok(());
        }
    }
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

fn handle_request(
    frame: HostToSupervisor,
    sessions: &mut HashMap<u32, Session>,
    shutdown_requested: &mut bool,
) -> io::Result<()> {
    match frame {
        HostToSupervisor::Open { reqid, opts } => {
            // Disallow duplicate reqid; the host should use a fresh one.
            if sessions.contains_key(&reqid) {
                write_frame(&SupervisorToHost::Err {
                    reqid: Some(reqid),
                    code: libc::EEXIST as u32,
                    msg: "reqid already in use".into(),
                })?;
                return Ok(());
            }
            match spawn::spawn(reqid, opts) {
                Ok(spawn::OpenedSession {
                    session,
                    spawn_error,
                }) => {
                    let pid = session.pid;
                    if let Some(err_msg) = spawn_error {
                        // Child failed before exec. Report and don't keep
                        // the session: the child is already reaped inside
                        // spawn() and has no fds left to drain.
                        write_frame(&SupervisorToHost::Err {
                            reqid: Some(reqid),
                            code: libc::EIO as u32,
                            msg: err_msg,
                        })?;
                        write_frame(&SupervisorToHost::Closed { reqid })?;
                        return Ok(());
                    }
                    sessions.insert(reqid, session);
                    write_frame(&SupervisorToHost::Opened { reqid, pid })?;
                }
                Err(e) => {
                    write_frame(&SupervisorToHost::Err {
                        reqid: Some(reqid),
                        code: libc::EIO as u32,
                        msg: format!("{e}"),
                    })?;
                    write_frame(&SupervisorToHost::Closed { reqid })?;
                }
            }
        }
        HostToSupervisor::Write { reqid, bytes } => {
            let Some(s) = sessions.get(&reqid) else {
                return Ok(()); // unknown reqid; silently drop
            };
            let Some(fd) = s.stdin_target() else {
                return Ok(()); // stdin not writable for this session
            };
            // Best-effort blocking write of the whole chunk. EAGAIN is
            // unlikely because we don't set the parent ends nonblocking;
            // if we ever do, a partial-write loop with poll(POLLOUT) goes
            // here.
            let mut written = 0usize;
            while written < bytes.len() {
                let n = unsafe {
                    libc::write(
                        fd,
                        bytes.as_ptr().add(written) as *const libc::c_void,
                        bytes.len() - written,
                    )
                };
                if n < 0 {
                    let err = io::Error::last_os_error();
                    if err.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    if err.raw_os_error() == Some(libc::EPIPE) {
                        break; // child died; SIGCHLD will tell us
                    }
                    return Ok(()); // best-effort; don't kill the loop
                }
                written += n as usize;
            }
        }
        HostToSupervisor::Signal { reqid, signum } => {
            if let Some(s) = sessions.get(&reqid) {
                unsafe {
                    libc::kill(-s.pid, signum);
                }
            }
        }
        HostToSupervisor::Term { reqid } => {
            if let Some(s) = sessions.get(&reqid) {
                unsafe {
                    libc::kill(-s.pid, libc::SIGKILL);
                }
            }
        }
        HostToSupervisor::Shutdown => {
            *shutdown_requested = true;
            kill_all(sessions, libc::SIGTERM);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Reaping + output draining
// ---------------------------------------------------------------------------

fn reap_children(sessions: &mut HashMap<u32, Session>) -> io::Result<()> {
    loop {
        let mut status: libc::c_int = 0;
        let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
        if pid <= 0 {
            return Ok(());
        }
        let (exit_code, term_signal) = decode_status(status);
        // Find session by pid.
        let Some((_, s)) = sessions.iter_mut().find(|(_, s)| s.pid == pid) else {
            continue; // not one of ours
        };
        s.exit_code = Some(exit_code);
        s.term_signal = Some(term_signal);
        if !s.exited_announced {
            let frame = SupervisorToHost::Exited {
                reqid: s.reqid,
                exit_code,
                term_signal,
            };
            s.exited_announced = true;
            write_frame(&frame)?;
        }
    }
}

fn drain_session_output(sessions: &mut HashMap<u32, Session>, reqid: u32) -> io::Result<()> {
    // Take the session out so we can call write_frame (which borrows
    // global stdout) without overlapping mutable borrows.
    let Some(s) = sessions.get_mut(&reqid) else {
        return Ok(());
    };
    let stream = s.stream;
    let mut buf = [0u8; OUTPUT_CHUNK];
    loop {
        let n = unsafe {
            libc::read(
                s.output_fd(),
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
            )
        };
        if n > 0 {
            let seq = s.next_seq;
            s.next_seq += 1;
            let frame = SupervisorToHost::Output {
                reqid,
                seq,
                stream,
                bytes: buf[..n as usize].to_vec(),
            };
            write_frame(&frame)?;
            continue;
        }
        if n == 0 {
            s.eof = true;
            return Ok(());
        }
        // n < 0
        let err = io::Error::last_os_error();
        match err.kind() {
            io::ErrorKind::WouldBlock => return Ok(()),
            io::ErrorKind::Interrupted => continue,
            _ => {
                // For pty masters, EIO is the canonical "child closed all
                // slave references" signal.
                if err.raw_os_error() == Some(libc::EIO) {
                    s.eof = true;
                    return Ok(());
                }
                return Err(err);
            }
        }
    }
}

fn finalize_done_sessions(sessions: &mut HashMap<u32, Session>) -> io::Result<()> {
    let done: Vec<u32> = sessions
        .iter()
        .filter(|(_, s)| s.eof && s.exited_announced)
        .map(|(id, _)| *id)
        .collect();
    for id in done {
        write_frame(&SupervisorToHost::Closed { reqid: id })?;
        sessions.remove(&id);
    }
    Ok(())
}

fn kill_all(sessions: &HashMap<u32, Session>, sig: libc::c_int) {
    for s in sessions.values() {
        unsafe {
            libc::kill(-s.pid, sig);
        }
    }
}

// ---------------------------------------------------------------------------
// Tiny helpers
// ---------------------------------------------------------------------------

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
}

fn decode_status(status: libc::c_int) -> (i32, i32) {
    if libc::WIFEXITED(status) {
        (libc::WEXITSTATUS(status), 0)
    } else if libc::WIFSIGNALED(status) {
        (-1, libc::WTERMSIG(status))
    } else {
        (-1, 0)
    }
}
