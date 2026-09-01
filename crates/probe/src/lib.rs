//! RefurbMan probe engine.
//!
//! Reads a machine's hardware and its wear state from sources a seller cannot
//! casually edit: the kernel, the firmware tables, and the devices themselves.
//! Nothing here reads the Windows registry, and nothing trusts a driver-supplied
//! marketing string for a hardware claim.
//!
//! The engine has no GUI dependencies, so it builds and runs headlessly. The
//! Tauri shell and the `refurbman-probe` CLI are both thin callers of
//! [`scan`].

pub mod battery;
pub mod cpu;
pub mod fact;
pub mod platform;
pub mod report;
pub mod scan;
pub mod smart;
pub mod smbios;
pub mod storage;
pub mod tamper;

pub use fact::{Fact, Trust, Value};
pub use report::{Component, Consumable, Finding, Report, Verdict};

/// Semantic version of the engine, stamped into every report.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
