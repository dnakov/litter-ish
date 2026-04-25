# `embed/` — async Rust embedding API for iSH

This directory turns iSH into a Rust crate (`ish-embed-host`) that other Rust code links directly. The crate boots iSH's kernel, runs a small PID-1 supervisor inside it, and exposes an async API for spawning long-lived processes, reading their output incrementally, writing to their stdin, and signaling/terminating them. It is shaped to plug into [`codex-rs`](../) — both the legacy `codex_core::exec::set_ios_exec_hook` flow and `app-server`'s `ExecBackend` / `ExecProcess` trait.

## Architecture

```
host process
├── ish-embed-host        async Rust API; FFIs into iSH C kernel libs
│   └── reader thread     reads framed responses from supervisor pipe
│   └── writer thread     writes framed requests to supervisor pipe
│
iSH kernel pthread
└── PID 1 = ish-supervisor          static i386 musl ELF, ~411 KB
    ├── poll(2) loop
    │   ├── stdin (request frames from host)
    │   ├── SIGCHLD self-pipe (reap children)
    │   └── per-session output fds (drain stdout/stderr/pty master)
    └── child processes               one fork+execve per session
        ├── /bin/sh -c "<cmd>"         own pgid, own stdio, own state
        ├── /bin/cat (with pipe_stdin) host writes to its stdin
        └── ...
```

Each session is a separate `fork+execve` child of the supervisor, with its own process group. Cancelling sends `SIGKILL` to the pgid. Output is multiplexed back to the host with monotonic per-session `seq` numbers, matching `codex_exec_server::ProcessOutputChunk`'s shape.

## Crates

| Crate | Role |
|---|---|
| `protocol/`  | `#![no_std] + alloc` postcard-encoded wire types shared by host and supervisor. `PROTOCOL_VERSION` is checked at handshake; mismatched binaries fail loudly. |
| `supervisor/`| The PID-1 ELF. Static-linked i686 musl, no async runtime, single-threaded `poll(2)` loop. |
| `host/`      | The async public API (`IshInstance`, `IshSession`, …). `build.rs` drives Meson + Ninja for the iSH C side and cross-builds the supervisor. |

## Public API surface

```rust
let ish = IshInstance::boot(rootfs_path, Some(Path::new("/")))?;

let session = ish.spawn(SpawnOpts::cmd(["/bin/echo", "hello"]))?;
let read = session.read(Some(0), Some(64 * 1024), Some(2_000)).await?;
//          ^^ codex's ReadParams { after_seq, max_bytes, wait_ms } shape

session.write(b"some-stdin-bytes").await?;
session.signal(libc::SIGINT).await?;
session.terminate().await?;     // SIGKILL pgid

// Codex `set_ios_exec_hook` drop-in:
let (exit_code, output) = ish.run_oneshot(&argv, &cwd, &env, Some(timeout_ms));
```

`IshSession::subscribe()` returns a `tokio::sync::broadcast::Receiver<SessionEvent>` for push-style consumption (`Opened` / `Output` / `Exited` / `Closed` / `Failed`), 1:1 with codex's `ExecProcessEvent`.

## Build prerequisites

- Rust toolchain with the `i686-unknown-linux-musl` target installed (`rustup target add i686-unknown-linux-musl`). The supervisor cross-builds via `rust-lld`, which ships with rustup, so no host C cross-toolchain is needed.
- Meson + Ninja (`brew install meson ninja` on macOS, apt on Linux).
- LLVM's `clang` and `lld` for iSH's vdso step (`brew install llvm` on macOS — see `vdso/meson.build`).
- A fakefs rootfs for testing. For dev builds the existing one at `<repo>/build/alpine-fakefs` works; production consumers ship `fs.tar.gz` produced by `build-rootfs.sh`.

## Tests

```bash
# Unit tests (build pipeline + protocol roundtrips)
cargo test -p ish-embed-protocol
cargo test -p ish-embed-host --lib

# End-to-end against an existing rootfs (echo, exit codes, stdin pipe,
# concurrent sessions, cancel via SIGKILL)
ISH_TEST_ROOTFS=$PWD/../build/alpine-fakefs/data \
    cargo test -p ish-embed-host --test smoke -- --test-threads=1
```

Set `ISH_TRACE_FRAMES=1` to dump every host↔supervisor frame to stderr.

## Wire protocol summary

| Direction        | Op       | Payload |
|------------------|----------|---------|
| host → super     | `Open`   | `reqid`, `SpawnOpts { argv, envp, cwd, tty, pipe_stdin, arg0 }` |
| host → super     | `Write`  | `reqid`, `bytes` |
| host → super     | `Signal` | `reqid`, `signum` |
| host → super     | `Term`   | `reqid` (= `SIGKILL` pgid + reap) |
| host → super     | `Shutdown` | (kills all sessions, supervisor `_exit(0)` → iSH `halt_system`) |
| super → host     | `Ready`  | `protocol_version` |
| super → host     | `Opened` | `reqid`, `pid` |
| super → host     | `Output` | `reqid`, `seq`, `stream`, `bytes` |
| super → host     | `Exited` | `reqid`, `exit_code`, `term_signal` |
| super → host     | `Closed` | `reqid` (final event for a session) |
| super → host     | `Err`    | optional `reqid`, `code`, `msg` |

Frames are length-prefixed (`u32` LE) postcard-encoded enums.

## Why a separate i386 supervisor

iSH is an x86 emulator. Its PID 1's mm is loaded by `do_execve` and its execution is the emulator loop, so init's "code" must be i386 ELF that runs under the emulator — host code can't *be* PID 1. Forking from outside an iSH task is unsafe (the kernel's `fork` copies `current`'s state, which only the emulator's pthread has set up). So the supervisor is a minimal static binary built by Cargo (`cargo build --release --target i686-unknown-linux-musl`) and embedded into the host crate via `include_bytes!`. At boot the host crate writes it to `/sbin/ish-supervisor` inside the fakefs through the kernel's own `generic_open()`, so fakefs metadata is registered correctly. Production rootfs builds may bake the supervisor in at fakefsify time; the runtime path is the dev-mode fallback.
