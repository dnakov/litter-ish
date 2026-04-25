use thiserror::Error;

#[derive(Debug, Error)]
pub enum IshError {
    #[error("iSH already initialised in this process")]
    AlreadyInitialised,
    #[error("rootfs path is invalid")]
    InvalidRootfs,
    #[error("kernel call {call:?} failed (rc {rc})")]
    KernelCall { call: &'static str, rc: i32 },
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("encoding error: {0}")]
    Encoding(String),
    #[error("decoding error: {0:?}")]
    Decoding(ish_embed_protocol::FrameError),
    #[error("supervisor protocol mismatch (host {host}, supervisor {supervisor})")]
    ProtocolMismatch { host: u32, supervisor: u32 },
    #[error("supervisor exited unexpectedly")]
    SupervisorExited,
    #[error("session {id} not found")]
    UnknownSession { id: u32 },
    #[error("instance is shutting down")]
    ShuttingDown,
    #[error("supervisor reported error: {0}")]
    Supervisor(String),
}

impl From<ish_embed_protocol::FrameError> for IshError {
    fn from(e: ish_embed_protocol::FrameError) -> Self {
        IshError::Decoding(e)
    }
}
