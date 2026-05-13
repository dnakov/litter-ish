//! Opt-in acceptance coverage for the embedded ARM64 runtime.
//!
//! This test installs large guest toolchains, so it is deliberately gated by
//! `ISH_ACCEPTANCE_ROOTFS` and is not part of the default host crate smoke.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ish_embed_host::{IshInstance, IshSession, SpawnOpts};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn modern_cli_toolchain_smoke() {
    let Some(rootfs) = std::env::var_os("ISH_ACCEPTANCE_ROOTFS") else {
        eprintln!("ISH_ACCEPTANCE_ROOTFS not set; skipping modern_cli_toolchain_smoke");
        return;
    };
    let rootfs = PathBuf::from(rootfs);
    let ish = IshInstance::boot(&rootfs, Some(Path::new("/")))
        .unwrap_or_else(|e| panic!("boot {}: {e}", rootfs.display()));

    run_ok(
        &ish,
        "shell",
        "test -x /bin/sh && /bin/sh -lc 'echo shell-ok' | grep -qx shell-ok",
        10,
    )
    .await;

    run_ok(
        &ish,
        "apk setup",
        "test -f /etc/resolv.conf || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; \
         sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; \
         apk update",
        180,
    )
    .await;

    run_ok(
        &ish,
        "toolchain install",
        "apk add --no-cache python3 nodejs npm go rust cargo",
        1_200,
    )
    .await;

    run_ok(&ish, "python3", "python3 --version", 30).await;
    run_ok(&ish, "node", "node --version", 30).await;
    run_ok(&ish, "npm", "npm --version", 30).await;
    run_ok(
        &ish,
        "go",
        "env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin go version",
        60,
    )
    .await;
    run_ok(
        &ish,
        "cargo",
        r#"rm -rf /tmp/ish-acceptance-rust &&
           mkdir -p /tmp/ish-acceptance-rust/src &&
           cd /tmp/ish-acceptance-rust &&
           cat > Cargo.toml <<'EOF'
[package]
name = "ish_acceptance"
version = "0.1.0"
edition = "2021"
EOF
           cat > src/main.rs <<'EOF'
fn main() {
    println!("rust-cargo-ok");
}
EOF
           cargo run --quiet | grep -qx rust-cargo-ok"#,
        300,
    )
    .await;
}

async fn run_ok(ish: &IshInstance, label: &str, cmd: &str, timeout_secs: u64) {
    let session = ish
        .spawn(SpawnOpts::cmd(["/bin/sh", "-lc", cmd]))
        .unwrap_or_else(|e| panic!("{label}: spawn: {e}"));
    let result = drain(&session, Duration::from_secs(timeout_secs)).await;
    if !result.closed {
        let _ = session.terminate().await;
        panic!(
            "{label}: timed out after {timeout_secs}s\n{}",
            result.output
        );
    }
    assert_eq!(
        result.exit_code,
        Some(0),
        "{label}: expected exit 0, got {:?}\n{}",
        result.exit_code,
        result.output
    );
}

struct DrainResult {
    exit_code: Option<i32>,
    output: String,
    closed: bool,
}

async fn drain(session: &IshSession, timeout: Duration) -> DrainResult {
    let deadline = Instant::now() + timeout;
    let mut next_seq = 0u64;
    let mut out = Vec::new();
    loop {
        let now = Instant::now();
        if now >= deadline {
            return DrainResult {
                exit_code: None,
                output: String::from_utf8_lossy(&out).into_owned(),
                closed: false,
            };
        }
        let wait_ms = (deadline - now).as_millis().min(1_000) as u64;
        let read = session
            .read(Some(next_seq), Some(64 * 1024), Some(wait_ms))
            .await
            .expect("read");
        for chunk in &read.chunks {
            out.extend_from_slice(&chunk.bytes);
            next_seq = chunk.seq;
        }
        if read.closed {
            return DrainResult {
                exit_code: read.exit_code,
                output: String::from_utf8_lossy(&out).into_owned(),
                closed: true,
            };
        }
    }
}
