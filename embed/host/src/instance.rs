//! `IshInstance` — a booted iSH kernel + supervisor pair.
//!
//! Single-instance-per-process (matches the previous C library; iSH uses
//! per-process kernel globals). After `boot()` returns successfully the
//! caller has an Arc that they can spawn sessions from until they call
//! `shutdown().await`.

use std::collections::HashMap;
use std::ffi::CString;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock, Weak};
use std::thread;
use std::time::Duration;

use bytes::Bytes;
use ish_embed_protocol::{
    read_frame, HostToSupervisor, PtySize, SpawnOpts as WireSpawnOpts, SupervisorToHost,
    PROTOCOL_VERSION,
};
use parking_lot::Mutex;

use crate::error::IshError;
use crate::ffi;
use crate::session::{IshSession, SessionId, SessionInner};

/// Default path inside the rootfs where the supervisor is dropped.
const SUPERVISOR_PATH_IN_ROOTFS: &str = "/sbin/ish-supervisor";

static GLOBAL_INSTANCE: OnceLock<Weak<InstanceInner>> = OnceLock::new();

/// Instance-level singleton: the C kernel keeps process-global state, so
/// trying to boot twice in the same process is undefined. We surface that
/// as `IshError::AlreadyInitialised`.
fn try_claim_singleton() -> Result<(), IshError> {
    if let Some(weak) = GLOBAL_INSTANCE.get() {
        if weak.strong_count() > 0 {
            return Err(IshError::AlreadyInitialised);
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct SpawnOpts {
    pub argv: Vec<String>,
    pub envp: Option<Vec<(String, String)>>,
    pub cwd: Option<PathBuf>,
    pub tty: bool,
    pub size: Option<PtySize>,
    pub pipe_stdin: bool,
    pub arg0: Option<String>,
}

impl SpawnOpts {
    pub fn cmd(argv: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            argv: argv.into_iter().map(Into::into).collect(),
            envp: None,
            cwd: None,
            tty: false,
            size: None,
            pipe_stdin: false,
            arg0: None,
        }
    }

    fn into_wire(self) -> WireSpawnOpts {
        WireSpawnOpts {
            argv: self.argv,
            envp: self.envp,
            cwd: self.cwd.map(|p| p.to_string_lossy().into_owned()),
            tty: self.tty,
            size: self.size,
            pipe_stdin: self.pipe_stdin,
            arg0: self.arg0,
        }
    }
}

pub(crate) struct InstanceInner {
    next_reqid: AtomicU32,
    sessions: Mutex<HashMap<SessionId, Weak<SessionInner>>>,
    writer_tx: std::sync::mpsc::Sender<HostToSupervisor>,
    poisoned: AtomicBool,
    /// Only used during boot; signalled from the kernel exit hook.
    kernel_exit: Arc<KernelExit>,
}

struct KernelExit {
    mtx: parking_lot::Mutex<Option<i32>>,
    cv: parking_lot::Condvar,
}

impl InstanceInner {
    pub(crate) fn send_frame(&self, frame: HostToSupervisor) -> Result<(), IshError> {
        if self.poisoned.load(Ordering::Acquire) {
            return Err(IshError::ShuttingDown);
        }
        self.writer_tx
            .send(frame)
            .map_err(|_| IshError::ShuttingDown)
    }
}

pub struct IshInstance {
    inner: Arc<InstanceInner>,
}

impl IshInstance {
    /// Boot the iSH kernel with `rootfs_path` mounted at `/`, drop the
    /// embedded supervisor binary at `/sbin/ish-supervisor`, exec it as
    /// init, and read the readiness handshake. Sync because the kernel
    /// boot sequence ends in `task_start` which spawns its own pthread.
    pub fn boot(rootfs_path: &Path, workdir: Option<&Path>) -> Result<Self, IshError> {
        try_claim_singleton()?;

        // 1. Mount the fakefs.
        let rootfs_c = CString::new(rootfs_path.as_os_str().as_bytes())
            .map_err(|_| IshError::InvalidRootfs)?;
        let rc = unsafe { ffi::ish_ffi_mount_fakefs(rootfs_c.as_ptr()) };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "mount_fakefs",
                rc,
            });
        }

        // 2. Become PID 1.
        let rc = unsafe { ffi::ish_ffi_become_init() };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "become_init",
                rc,
            });
        }

        // 3. Mount guest pseudo-filesystems used by shells and language tools.
        let rc = unsafe { ffi::ish_ffi_mount_procfs() };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "mount_procfs",
                rc,
            });
        }
        let rc = unsafe { ffi::ish_ffi_mount_devpts() };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "mount_devpts",
                rc,
            });
        }

        // 4. Drop the supervisor binary into the fakefs at /sbin/ish-supervisor.
        //    On a freshly-built production rootfs this file is already
        //    pre-baked at fakefsify time and the call is a fast overwrite;
        //    on dev rootfs it's the first time. We go through the kernel's
        //    own generic_open() so fakefs metadata is registered correctly.
        let supervisor_path = std::ffi::CString::new(SUPERVISOR_PATH_IN_ROOTFS).unwrap();
        let elf = crate::SUPERVISOR_ELF;
        let rc = unsafe {
            ffi::ish_ffi_install_executable(supervisor_path.as_ptr(), elf.as_ptr(), elf.len())
        };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "install_executable",
                rc,
            });
        }

        // 5. Pipes for supervisor I/O. fd 0 in the supervisor reads from
        //    `host_stdin_w`; fd 1 (and fd 2, dup'd) writes to
        //    `host_stdout_r`. `make_pipe()` returns (read_end, write_end);
        //    we destructure so the host owns the writable end on the stdin
        //    pipe and the readable end on the stdout pipe.
        let (kernel_in_r, host_stdin_w) = make_pipe()?;
        let (host_stdout_r, kernel_out_w_a) = make_pipe()?;
        let kernel_out_w_b = unsafe { libc::dup(kernel_out_w_a.as_raw_fd()) };
        if kernel_out_w_b < 0 {
            return Err(IshError::Io(std::io::Error::last_os_error()));
        }

        // 6. Install the kernel side of the pipes as init's stdio. After
        //    this call the kernel owns those fds.
        let rc = unsafe {
            ffi::ish_ffi_install_pipe_stdio(
                kernel_in_r.into_raw_fd(),
                kernel_out_w_a.into_raw_fd(),
                kernel_out_w_b,
            )
        };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "install_stdio",
                rc,
            });
        }

        // 7. chdir.
        let workdir_c = match workdir {
            Some(p) => {
                CString::new(p.as_os_str().as_bytes()).map_err(|_| IshError::InvalidRootfs)?
            }
            None => CString::new("/").unwrap(),
        };
        let rc = unsafe { ffi::ish_ffi_chdir(workdir_c.as_ptr()) };
        if rc < 0 {
            return Err(IshError::KernelCall { call: "chdir", rc });
        }

        // 7. Register the exit hook. We have to do this BEFORE task_start
        //    so we don't race against the kernel thread.
        let kernel_exit = Arc::new(KernelExit {
            mtx: parking_lot::Mutex::new(None),
            cv: parking_lot::Condvar::new(),
        });
        register_exit_hook(kernel_exit.clone());

        // 8. execve the supervisor.
        // do_execve / args_size expect both argv and envp to be NUL-separated
        // strings followed by an additional empty NUL terminator. argc is
        // explicit; envp is autocounted by walking until the trailing '\0'.
        let argv0 = b"ish-supervisor\0\0";
        let argv = b"ish-supervisor\0\0";
        let envp = b"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0\
                     HOME=/root\0\
                     GODEBUG=asyncpreemptoff=1\0\
                     GOMAXPROCS=2\0\
                     GOROOT=/usr/lib/go\0\
                     OPENSSL_armcap=0\0\
                     NO_COLOR=1\0\
                     PIP_PROGRESS_BAR=off\0\
                     PYTHONMALLOC=malloc\0\
                     PYTHONDONTWRITEBYTECODE=1\0\
                     JSC_numberOfGCMarkers=1\0\
                     JSC_useConcurrentGC=0\0\0";
        let path_c = CString::new(SUPERVISOR_PATH_IN_ROOTFS).unwrap();
        let rc = unsafe {
            ffi::ish_ffi_execve(
                path_c.as_ptr(),
                1,
                argv.as_ptr() as *const _,
                1,
                envp.as_ptr() as *const _,
            )
        };
        // Suppress unused warning: argv0 is a placeholder for the
        // "supervisor's argv[0]" — currently identical to argv[0]; kept
        // separate so we can override later if the supervisor wants to
        // examine its self-name.
        let _ = argv0;
        if rc < 0 {
            return Err(IshError::KernelCall { call: "execve", rc });
        }

        // 9. Hand control to the kernel pthread.
        let rc = unsafe { ffi::ish_ffi_task_start() };
        if rc < 0 {
            return Err(IshError::KernelCall {
                call: "task_start",
                rc,
            });
        }

        // 10. Now that the kernel is running, set up the writer/reader
        //     threads + the shared instance state, then read the READY
        //     frame to confirm the supervisor is alive and version-locked.
        let (writer_tx, writer_rx) = std::sync::mpsc::channel::<HostToSupervisor>();
        // The writer thread takes ownership of the host's write end. No dup
        // — iSH's emulator shares the host's real-fd table, and adding
        // extra dups created confusing failures during the macOS host smoke.
        let host_stdin_w_for_writer = host_stdin_w;

        let inner = Arc::new(InstanceInner {
            next_reqid: AtomicU32::new(1),
            sessions: Mutex::new(HashMap::new()),
            writer_tx,
            poisoned: AtomicBool::new(false),
            kernel_exit,
        });
        let _ = GLOBAL_INSTANCE.set(Arc::downgrade(&inner));

        // Spawn writer thread.
        thread::Builder::new()
            .name("ish-writer".into())
            .spawn(move || writer_loop(host_stdin_w_for_writer, writer_rx))
            .map_err(IshError::Io)?;

        // Now read READY synchronously on the main thread BEFORE handing
        // the host_stdout_r off to the reader thread.
        let mut reader_pipe = OwnedFdReader::new(host_stdout_r);
        let ready: Option<SupervisorToHost> = read_frame(&mut reader_pipe)?;
        match ready {
            Some(SupervisorToHost::Ready { protocol_version })
                if protocol_version == PROTOCOL_VERSION => {}
            Some(SupervisorToHost::Ready { protocol_version }) => {
                return Err(IshError::ProtocolMismatch {
                    host: PROTOCOL_VERSION,
                    supervisor: protocol_version,
                });
            }
            Some(SupervisorToHost::Err { msg, .. }) => {
                return Err(IshError::Supervisor(msg));
            }
            Some(other) => {
                return Err(IshError::Supervisor(format!(
                    "unexpected first frame: {other:?}"
                )));
            }
            None => return Err(IshError::SupervisorExited),
        }

        // Spawn reader thread.
        let reader_inner = Arc::clone(&inner);
        thread::Builder::new()
            .name("ish-reader".into())
            .spawn(move || reader_loop(reader_pipe, reader_inner))
            .map_err(IshError::Io)?;

        Ok(IshInstance { inner })
    }

    pub fn spawn(&self, opts: SpawnOpts) -> Result<Arc<IshSession>, IshError> {
        let id = self.inner.next_reqid.fetch_add(1, Ordering::Relaxed);
        let session_inner = Arc::new(SessionInner::new(id, Arc::downgrade(&self.inner)));
        {
            let mut t = self.inner.sessions.lock();
            t.insert(id, Arc::downgrade(&session_inner));
        }
        self.inner.send_frame(HostToSupervisor::Open {
            reqid: id,
            opts: opts.into_wire(),
        })?;
        Ok(Arc::new(IshSession::from_inner_arc(session_inner)))
    }

    pub fn spawn_pty(
        &self,
        argv: &[String],
        env: &HashMap<String, String>,
        cwd: &Path,
        size: PtySize,
    ) -> Result<Arc<IshSession>, IshError> {
        self.spawn(SpawnOpts {
            argv: argv.to_vec(),
            envp: Some(
                env.iter()
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect(),
            ),
            cwd: Some(cwd.to_path_buf()),
            tty: true,
            size: Some(size),
            pipe_stdin: false,
            arg0: None,
        })
    }

    /// Drop-in for `codex_core::exec::set_ios_exec_hook`'s sync signature.
    pub fn run_oneshot(
        &self,
        argv: &[String],
        cwd: &Path,
        env: &std::collections::HashMap<String, String>,
        timeout_ms: Option<u64>,
    ) -> (i32, Vec<u8>) {
        self.run_oneshot_streaming(argv, cwd, env, timeout_ms, |_| {})
    }

    pub fn run_oneshot_streaming<F>(
        &self,
        argv: &[String],
        cwd: &Path,
        env: &std::collections::HashMap<String, String>,
        timeout_ms: Option<u64>,
        mut on_output: F,
    ) -> (i32, Vec<u8>)
    where
        F: FnMut(&[u8]),
    {
        // Build a small dedicated current-thread runtime so we can be
        // called from non-tokio threads (which is how the iOS exec hook
        // is invoked from codex-core).
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => return (-1, format!("runtime: {e}\n").into_bytes()),
        };
        rt.block_on(async {
            let opts = SpawnOpts {
                argv: argv.to_vec(),
                envp: Some(env.iter().map(|(k, v)| (k.clone(), v.clone())).collect()),
                cwd: Some(cwd.to_path_buf()),
                tty: false,
                size: None,
                pipe_stdin: false,
                arg0: None,
            };
            let session = match self.spawn(opts) {
                Ok(s) => s,
                Err(e) => return (-1, format!("spawn: {e}\n").into_bytes()),
            };
            drain_to_completion_streaming(&session, timeout_ms, &mut on_output).await
        })
    }

    /// Sends `Shutdown` and waits up to 5 s for the kernel exit hook to
    /// signal completion. Idempotent.
    pub async fn shutdown(self) -> Result<(), IshError> {
        let _ = self.inner.send_frame(HostToSupervisor::Shutdown);
        self.inner.poisoned.store(true, Ordering::Release);
        let exit = Arc::clone(&self.inner.kernel_exit);
        let result = tokio::task::spawn_blocking(move || {
            let mut guard = exit.mtx.lock();
            if guard.is_some() {
                return Ok(());
            }
            let timed_out = exit
                .cv
                .wait_for(&mut guard, Duration::from_secs(5))
                .timed_out();
            if timed_out && guard.is_none() {
                Err(IshError::Supervisor("kernel exit timeout".into()))
            } else {
                Ok(())
            }
        })
        .await
        .unwrap_or_else(|e| Err(IshError::Supervisor(format!("shutdown join: {e}"))));
        result
    }
}

// ---------------------------------------------------------------------------
// Internal: writer/reader threads
// ---------------------------------------------------------------------------

fn writer_loop(fd: OwnedFd, rx: std::sync::mpsc::Receiver<HostToSupervisor>) {
    let trace = std::env::var_os("ISH_TRACE_FRAMES").is_some();
    let mut writer = OwnedFdWriter::new(fd);
    loop {
        let frame = match rx.recv() {
            Ok(f) => f,
            Err(e) => {
                if trace {
                    eprintln!("[ish-out] writer rx closed: {e}");
                }
                break;
            }
        };
        if trace {
            eprintln!("[ish-out] {frame:?}");
        }
        if let Err(e) = ish_embed_protocol::write_frame(&mut writer, &frame) {
            if trace {
                eprintln!("[ish-out] writer write_frame error: {e}");
            }
            break;
        }
    }
}

fn reader_loop(mut reader: OwnedFdReader, inner: Arc<InstanceInner>) {
    loop {
        match read_frame::<_, SupervisorToHost>(&mut reader) {
            Ok(Some(frame)) => dispatch(&inner, frame),
            Ok(None) => break,
            Err(_) => break,
        }
    }
    // Reader exit: poison the instance so further sends fail fast.
    inner.poisoned.store(true, Ordering::Release);
    // Wake any session waiters so their reads/writes can observe shutdown.
    let sessions: Vec<Arc<SessionInner>> = inner
        .sessions
        .lock()
        .values()
        .filter_map(|w| w.upgrade())
        .collect();
    for s in sessions {
        s.on_failed("supervisor disconnected".into());
    }
}

fn dispatch(inner: &InstanceInner, frame: SupervisorToHost) {
    if std::env::var_os("ISH_TRACE_FRAMES").is_some() {
        eprintln!("[ish-in] {frame:?}");
    }
    match frame {
        SupervisorToHost::Ready { .. } => {
            // Already consumed during boot. A second Ready is unexpected.
        }
        SupervisorToHost::Opened { reqid, pid } => {
            if let Some(s) = lookup_session(inner, reqid) {
                s.on_opened(pid);
            }
        }
        SupervisorToHost::Output {
            reqid,
            seq,
            stream,
            bytes,
        } => {
            if let Some(s) = lookup_session(inner, reqid) {
                s.on_output(seq, stream.into(), Bytes::from(bytes));
            }
        }
        SupervisorToHost::Exited {
            reqid,
            exit_code,
            term_signal,
        } => {
            if let Some(s) = lookup_session(inner, reqid) {
                s.on_exited(exit_code, term_signal);
            }
        }
        SupervisorToHost::Closed { reqid } => {
            if let Some(s) = lookup_session(inner, reqid) {
                s.on_closed();
            }
            inner.sessions.lock().remove(&reqid);
        }
        SupervisorToHost::Err {
            reqid: Some(reqid),
            msg,
            ..
        } => {
            if let Some(s) = lookup_session(inner, reqid) {
                s.on_failed(msg);
            }
        }
        SupervisorToHost::Err {
            reqid: None, msg, ..
        } => {
            // Instance-level error: poison + fail every session.
            inner.poisoned.store(true, Ordering::Release);
            let sessions: Vec<Arc<SessionInner>> = inner
                .sessions
                .lock()
                .values()
                .filter_map(|w| w.upgrade())
                .collect();
            for s in sessions {
                s.on_failed(msg.clone());
            }
        }
    }
}

fn lookup_session(inner: &InstanceInner, id: SessionId) -> Option<Arc<SessionInner>> {
    inner.sessions.lock().get(&id).and_then(|w| w.upgrade())
}

/// Drain a session until it exits (or `timeout_ms` elapses), returning
/// (exit_code, merged_output_bytes). Used by `run_oneshot`.
async fn drain_to_completion_streaming<F>(
    session: &IshSession,
    timeout_ms: Option<u64>,
    on_output: &mut F,
) -> (i32, Vec<u8>)
where
    F: FnMut(&[u8]),
{
    use tokio::time::Instant;

    let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
    let mut output = Vec::new();
    let mut next_seq: u64 = 0;
    loop {
        let remaining = deadline.map(|d| {
            let now = Instant::now();
            if now >= d {
                Duration::ZERO
            } else {
                d - now
            }
        });
        if remaining == Some(Duration::ZERO) {
            // Timeout hit; ask the supervisor to kill the child and bail.
            let _ = session.terminate().await;
            return (-1, output);
        }
        let wait_ms = remaining.map(|d| d.as_millis() as u64).unwrap_or(60_000);
        let read = match session
            .read(Some(next_seq), Some(64 * 1024), Some(wait_ms))
            .await
        {
            Ok(r) => r,
            Err(e) => {
                output.extend_from_slice(format!("read error: {e}\n").as_bytes());
                return (-1, output);
            }
        };
        for chunk in &read.chunks {
            output.extend_from_slice(&chunk.bytes);
            on_output(&chunk.bytes);
            next_seq = chunk.seq;
        }
        if read.closed {
            return (read.exit_code.unwrap_or(-1), output);
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn make_pipe() -> Result<(OwnedFd, OwnedFd), IshError> {
    let mut fds = [-1i32; 2];
    let rc = unsafe { libc::pipe(fds.as_mut_ptr()) };
    if rc < 0 {
        return Err(IshError::Io(std::io::Error::last_os_error()));
    }
    let r = unsafe { OwnedFd::from_raw_fd(fds[0]) };
    let w = unsafe { OwnedFd::from_raw_fd(fds[1]) };
    Ok((r, w))
}

unsafe extern "C" fn exit_hook_trampoline(code: std::os::raw::c_int) {
    if let Some(weak) = GLOBAL_INSTANCE.get() {
        if let Some(inner) = weak.upgrade() {
            let exit = Arc::clone(&inner.kernel_exit);
            let mut guard = exit.mtx.lock();
            *guard = Some(code as i32);
            exit.cv.notify_all();
        }
    }
}

fn register_exit_hook(_: Arc<KernelExit>) {
    // The trampoline reads global state; the Arc is kept alive on the
    // instance side. We just need to install the trampoline once.
    unsafe {
        ffi::ish_ffi_register_exit_hook(Some(exit_hook_trampoline));
    }
}

// ---------------------------------------------------------------------------
// Tiny std::io::Read/Write adapters for OwnedFd
// ---------------------------------------------------------------------------

pub(crate) struct OwnedFdReader {
    fd: OwnedFd,
}

impl OwnedFdReader {
    fn new(fd: OwnedFd) -> Self {
        Self { fd }
    }
}

impl Read for OwnedFdReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let n = unsafe {
                libc::read(
                    self.fd.as_raw_fd(),
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                )
            };
            if n >= 0 {
                return Ok(n as usize);
            }
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
}

struct OwnedFdWriter {
    fd: OwnedFd,
}

impl OwnedFdWriter {
    fn new(fd: OwnedFd) -> Self {
        Self { fd }
    }
}

impl Write for OwnedFdWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        loop {
            let n = unsafe {
                libc::write(
                    self.fd.as_raw_fd(),
                    buf.as_ptr() as *const libc::c_void,
                    buf.len(),
                )
            };
            if n >= 0 {
                return Ok(n as usize);
            }
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

// IshSession::from_inner_arc helper sits here so we don't have to expose
// SessionInner publicly.
impl IshSession {
    fn from_inner_arc(inner: Arc<SessionInner>) -> IshSession {
        IshSession::from_inner(inner)
    }
}

// Convert Vec<u8> → Bytes is borrowed by dispatch(); we use Bytes::from
// which copies. That's fine for v1; later we can swap in a zero-copy
// Bytes::from_owner pattern.

// IntoRawFd is needed for transferring fds into the kernel's ownership.
use std::os::fd::IntoRawFd;
