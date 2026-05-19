//! fork + execve helpers. These are the "child side" of opening a session.

use std::ffi::CString;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

use ish_embed_protocol::{PtySize, SpawnOpts, Stream};

use crate::session::Session;

#[derive(Debug)]
pub struct OpenedSession {
    pub session: Session,
    /// `Some` iff the child failed before exec; the supervisor surfaces it
    /// to the host as a Failed event.
    pub spawn_error: Option<String>,
}

#[derive(Debug)]
pub enum SpawnError {
    Pipe(std::io::Error),
    Pty(std::io::Error),
    Fork(std::io::Error),
    BadArgv,
}

impl std::fmt::Display for SpawnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpawnError::Pipe(e) => write!(f, "pipe: {e}"),
            SpawnError::Pty(e) => write!(f, "openpty: {e}"),
            SpawnError::Fork(e) => write!(f, "fork: {e}"),
            SpawnError::BadArgv => write!(f, "argv must be non-empty"),
        }
    }
}

pub fn spawn(reqid: u32, opts: SpawnOpts) -> Result<OpenedSession, SpawnError> {
    if opts.argv.is_empty() {
        return Err(SpawnError::BadArgv);
    }

    // Pre-allocate everything we'll need on the child side BEFORE fork —
    // post-fork we can't allocate safely from async-signal contexts. CStrings
    // and the env vector are stable references into Rust-side allocations
    // owned by the parent until the child execve's.
    let arg0_path: CString = CString::new(opts.arg0.as_deref().unwrap_or(&opts.argv[0]).as_bytes())
        .map_err(|_| SpawnError::BadArgv)?;
    let argv_cstrs: Vec<CString> = opts
        .argv
        .iter()
        .map(|s| CString::new(s.as_bytes()).map_err(|_| SpawnError::BadArgv))
        .collect::<Result<_, _>>()?;
    let argv_ptrs: Vec<*const libc::c_char> = argv_cstrs
        .iter()
        .map(|c| c.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let envp_cstrs: Option<Vec<CString>> = match &opts.envp {
        Some(env) => Some(
            env.iter()
                .map(|(k, v)| CString::new(format!("{k}={v}")).map_err(|_| SpawnError::BadArgv))
                .collect::<Result<_, _>>()?,
        ),
        None => None,
    };
    let envp_ptrs: Option<Vec<*const libc::c_char>> = envp_cstrs.as_ref().map(|cs| {
        cs.iter()
            .map(|c| c.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect()
    });
    let cwd_cstr: Option<CString> = match &opts.cwd {
        Some(c) => Some(CString::new(c.as_bytes()).map_err(|_| SpawnError::BadArgv)?),
        None => None,
    };

    // Create stdio plumbing.
    let (stream, parent_out, child_stdout, parent_stdin_w, child_stdin_r) = if opts.tty {
        let (master, slave) = openpty(opts.size)?;
        // For tty sessions both stdin and stdout flow through the master fd.
        (Stream::Pty, master, slave, None, None)
    } else {
        let (out_r, out_w) = pipe2_cloexec()?;
        if opts.pipe_stdin {
            let (in_r, in_w) = pipe2_cloexec()?;
            (Stream::Stdout, out_r, out_w, Some(in_w), Some(in_r))
        } else {
            (Stream::Stdout, out_r, out_w, None, None)
        }
    };

    // Self-pipe used to ferry an execve errno from child → parent if exec
    // fails. Closed-on-exec, so a successful execve gives the parent EOF.
    let (err_r, err_w) = pipe2_cloexec()?;

    // SAFETY: fork() returns 0 in the child, child pid in the parent, -1
    // on error. After fork in the child we only call async-signal-safe
    // functions until execve.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(SpawnError::Fork(std::io::Error::last_os_error()));
    }
    if pid == 0 {
        // ----- CHILD -----
        // Drop the parent end of the error pipe; keep the write end (cloexec).
        let err_w_raw = err_w.as_raw_fd();
        drop(err_r);

        // Move child-side stdio into 0/1/2.
        let stdout_fd = child_stdout.as_raw_fd();
        let stdin_fd = child_stdin_r
            .as_ref()
            .map(|fd| fd.as_raw_fd())
            .unwrap_or(-1);

        unsafe {
            libc::setsid();
            if opts.tty {
                // Make the slave our controlling tty.
                libc::ioctl(stdout_fd, libc::TIOCSCTTY as _, 0);
                libc::dup2(stdout_fd, 0);
                libc::dup2(stdout_fd, 1);
                libc::dup2(stdout_fd, 2);
            } else {
                libc::dup2(stdout_fd, 1);
                libc::dup2(stdout_fd, 2);
                if stdin_fd >= 0 {
                    libc::dup2(stdin_fd, 0);
                } else {
                    let dn = libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY);
                    if dn >= 0 {
                        libc::dup2(dn, 0);
                        libc::close(dn);
                    }
                }
            }
        }
        // After dup2 the originals are still open as separate fds; fall
        // through to the closefrom-style sweep below.

        if let Some(cwd) = &cwd_cstr {
            unsafe {
                libc::chdir(cwd.as_ptr());
            }
        }

        // Close every other fd we might have inherited. Anything we needed
        // is already at 0/1/2, plus err_w which is cloexec and will close
        // automatically on a successful execve.
        close_all_fds_above(2, err_w_raw);

        // exec
        let envp = match &envp_ptrs {
            Some(p) => p.as_ptr(),
            None => unsafe {
                // Inherit our own environ.
                extern "C" {
                    static environ: *const *const libc::c_char;
                }
                environ as *const *const libc::c_char
            },
        };
        unsafe {
            libc::execve(arg0_path.as_ptr(), argv_ptrs.as_ptr(), envp);
        }

        // execve only returns on failure. Send the errno to the parent
        // and bail.
        let errno = std::io::Error::last_os_error()
            .raw_os_error()
            .unwrap_or(libc::EIO);
        let bytes = (errno as i32).to_le_bytes();
        unsafe {
            let _ = libc::write(err_w_raw, bytes.as_ptr() as *const libc::c_void, 4);
            libc::_exit(127);
        }
    }

    // ----- PARENT -----
    // Close the child-side fds so EOF is observable when the child exits.
    drop(child_stdout);
    drop(child_stdin_r);
    drop(err_w);

    // Read the error pipe; EOF means execve succeeded, 4 bytes means it
    // didn't. Use blocking read since this is a brief handshake.
    let mut errno_buf = [0u8; 4];
    let exec_err = read_full(err_r.as_raw_fd(), &mut errno_buf);
    drop(err_r);
    let spawn_error = match exec_err {
        Ok(0) => None,
        Ok(_) => {
            let errno = i32::from_le_bytes(errno_buf);
            // Reap the failed child immediately so the supervisor doesn't
            // see a stale SIGCHLD later.
            unsafe {
                libc::waitpid(pid, std::ptr::null_mut(), 0);
            }
            Some(format!(
                "execve: {}",
                std::io::Error::from_raw_os_error(errno)
            ))
        }
        Err(e) => Some(format!("exec-error pipe: {e}")),
    };

    set_nonblocking(parent_out.as_raw_fd());
    let session = Session::new(reqid, pid, stream, parent_out, parent_stdin_w);
    Ok(OpenedSession {
        session,
        spawn_error,
    })
}

// ---------------------------------------------------------------------------
// Small low-level helpers
// ---------------------------------------------------------------------------

fn pipe2_cloexec() -> Result<(OwnedFd, OwnedFd), SpawnError> {
    let mut fds = [-1i32; 2];
    let rc = unsafe { libc::pipe(fds.as_mut_ptr()) };
    if rc < 0 {
        return Err(SpawnError::Pipe(std::io::Error::last_os_error()));
    }
    set_cloexec(fds[0]);
    set_cloexec(fds[1]);
    // SAFETY: pipe returns valid fds we now own.
    let r = unsafe { OwnedFd::from_raw_fd(fds[0]) };
    let w = unsafe { OwnedFd::from_raw_fd(fds[1]) };
    Ok((r, w))
}

fn openpty(size: Option<PtySize>) -> Result<(OwnedFd, OwnedFd), SpawnError> {
    let mut master = -1i32;
    let mut slave = -1i32;
    let mut winsize = size.map(|size| libc::winsize {
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    });
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            winsize
                .as_mut()
                .map(|ws| ws as *mut libc::winsize)
                .unwrap_or(std::ptr::null_mut()),
        )
    };
    if rc < 0 {
        return Err(SpawnError::Pty(std::io::Error::last_os_error()));
    }
    // openpty doesn't set CLOEXEC; do it ourselves so the child doesn't
    // inherit either end (we'll dup2 the slave into 0/1/2).
    set_cloexec(master);
    set_cloexec(slave);
    let m = unsafe { OwnedFd::from_raw_fd(master) };
    let s = unsafe { OwnedFd::from_raw_fd(slave) };
    Ok((m, s))
}

fn set_cloexec(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
}

fn read_full(fd: RawFd, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0usize;
    while filled < buf.len() {
        let n = unsafe {
            libc::read(
                fd,
                buf.as_mut_ptr().add(filled) as *mut libc::c_void,
                buf.len() - filled,
            )
        };
        match n {
            0 => return Ok(filled),
            n if n < 0 => {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            n => filled += n as usize,
        }
    }
    Ok(filled)
}

/// Close every open fd above `floor`, except `keep`. Used on the child side
/// to drop everything the supervisor had inherited (request fd, response
/// fd, signalfd, other sessions' pipes, etc.).
fn close_all_fds_above(floor: RawFd, keep: RawFd) {
    // Try /proc/self/fd first; fall back to walking 3..N.
    let dir = unsafe { libc::opendir(c"/proc/self/fd".as_ptr()) };
    if !dir.is_null() {
        loop {
            let ent = unsafe { libc::readdir(dir) };
            if ent.is_null() {
                break;
            }
            let name_ptr = unsafe { (*ent).d_name.as_ptr() };
            let name = unsafe { std::ffi::CStr::from_ptr(name_ptr) };
            let s = name.to_string_lossy();
            if s == "." || s == ".." {
                continue;
            }
            if let Ok(fd) = s.parse::<RawFd>() {
                if fd > floor && fd != keep {
                    unsafe {
                        libc::close(fd);
                    }
                }
            }
        }
        unsafe {
            libc::closedir(dir);
        }
        return;
    }

    // Fallback: brute-force loop. iSH's emulated /proc may not exist yet.
    let max = unsafe { libc::sysconf(libc::_SC_OPEN_MAX) } as RawFd;
    let cap = if max > 0 { max } else { 4096 };
    for fd in (floor + 1)..cap {
        if fd == keep {
            continue;
        }
        unsafe {
            libc::close(fd);
        }
    }
}
