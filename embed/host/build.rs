//! Build script for `ish-embed-host`.
//!
//! Three jobs:
//! 1. Drive Meson + Ninja to build iSH's existing C static libs
//!    (`libish`, `libish_emu`, `libfakefs`) so we can link them.
//! 2. Compile the small C shim at `embed/ffi.c` and run bindgen over
//!    `embed/ffi.h` so the Rust crate has typed access to the seven kernel
//!    calls it needs.
//! 3. Cross-build the in-iSH supervisor binary for `i686-unknown-linux-musl`
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
    run_meson(&ish_root, &meson_build_dir);

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
    println!("cargo:rerun-if-changed={}", supervisor_src.display());
    let supervisor_bin = build_supervisor(&supervisor_src, &out_dir);

    // Stash the binary under a stable name in OUT_DIR; lib.rs will
    // include_bytes! against it.
    let staged = out_dir.join("ish-supervisor.bin");
    std::fs::copy(&supervisor_bin, &staged)
        .unwrap_or_else(|e| panic!("copy supervisor.bin {}: {e}", supervisor_bin.display()));
    println!("cargo:rustc-env=ISH_SUPERVISOR_BIN={}", staged.display());
}

fn run_meson(ish_root: &Path, build_dir: &Path) {
    let configured_marker = build_dir.join("build.ninja");
    if !configured_marker.exists() {
        std::fs::create_dir_all(build_dir).unwrap();
        let status = Command::new("meson")
            .arg("setup")
            .arg("--buildtype=release")
            .arg("--default-library=static")
            .arg(build_dir)
            .arg(ish_root)
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
            "i686-unknown-linux-musl",
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
        .join("i686-unknown-linux-musl")
        .join("supervisor")
        .join("ish-supervisor")
}
