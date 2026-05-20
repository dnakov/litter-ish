//! Build script for `ish-embed-host`.
//!
//! Three jobs:
//! 1. Drive Meson + Ninja to build iSH's existing C static libs
//!    (`libish`, `libish_emu`, `libfakefs`) so we can link them.
//! 2. Compile the small C shim at `embed/ffi.c` and run bindgen over
//!    `embed/ffi.h` so the Rust crate has typed access to the kernel calls
//!    it needs.
//! 3. Cross-build the in-iSH supervisor binary for `aarch64-unknown-linux-musl`
//!    and embed it as a `.rodata` blob so the host crate is self-contained
//!    (no separate file to ship).
//!
//! Everything happens against the iSH source tree at `<crate>/../..`. The
//! build is currently scoped to the macOS host triple and macOS-on-ARM
//! Apple Silicon dev boxes — iOS cross-build wiring lives in the same
//! pattern but reuses the existing `embed/cross/*.txt` Meson cross-files
//! and is added once host builds are green end-to-end.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let ish_root = crate_dir
        .parent() // embed/
        .expect("embed/")
        .parent() // ish/
        .expect("ish/")
        .to_path_buf();
    let embed_dir = ish_root.join("embed");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));

    // -- 1. iSH static libs via Meson ---------------------------------------
    let meson_build_dir = out_dir.join("meson-build");
    let target = env::var("TARGET").unwrap_or_default();
    let cross_file = maybe_write_cross_file(&out_dir, &target);
    run_meson(&ish_root, &meson_build_dir, cross_file.as_deref());

    println!(
        "cargo:rustc-link-search=native={}",
        meson_build_dir.display()
    );
    // Meson outputs libish.a in the build root; libish_emu.a, libfakefs.a in
    // their respective subdirs. Add all three to the link search path.
    println!(
        "cargo:rustc-link-search=native={}",
        meson_build_dir.display()
    );
    println!("cargo:rustc-link-lib=static=ish");
    println!("cargo:rustc-link-lib=static=ish_emu");
    println!("cargo:rustc-link-lib=static=fakefs");
    println!("cargo:rustc-link-lib=sqlite3");

    // macOS frameworks pulled in by iSH's host shims (NSLog etc.)
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if matches!(target_os.as_str(), "macos" | "ios") {
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    }

    // -- 2. C shim + bindgen -----------------------------------------------
    let ffi_c = embed_dir.join("ffi.c");
    let ffi_h = embed_dir.join("ffi.h");
    println!("cargo:rerun-if-changed={}", ffi_c.display());
    println!("cargo:rerun-if-changed={}", ffi_h.display());

    cc::Build::new()
        .file(&ffi_c)
        .include(&ish_root)
        .include(&embed_dir)
        .define("GUEST_ARM64", "1")
        .flag_if_supported("-std=gnu11")
        .flag_if_supported("-Wno-implicit-function-declaration")
        .compile("ish_embed_ffi");

    // bindgen runs only over ffi.h, *not* the iSH kernel headers, on
    // purpose. The iSH headers are full of macros and `struct task *`-style
    // opaque pointers that don't roundtrip cleanly through bindgen, and we
    // don't need them — the shim hides everything.
    let bindings = bindgen::Builder::default()
        .header(ffi_h.to_string_lossy().to_string())
        .clang_arg(format!("-I{}", ish_root.display()))
        .clang_arg(format!("-I{}", embed_dir.display()))
        .clang_arg("-DGUEST_ARM64=1")
        .allowlist_function("ish_ffi_.*")
        .allowlist_type("ish_ffi_.*")
        .generate_comments(true)
        .layout_tests(false)
        .generate()
        .expect("bindgen");

    let bindings_out = out_dir.join("ffi.rs");
    bindings
        .write_to_file(&bindings_out)
        .expect("write bindings");

    // -- 3. Supervisor cross-build -----------------------------------------
    let supervisor_src = embed_dir.join("supervisor");
    let protocol_src = embed_dir.join("protocol");
    emit_rerun_if_changed_recursive(&supervisor_src);
    // The supervisor binary is `include_bytes!`d into host. The supervisor
    // depends on `embed/protocol` via a path dep; if PROTOCOL_VERSION (or
    // any other protocol source) changes but supervisor's own tree doesn't,
    // Cargo would skip rerunning this build script and ship a stale binary
    // against a newer host crate — surfacing as `supervisor protocol
    // mismatch (host N, supervisor N-1)` at runtime. Watch protocol too.
    emit_rerun_if_changed_recursive(&protocol_src);
    let supervisor_bin = build_supervisor(&supervisor_src, &out_dir);

    // Stash the binary under a stable name in OUT_DIR; lib.rs will
    // include_bytes! against it.
    let staged = out_dir.join("ish-supervisor.bin");
    std::fs::copy(&supervisor_bin, &staged)
        .unwrap_or_else(|e| panic!("copy supervisor.bin {}: {e}", supervisor_bin.display()));
    println!("cargo:rustc-env=ISH_SUPERVISOR_BIN={}", staged.display());
}

fn emit_rerun_if_changed_recursive(path: &Path) {
    println!("cargo:rerun-if-changed={}", path.display());
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let child = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            emit_rerun_if_changed_recursive(&child);
        } else if file_type.is_file() {
            println!("cargo:rerun-if-changed={}", child.display());
        }
    }
}

fn run_meson(ish_root: &Path, build_dir: &Path, cross_file: Option<&Path>) {
    let configured_marker = build_dir.join("build.ninja");
    if !configured_marker.exists() {
        std::fs::create_dir_all(build_dir).unwrap();
        let mut cmd = Command::new("meson");
        cmd.arg("setup")
            .arg("--buildtype=release")
            .arg("--default-library=static");
        if let Some(cf) = cross_file {
            cmd.arg("--cross-file").arg(cf);
        }
        cmd.arg(build_dir).arg(ish_root);
        // The parent cargo build may have set CC/CFLAGS to target the
        // outer Rust target (e.g. aarch64-apple-ios). Meson reads CC for
        // the build_machine probe — leaving an iOS-targeted compiler
        // there triggers "Executables created by c compiler … are not
        // runnable." Clear the wrapper/compiler vars and let Meson
        // rediscover the host toolchain. Our `[binaries]` section in the
        // cross-file already pins the iOS-side compilers explicitly.
        for var in [
            "CC",
            "CXX",
            "AR",
            "RANLIB",
            "OBJC",
            "STRIP",
            "CFLAGS",
            "CXXFLAGS",
            "LDFLAGS",
            "OBJCFLAGS",
            "RUSTC_WRAPPER",
            "CARGO_BUILD_RUSTC_WRAPPER",
        ] {
            cmd.env_remove(var);
        }
        let status = cmd
            .status()
            .expect("invoke meson — install via `brew install meson ninja`");
        if !status.success() {
            panic!("meson setup failed (status {status})");
        }
    }
    let status = Command::new("ninja")
        .arg("-C")
        .arg(build_dir)
        .arg("libish.a")
        .arg("libish_emu.a")
        .arg("libfakefs.a")
        .status()
        .expect("invoke ninja");
    if !status.success() {
        panic!("ninja build failed");
    }
}

/// For Apple-cross targets (iOS device, iOS simulators), write a Meson cross
/// file that points at Xcode's clang with the right SDK + arch flags. Returns
/// the path to the cross-file, or `None` for native builds (Meson autodetects
/// the host toolchain just fine).
fn maybe_write_cross_file(out_dir: &Path, target: &str) -> Option<PathBuf> {
    let (sdk_platform, sdk_name, arch, min_flag, system, cpu_family, is_simulator) = match target {
        "aarch64-apple-ios" => (
            "iPhoneOS",
            "iPhoneOS",
            "arm64",
            "-mios-version-min=16.0",
            "darwin",
            "aarch64",
            false,
        ),
        "aarch64-apple-ios-sim" => (
            "iPhoneSimulator",
            "iPhoneSimulator",
            "arm64",
            "-mios-simulator-version-min=16.0",
            "darwin",
            "aarch64",
            true,
        ),
        "x86_64-apple-ios" => (
            "iPhoneSimulator",
            "iPhoneSimulator",
            "x86_64",
            "-mios-simulator-version-min=16.0",
            "darwin",
            "x86_64",
            true,
        ),
        // Host macs: no cross-file needed.
        _ => return None,
    };
    let _ = sdk_name;
    let _ = is_simulator;

    let xcode_select = Command::new("xcode-select").arg("-p").output();
    let developer_dir = match xcode_select {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "/Applications/Xcode.app/Contents/Developer".to_string(),
    };

    let sdk = format!(
        "{developer_dir}/Platforms/{sdk_platform}.platform/Developer/SDKs/{sdk_platform}.sdk"
    );
    let xctool = format!("{developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin");

    let body = format!(
        "[constants]\n\
         sdk = '{sdk}'\n\
         xctool = '{xctool}'\n\
         arch = '-arch'\n\
         cpu = '{arch}'\n\
         min = '{min_flag}'\n\
         \n\
         [binaries]\n\
         c    = [xctool + '/clang', '-isysroot', sdk, arch, cpu, min]\n\
         objc = [xctool + '/clang', '-isysroot', sdk, arch, cpu, min]\n\
         ar   = xctool + '/ar'\n\
         strip = xctool + '/strip'\n\
         \n\
         [built-in options]\n\
         c_link_args = ['-isysroot', sdk, '-arch', '{arch}', '{min_flag}']\n\
         \n\
         [project options]\n\
         apple_ui = true\n\
         \n\
         [host_machine]\n\
         system = '{system}'\n\
         cpu_family = '{cpu_family}'\n\
         cpu = '{cpu_family}'\n\
         endian = 'little'\n",
    );

    let cf = out_dir.join("meson-cross.ini");
    std::fs::write(&cf, body).expect("write meson cross file");
    Some(cf)
}

fn build_supervisor(supervisor_src: &Path, out_dir: &Path) -> PathBuf {
    let target_dir = out_dir.join("supervisor-target");
    // Use a separate target dir to avoid Cargo's parent-build lock.
    let status = Command::new("cargo")
        // Spawn a child cargo for the supervisor crate. Forward the user's
        // toolchain and PATH but explicitly clear vars cargo populates for
        // the parent build that would confuse the inner one.
        .env_remove("CARGO")
        .env_remove("CARGO_MANIFEST_DIR")
        .env_remove("RUSTC_WRAPPER")
        .env_remove("RUSTC")
        .env_remove("CARGO_ENCODED_RUSTFLAGS")
        .args([
            "build",
            "--profile",
            "supervisor",
            "--target",
            "aarch64-unknown-linux-musl",
            "--target-dir",
        ])
        .arg(&target_dir)
        .current_dir(supervisor_src)
        .status()
        .expect("cargo build supervisor");
    if !status.success() {
        panic!("supervisor cross-build failed");
    }
    target_dir
        .join("aarch64-unknown-linux-musl")
        .join("supervisor")
        .join("ish-supervisor")
}
