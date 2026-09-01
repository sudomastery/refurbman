//! Windows readers.
//!
//! Nothing in this file reads the registry. Machine identity comes from
//! `GetSystemFirmwareTable('RSMB')` by way of `smbios-lib`, which is the
//! firmware's own table; the rest comes from documented kernel calls.

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::SystemInformation::GlobalMemoryStatusEx;
use windows::Win32::System::SystemInformation::MEMORYSTATUSEX;

use crate::report::Facts;

/// Whether this process holds an elevated token.
///
/// SMART passthrough needs it. Unlike Linux, the firmware tables themselves do
/// not, so an unelevated Windows scan still identifies the machine fully.
pub fn is_privileged() -> bool {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut token = HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
            return false;
        }
        let mut elevation = TOKEN_ELEVATION::default();
        let mut size = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            Some(&mut elevation as *mut _ as *mut _),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        )
        .is_ok();
        let _ = CloseHandle(token);
        ok && elevation.TokenIsElevated != 0
    }
}

/// Physical memory total as the kernel accounts for it.
///
/// Independent of SMBIOS on purpose: the tamper pass compares the two.
pub fn meminfo_total_bytes() -> Option<u64> {
    unsafe {
        let mut status = MEMORYSTATUSEX {
            dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
            ..Default::default()
        };
        GlobalMemoryStatusEx(&mut status).ok()?;
        Some(status.ullTotalPhys)
    }
}

/// On Windows the full firmware table is readable without elevation, so there
/// is no reduced identity path to fall back to.
pub fn dmi_id_facts() -> Facts {
    Facts::new()
}

/// Kernel build information.
pub fn os_facts() -> Facts {
    use windows::Win32::System::SystemInformation::GetVersion;

    let mut f = Facts::new();
    // GetVersion reports the kernel's own version word. The friendly product
    // name lives in the registry, so it is deliberately not read here.
    let v = unsafe { GetVersion() };
    let major = v & 0xFF;
    let minor = (v >> 8) & 0xFF;
    let build = if v < 0x8000_0000 { v >> 16 } else { 0 };
    f.insert(
        "kernel".into(),
        crate::fact::kernel(format!("{major}.{minor}.{build}"), "win32:GetVersion"),
    );
    f
}
