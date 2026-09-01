//! Linux readers: sysfs and procfs.

use std::fs;
use std::path::Path;

use crate::fact::{firmware, kernel};
use crate::report::Facts;

/// Root is needed for the raw DMI table and for SMART passthrough.
pub fn is_privileged() -> bool {
    // Safe: `geteuid` takes no arguments and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

/// Read a sysfs file, trimmed, empty treated as absent.
pub fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    let v = fs::read_to_string(path).ok()?;
    let t = v.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_owned())
    }
}

pub fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_trimmed(path)?.parse().ok()
}

/// SMBIOS chassis type, mapped to the words a buyer would use.
///
/// Worth surfacing because it is an easy mismatch to spot: a listing that says
/// "laptop" against a chassis type of 3 (desktop) is a repackaged machine.
pub fn chassis_name(code: u64) -> Option<&'static str> {
    Some(match code {
        3 => "Desktop",
        4 => "Low profile desktop",
        5 => "Pizza box",
        6 => "Mini tower",
        7 => "Tower",
        8 => "Portable",
        9 => "Laptop",
        10 => "Notebook",
        11 => "Hand held",
        13 => "All in one",
        14 => "Sub notebook",
        15 => "Space saving",
        16 => "Lunch box",
        17 => "Main server chassis",
        23 => "Rack mount chassis",
        24 => "Sealed case PC",
        30 => "Tablet",
        31 => "Convertible",
        32 => "Detachable",
        _ => return None,
    })
}

/// Machine identity from `/sys/class/dmi/id`, the unprivileged fallback for
/// when the raw SMBIOS table cannot be opened.
///
/// The kernel exports these fields individually and applies its own permissions:
/// make, model and BIOS are world-readable, while serials and the system UUID
/// are root-only. So an ordinary user still gets enough to identify the machine,
/// and only the identifying serials need the unlock prompt. These values come
/// from the same firmware tables, so they keep firmware rank.
pub fn dmi_id_facts() -> Facts {
    const BASE: &str = "/sys/class/dmi/id";
    let mut f = Facts::new();

    let mut put = |key: &str, file: &str| {
        if let Some(v) = read_trimmed(format!("{BASE}/{file}")) {
            let cleaned = crate::smbios::clean_public(&v);
            if let Some(v) = cleaned {
                f.insert(key.to_owned(), firmware(v, format!("sysfs:{BASE}/{file}")));
            }
        }
    };

    put("manufacturer", "sys_vendor");
    put("model", "product_name");
    put("version", "product_version");
    put("family", "product_family");
    put("sku", "product_sku");
    put("boardVendor", "board_vendor");
    put("boardModel", "board_name");
    put("biosVendor", "bios_vendor");
    put("biosVersion", "bios_version");
    put("biosDate", "bios_date");
    put("serialNumber", "product_serial");
    put("boardSerial", "board_serial");

    if let Some(code) = read_u64(format!("{BASE}/chassis_type")) {
        if let Some(name) = chassis_name(code) {
            f.insert(
                "chassis".into(),
                firmware(name, format!("sysfs:{BASE}/chassis_type")),
            );
        }
    }

    f
}

/// Total usable RAM as the kernel itself accounts for it.
///
/// Deliberately independent of SMBIOS: the tamper pass compares the two, and a
/// board claiming sticks the kernel cannot see is a strong signal.
pub fn meminfo_total_bytes() -> Option<u64> {
    let text = fs::read_to_string("/proc/meminfo").ok()?;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            let kb: u64 = rest.trim().trim_end_matches(" kB").trim().parse().ok()?;
            return Some(kb * 1024);
        }
    }
    None
}

/// Kernel release and the distribution's own name.
pub fn os_facts() -> Facts {
    let mut f = Facts::new();

    if let Some(v) = read_trimmed("/proc/sys/kernel/osrelease") {
        f.insert("kernel".into(), kernel(v, "procfs:/proc/sys/kernel/osrelease"));
    }
    // The distribution name is an editable text file, so it is ranked as
    // software and never used to back a hardware claim.
    if let Ok(text) = fs::read_to_string("/etc/os-release") {
        for line in text.lines() {
            if let Some(v) = line.strip_prefix("PRETTY_NAME=") {
                let v = v.trim_matches('"');
                f.insert(
                    "distribution".into(),
                    crate::fact::software(v, "file:/etc/os-release"),
                );
            }
        }
    }
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chassis_codes_map_to_plain_words() {
        assert_eq!(chassis_name(10), Some("Notebook"));
        assert_eq!(chassis_name(3), Some("Desktop"));
        assert_eq!(chassis_name(200), None);
    }

    #[test]
    fn meminfo_total_is_plausible_on_this_host() {
        // Any Linux host running the test suite has a MemTotal, and it is
        // certainly more than 128MB and less than 8TB.
        let bytes = meminfo_total_bytes().expect("MemTotal should be readable");
        assert!(bytes > 128 * 1024 * 1024, "suspiciously small: {bytes}");
        assert!(bytes < 8 * 1024_u64.pow(4), "suspiciously large: {bytes}");
    }

    #[test]
    fn dmi_identity_is_readable_without_privileges() {
        // The whole degraded path rests on this being true on a normal Linux
        // desktop: make and model without a password prompt.
        let f = dmi_id_facts();
        assert!(
            f.contains_key("manufacturer") || f.contains_key("model"),
            "expected some machine identity from /sys/class/dmi/id"
        );
    }
}
