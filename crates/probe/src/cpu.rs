//! Processor identity, straight from the silicon.
//!
//! CPU model is the single most misrepresented item in used-machine listings,
//! because a case sticker costs nothing and most tools repeat whatever string
//! the OS was told. The `CPUID` instruction asks the processor itself, and the
//! answer is baked into the part. That earns [`Trust::Device`], the same rank
//! as a drive answering a SMART command.
//!
//! The one way to lie to `CPUID` is to run under a hypervisor, so we detect
//! that and say so plainly rather than quietly presenting virtual hardware as
//! real.

use raw_cpuid::CpuId;

use crate::fact::{derived, device, kernel};
use crate::report::{Component, Finding};

/// Result of the processor probe.
pub struct Cpu {
    pub component: Component,
    /// Brand string as the silicon reports it, for the tamper cross-check
    /// against what the firmware claims.
    pub cpuid_brand: Option<String>,
    /// Set when a hypervisor is present, which invalidates every hardware
    /// claim on the machine.
    pub hypervisor: Option<String>,
}

pub fn probe() -> Cpu {
    let cpuid = CpuId::new();

    let brand = cpuid
        .get_processor_brand_string()
        .map(|b| b.as_str().trim().to_owned())
        .filter(|s| !s.is_empty());

    let vendor = cpuid
        .get_vendor_info()
        .map(|v| v.as_str().trim().to_owned())
        .filter(|s| !s.is_empty());

    let name = brand
        .clone()
        .or_else(|| vendor.clone())
        .unwrap_or_else(|| "Unknown processor".to_owned());

    let mut c = Component::new("cpu", name);

    if let Some(b) = &brand {
        c.push(
            "model",
            device(b.clone(), "cpuid:leaf 0x80000002-4 brand string"),
        );
    }
    if let Some(v) = &vendor {
        c.push("vendor", device(v.clone(), "cpuid:leaf 0x0 vendor id"));
    }

    let mut hypervisor = None;
    if let Some(fi) = cpuid.get_feature_info() {
        c.push(
            "family",
            device(u64::from(fi.family_id()), "cpuid:leaf 0x1 family"),
        );
        c.push(
            "modelId",
            device(u64::from(fi.model_id()), "cpuid:leaf 0x1 model"),
        );
        c.push(
            "stepping",
            device(u64::from(fi.stepping_id()), "cpuid:leaf 0x1 stepping"),
        );

        if fi.has_hypervisor() {
            let vendor = cpuid
                .get_hypervisor_info()
                .map(|h| format!("{:?}", h.identify()))
                .unwrap_or_else(|| "unidentified".to_owned());
            c.push(
                "hypervisor",
                device(vendor.clone(), "cpuid:leaf 0x1 ecx bit 31"),
            );
            hypervisor = Some(vendor);
        }
    }

    // Core and thread counts come from the kernel's topology view rather than
    // CPUID, because the kernel already accounts for disabled cores and for
    // chips that report their topology across several leaves.
    let (physical, logical) = core_counts();
    if let Some(p) = physical {
        c.push(
            "cores",
            kernel(p, "sysfs:/sys/devices/system/cpu/*/topology/core_id"),
        );
    }
    if let Some(l) = logical {
        c.push(
            "threads",
            kernel(l, "sysfs:/sys/devices/system/cpu/present"),
        );
    }
    if let (Some(p), Some(l)) = (physical, logical) {
        if let Some(ratio) = l.checked_div(p) {
            c.push("threadsPerCore", derived(ratio, "cores and threads above"));
        }
    }

    if let Some(khz) = max_frequency_khz() {
        c.push(
            "maxFrequencyMhz",
            kernel(khz / 1000, "sysfs:cpufreq/cpuinfo_max_freq").unit("MHz"),
        );
    }

    Cpu {
        component: c,
        cpuid_brand: brand,
        hypervisor,
    }
}

/// A finding to show when the machine is virtual.
///
/// This matters more than it looks: inside a VM every reading below is the
/// hypervisor's invention, so the tool must not imply it has inspected real
/// hardware.
pub fn hypervisor_finding(vendor: &str) -> Finding {
    Finding::critical(
        "This is a virtual machine, not physical hardware",
        "The processor reports that it is running under virtualisation software. \
         Everything else in this report describes what that software chose to \
         present, not real parts. If you were expecting to be testing a physical \
         computer, stop and check what you are connected to.",
    )
    .evidence(format!("CPUID hypervisor bit set, reported as {vendor}"))
}

#[cfg(target_os = "linux")]
fn core_counts() -> (Option<u64>, Option<u64>) {
    use std::collections::BTreeSet;

    let base = std::path::Path::new("/sys/devices/system/cpu");
    let Ok(entries) = std::fs::read_dir(base) else {
        return (None, None);
    };

    // A physical core is a unique (package, core) pair. Counting distinct
    // core_id alone would merge cores that share an id across sockets.
    let mut seen: BTreeSet<(String, String)> = BTreeSet::new();
    let mut logical = 0u64;

    for e in entries.flatten() {
        let name = e.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("cpu") || !name[3..].chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        if name.len() == 3 {
            continue;
        }
        logical += 1;
        let topo = e.path().join("topology");
        let pkg = crate::platform::linux::read_trimmed(topo.join("physical_package_id"));
        let core = crate::platform::linux::read_trimmed(topo.join("core_id"));
        if let (Some(p), Some(c)) = (pkg, core) {
            seen.insert((p, c));
        }
    }

    let physical = if seen.is_empty() {
        None
    } else {
        Some(seen.len() as u64)
    };
    (physical, if logical == 0 { None } else { Some(logical) })
}

#[cfg(target_os = "windows")]
fn core_counts() -> (Option<u64>, Option<u64>) {
    // GetLogicalProcessorInformationEx walks the kernel's own topology table.
    // sysinfo wraps the same call and handles the variable-length buffer.
    let mut sys = sysinfo::System::new();
    sys.refresh_cpu_all();
    let logical = sys.cpus().len() as u64;
    let physical = sysinfo::System::physical_core_count().map(|c| c as u64);
    (physical, if logical == 0 { None } else { Some(logical) })
}

#[cfg(target_os = "linux")]
fn max_frequency_khz() -> Option<u64> {
    crate::platform::linux::read_u64("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
}

#[cfg(target_os = "windows")]
fn max_frequency_khz() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpuid_identifies_this_processor() {
        let cpu = probe();
        // Every x86 part made in the last twenty years supports the brand
        // string leaves, so a blank here means the probe is broken.
        let brand = cpu.cpuid_brand.expect("CPUID should return a brand string");
        assert!(!brand.is_empty());
        assert!(cpu.component.facts.contains_key("vendor"));
    }

    #[test]
    fn topology_is_self_consistent() {
        let cpu = probe();
        let cores = cpu.component.facts.get("cores");
        let threads = cpu.component.facts.get("threads");
        if let (Some(c), Some(t)) = (cores, threads) {
            use crate::fact::Value;
            if let (Value::Int(c), Value::Int(t)) = (&c.value, &t.value) {
                assert!(c > &0 && t > &0);
                // Threads cannot be fewer than physical cores.
                assert!(t >= c, "threads {t} < cores {c}");
            }
        }
    }
}
