//! Per-OS readers.
//!
//! Each platform module exposes the same shape, so the probes above stay free
//! of `cfg` noise. A platform that cannot answer returns empty rather than
//! erroring, because a partial report is the normal case: most scans run
//! without privileges the first time.

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use linux as host;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as host;

/// Whether this process can talk to devices and read the full firmware tables.
pub fn is_privileged() -> bool {
    host::is_privileged()
}
