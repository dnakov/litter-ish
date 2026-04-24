# Embedding iSH as a library

This directory turns iSH from a standalone terminal app into a library that another iOS app can call to run shell commands. The library and rootfs are produced as two artifacts you vendor into the consuming app.

## Artifacts

After running the build scripts you get, in `<ish>/build/`:

| Artifact | Purpose | Size |
|---|---|---|
| `codex_ish.xcframework` | Static library + headers. Slices: `ios-arm64`, `ios-arm64_x86_64-simulator`. Link this into your iOS target. | ~1-2 MB per slice |
| `alpine-fakefs/` | A pre-built fakefsified Alpine i386 rootfs (a `data/` dir plus `meta.db`). Consumer bundles this (or the tarball below) and copies it to a writable sandbox path at first launch. `ish_init` is pointed at `<sandbox>/alpine-fakefs/data`. | ~8 MB unpacked |
| `alpine-fakefs.tar.gz` | Same content as a tarball, for consumers that prefer to ship a compressed blob and extract on first launch. | ~3 MB |

## Building

Build prereqs (one-time, macOS host):
- Xcode Command Line Tools
- `brew install meson ninja llvm lld libarchive sqlite`

Then:

```sh
./embed/build-xcframework.sh   # → build/codex_ish.xcframework
./embed/build-rootfs.sh        # → build/alpine-fakefs[.tar.gz]
```

Override `ALPINE_VERSION` to pin a different minirootfs (default `3.19.1`).

## Public API

```c
#include "ish_embed.h"

// One-time boot. Mounts the fakefs at `rootfs_path` (must end in .../data),
// becomes init (PID 1), and execves /bin/sh on a dedicated kernel thread.
// At most one instance per process lifetime.
ish_instance_t *ish_init(const char *rootfs_path, const char *workdir);

// Run a shell command. stdout + stderr are merged.
int ish_run(ish_instance_t *ish,
            const char *cmd,
            const uint8_t *stdin_bytes, size_t stdin_len,
            uint8_t **out_bytes, size_t *out_len,
            int *exit_code);

// Run argv-style (no shell word-splitting). envp is NULL-terminated
// "KEY=VALUE" strings; pass NULL for the default environment.
int ish_exec(ish_instance_t *ish,
             const char *const *argv,
             const char *const *envp,
             const uint8_t *stdin_bytes, size_t stdin_len,
             uint8_t **out_bytes, size_t *out_len,
             int *exit_code);

void ish_free(void *p);
void ish_shutdown(ish_instance_t *ish);
```

Return codes: `ISH_OK` (0) on success, negative `ISH_E_*` values on failure (see header).

## Integration sketch (Swift/SwiftUI)

```swift
import CodexISH  // from the xcframework's module.modulemap

// 1. First-launch: copy the bundled rootfs directory into a writable location.
let fm = FileManager.default
let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true)
let rootfsDest = caches.appendingPathComponent("alpine-fakefs")
if !fm.fileExists(atPath: rootfsDest.path) {
    let src = Bundle.main.url(forResource: "alpine-fakefs", withExtension: nil)!
    try fm.copyItem(at: src, to: rootfsDest)
}

// 2. Boot the kernel. Pass the .../data subdir.
let dataPath = rootfsDest.appendingPathComponent("data").path
guard let ish = ish_init(dataPath, "/") else { fatalError("ish_init failed") }

// 3. Run a command.
var outBytes: UnsafeMutablePointer<UInt8>? = nil
var outLen: Int = 0
var exitCode: Int32 = 0
let rc = ish_run(ish, "uname -a", nil, 0, &outBytes, &outLen, &exitCode)
defer { if let p = outBytes { ish_free(p) } }
```

## Constraints and gotchas

- **One instance per process, permanently.** iSH's kernel uses `__thread current` and other per-process globals. After `ish_shutdown` the process should not call `ish_init` again.
- **Serialized API.** `ish_run` and `ish_exec` are mutex-guarded — concurrent callers serialize. This matches the kernel's single-scheduler assumption; don't try to work around it.
- **Architecture: i386 emulation.** All commands run through a threaded-code x86 interpreter. Expect 10–100× slower than equivalent native ARM code. Measure before committing to a heavy per-command workload.
- **stdout and stderr are merged** into a single output buffer.
- **Pre-set environment on the inner shell.** `HOME`, `PATH`, `USER`, `SHELL`, `TERM=dumb` are set at boot. Additional per-call env comes from `ish_exec`'s `envp`.
- **Writable rootfs.** `meta.db` is SQLite and is mutated when the emulated filesystem changes. Ship a writable copy, not a read-only bundle path.
- **apk add Just Works.** You can install extra Alpine packages at runtime via `ish_run(ish, "apk add --no-cache <pkg>", ...)`, network permitting.

## Host-side smoke test

`embed/tests/smoke_host.c` is a macOS host harness that links the library directly (no xcframework) and runs `echo`/`false`/`grep +stdin`/`ish_exec`/back-to-back/`ish_shutdown`. Run it after any change:

```sh
meson setup build-host
cd build-host
PATH=/opt/homebrew/opt/llvm/bin:$PATH ninja embed/smoke_host
../embed/build-rootfs.sh   # one-time; produces build/alpine-fakefs/
./embed/smoke_host ../build/alpine-fakefs/data
```

## Licensing

iSH is GPLv3 with the App-Store additional permission in `LICENSE.IOS`. Any app that links `codex_ish.xcframework` becomes a derivative work and must itself be GPL-compatible (source disclosure to end users, license text shipped). See the repo root `LICENSE.md`.
