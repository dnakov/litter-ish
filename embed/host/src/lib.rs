//! `ish-embed-host` — async Rust API for embedding the iSH kernel and
//! driving in-iSH processes.
//!
//! Quick start:
//! ```ignore
//! let ish = IshInstance::boot(Path::new("/path/to/fakefs"), None)?;
//! let session = ish.spawn(SpawnOpts::cmd(["/bin/echo", "hello"]))?;
//! let read = session.read(Some(0), Some(64 * 1024), Some(2_000)).await?;
//! ```

pub mod ffi {
    #![allow(non_camel_case_types)]
    #![allow(non_snake_case)]
    #![allow(non_upper_case_globals)]
    #![allow(dead_code)]
    include!(concat!(env!("OUT_DIR"), "/ffi.rs"));
}

mod error;
mod instance;
mod session;

pub use error::IshError;
pub use instance::{IshInstance, SpawnOpts};
pub use session::{
    IshSession, OutputChunk, ReadOutput, SessionEvent, SessionId, Stream, WriteStatus,
};

/// The PID-1 supervisor binary, statically linked as AArch64 musl ELF and
/// embedded into this crate.
pub static SUPERVISOR_ELF: &[u8] = include_bytes!(env!("ISH_SUPERVISOR_BIN"));

#[cfg(test)]
mod build_smoke {
    use super::*;

    #[test]
    fn supervisor_binary_is_an_aarch64_elf() {
        assert!(SUPERVISOR_ELF.len() > 1024);
        assert_eq!(&SUPERVISOR_ELF[..4], b"\x7fELF");
        assert_eq!(SUPERVISOR_ELF[4], 2);
        assert_eq!(SUPERVISOR_ELF[5], 1);
        assert_eq!(SUPERVISOR_ELF[18], 183);
        assert_eq!(SUPERVISOR_ELF[19], 0);
    }
}
