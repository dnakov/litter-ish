//! End-to-end smoke for the iSH embed library.
//!
//! Booting iSH mutates process-global kernel state and is single-instance
//! per process, so all integration tests live in this single binary and
//! run sequentially. They share one IshInstance, set up by `boot()` below.
//!
//! Set the env var `ISH_TEST_ROOTFS` to point at a fakefs (e.g. the dev
//! rootfs at `<repo>/build/alpine-fakefs`). If unset, tests skip with a
//! clear message rather than failing — they're not part of `cargo test`'s
//! default run.
//!
//! Run with:
//!     ISH_TEST_ROOTFS=$PWD/build/alpine-fakefs \
//!         cargo test -p ish-embed-host --test smoke -- --test-threads=1 --nocapture

use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

use ish_embed_host::{IshInstance, SpawnOpts};

static INSTANCE: OnceLock<&'static IshInstance> = OnceLock::new();

/// Return a leaked `&'static IshInstance`. We deliberately leak it for the
/// duration of the test process — iSH's kernel state is process-global, so
/// once you boot you can't really shut down and reboot in the same run.
fn shared_instance() -> Option<&'static IshInstance> {
    if let Some(inst) = INSTANCE.get() {
        return Some(inst);
    }
    let rootfs = std::env::var_os("ISH_TEST_ROOTFS")?;
    let rootfs = PathBuf::from(rootfs);
    let inst = match IshInstance::boot(&rootfs, Some(std::path::Path::new("/"))) {
        Ok(inst) => Box::leak(Box::new(inst)) as &'static IshInstance,
        Err(e) => {
            eprintln!("ISH_TEST_ROOTFS={}: boot failed: {e}", rootfs.display());
            return None;
        }
    };
    let _ = INSTANCE.set(inst);
    INSTANCE.get().copied()
}

macro_rules! ish_test {
    ($name:ident, |$ish:ident| $body:block) => {
        #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
        async fn $name() {
            let Some($ish) = shared_instance() else {
                eprintln!("ISH_TEST_ROOTFS not set; skipping {}", stringify!($name));
                return;
            };
            $body
        }
    };
}

ish_test!(echo_hello, |ish| {
    let session = ish
        .spawn(SpawnOpts::cmd(["/bin/echo", "hello"]))
        .expect("spawn");
    let (code, output) = drain(&session, 2_000).await;
    assert_eq!(
        code,
        Some(0),
        "echo should exit 0; got output={:?}",
        String::from_utf8_lossy(&output)
    );
    assert!(
        String::from_utf8_lossy(&output).contains("hello"),
        "expected 'hello' in output, got: {:?}",
        String::from_utf8_lossy(&output),
    );
});

ish_test!(procfs_is_mounted, |ish| {
    let session = ish
        .spawn(SpawnOpts::cmd([
            "/bin/sh",
            "-lc",
            "test -r /proc/mounts && \
             grep -q '^proc /proc proc ' /proc/mounts && \
             test -r /proc/self/stat && \
             test -r /proc/self/cmdline && \
             test -n \"$(readlink /proc/self/exe)\" && \
             ls /proc/self/fd >/dev/null",
        ]))
        .expect("spawn");
    let (code, output) = drain(&session, 2_000).await;
    assert_eq!(
        code,
        Some(0),
        "procfs smoke should exit 0; got output={:?}",
        String::from_utf8_lossy(&output),
    );
});

ish_test!(stdout_streams_before_exit, |ish| {
    let session = ish
        .spawn(SpawnOpts::cmd([
            "/bin/sh",
            "-lc",
            "/bin/echo first; sleep 2; /bin/echo second",
        ]))
        .expect("spawn");

    let first = session
        .read(Some(0), Some(64 * 1024), Some(1_500))
        .await
        .expect("read first chunk");
    let first_text: String = first
        .chunks
        .iter()
        .flat_map(|c| c.bytes.iter().copied())
        .map(|b| b as char)
        .collect();
    assert!(
        first_text.contains("first"),
        "expected first chunk before exit, got {first_text:?}"
    );
    assert!(
        !first.closed,
        "session should still be open after first streamed chunk"
    );

    let (code, output) = drain(&session, 4_000).await;
    let text = String::from_utf8_lossy(&output);
    assert_eq!(code, Some(0), "stream smoke failed, output={text:?}");
    assert!(
        text.contains("second"),
        "expected final chunk, got {text:?}"
    );
});

/// Read until the session is fully drained or `total_ms` elapses. Returns
/// (exit_code, merged_bytes).
async fn drain(session: &ish_embed_host::IshSession, total_ms: u64) -> (Option<i32>, Vec<u8>) {
    let deadline = std::time::Instant::now() + Duration::from_millis(total_ms);
    let mut next_seq = 0u64;
    let mut out = Vec::new();
    loop {
        let now = std::time::Instant::now();
        let remaining = if now >= deadline {
            0
        } else {
            (deadline - now).as_millis() as u64
        };
        let r = session
            .read(Some(next_seq), Some(64 * 1024), Some(remaining))
            .await
            .expect("read");
        for c in &r.chunks {
            out.extend_from_slice(&c.bytes);
            next_seq = c.seq;
        }
        if r.closed {
            return (r.exit_code, out);
        }
        if remaining == 0 {
            return (r.exit_code, out);
        }
    }
}

ish_test!(false_returns_nonzero, |ish| {
    let session = ish.spawn(SpawnOpts::cmd(["/bin/false"])).expect("spawn");
    // Drain to completion.
    let mut next_seq: u64 = 0;
    let mut out = Vec::new();
    let exit_code = loop {
        let r = session
            .read(Some(next_seq), Some(64 * 1024), Some(2_000))
            .await
            .expect("read");
        for c in &r.chunks {
            out.extend_from_slice(&c.bytes);
            next_seq = c.seq;
        }
        if r.exited && r.chunks.is_empty() {
            break r.exit_code.unwrap_or(-1);
        }
        if r.closed {
            break r.exit_code.unwrap_or(-1);
        }
    };
    assert_eq!(
        exit_code,
        1,
        "false should exit 1, output={:?}",
        String::from_utf8_lossy(&out)
    );
});

ish_test!(stdin_pipe_roundtrip, |ish| {
    let session = ish
        .spawn(SpawnOpts {
            argv: vec!["/bin/cat".into()],
            envp: None,
            cwd: None,
            tty: false,
            pipe_stdin: true,
            arg0: None,
        })
        .expect("spawn");
    // Wait for Opened so write isn't returned as Starting.
    let _ = session.read(Some(0), Some(0), Some(500)).await;
    session.write(b"ping\n").await.expect("write");
    // Close stdin so cat exits — currently no API for that; fall back to
    // sending SIGTERM after a moment.
    tokio::time::sleep(Duration::from_millis(200)).await;
    session.terminate().await.expect("terminate");
    let r = session
        .read(Some(0), Some(64 * 1024), Some(2_000))
        .await
        .expect("read");
    let combined: String = r
        .chunks
        .iter()
        .flat_map(|c| c.bytes.iter().copied())
        .map(|b| b as char)
        .collect();
    assert!(
        combined.contains("ping"),
        "expected 'ping' in output, got: {combined:?}"
    );
});

ish_test!(concurrent_three_sessions, |ish| {
    use std::time::Instant;
    let start = Instant::now();
    let mut handles = Vec::new();
    for i in 0..3 {
        let s = ish
            .spawn(SpawnOpts::cmd(["/bin/sh", "-c", "sleep 1; echo done $$"]))
            .unwrap_or_else(|e| panic!("spawn #{i}: {e}"));
        handles.push(s);
    }
    let mut codes = Vec::new();
    for s in handles {
        let mut next_seq: u64 = 0;
        let code = loop {
            let r = s
                .read(Some(next_seq), Some(64 * 1024), Some(3_000))
                .await
                .expect("read");
            for c in &r.chunks {
                next_seq = c.seq;
            }
            if r.exited && r.chunks.is_empty() {
                break r.exit_code;
            }
            if r.closed {
                break r.exit_code;
            }
        };
        codes.push(code);
    }
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_secs(2),
        "wall time {:?} not concurrent enough",
        elapsed
    );
    assert!(
        codes.iter().all(|c| *c == Some(0)),
        "all should exit 0; got {codes:?}"
    );
});

ish_test!(cancel_hung_command, |ish| {
    let s = ish
        .spawn(SpawnOpts::cmd([
            "/bin/sh",
            "-c",
            "while :; do sleep 1; done",
        ]))
        .expect("spawn");
    // Let it start.
    let _ = s.read(Some(0), Some(0), Some(300)).await;
    let start = std::time::Instant::now();
    s.terminate().await.expect("terminate");
    // Wait for Exited.
    let r = s
        .read(Some(0), Some(64 * 1024), Some(2_000))
        .await
        .expect("read after terminate");
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(r.exited, "should be exited");
    // SIGKILL = 9.
    assert_eq!(r.term_signal, Some(9), "should be killed by SIGKILL");
});
