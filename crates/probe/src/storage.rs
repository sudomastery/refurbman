//! Drives: identity from the kernel, health from the drive.
//!
//! The two are deliberately kept separate. The kernel can always tell us a
//! drive exists and how big it claims to be, even for an unprivileged scan.
//! Only the health questions need to reach the device, so a locked scan still
//! shows the machine's storage rather than an empty section.

use crate::fact::derived;
use crate::report::{human_bytes, Consumable, Facts};
use crate::smart::{parse, Smartctl};

pub struct Storage {
    pub drives: Vec<Consumable>,
    pub errors: Vec<String>,
    /// Version string of the smartctl that produced the health data, recorded
    /// so a reader can reproduce the same numbers.
    pub smartctl_version: Option<String>,
}

pub fn probe() -> Storage {
    let mut out = Storage {
        drives: Vec::new(),
        errors: Vec::new(),
        smartctl_version: None,
    };

    let kernel_view = kernel_drives();

    let Some(smart) = Smartctl::locate() else {
        out.errors.push(
            "smartctl was not found, so drive health could not be read. Install smartmontools \
             to see how much life the drives have left."
                .to_owned(),
        );
        out.drives = kernel_view.into_iter().map(|(_, c)| c).collect();
        return out;
    };
    out.smartctl_version = smart.version();

    let devices = match smart.scan() {
        Ok(d) => d,
        Err(e) => {
            out.errors.push(format!("Could not list drives: {e}"));
            out.drives = kernel_view.into_iter().map(|(_, c)| c).collect();
            return out;
        }
    };

    for dev in &devices {
        let mut consumable = if let Some(reason) = &dev.open_error {
            parse::locked(dev, reason)
        } else {
            match smart.inspect(dev) {
                Ok(json) => parse::drive(&json, &dev.name),
                Err(e) => {
                    out.errors.push(format!("Could not read {}: {e}", dev.name));
                    parse::locked(dev, &e.to_string())
                }
            }
        };

        // Fill gaps from the kernel's own view. A locked drive gets its size
        // and model this way, which is most of what a buyer wants to see.
        if let Some((_, kc)) = kernel_view
            .iter()
            .find(|(node, _)| same_device(node, &dev.name))
        {
            for (k, v) in &kc.facts {
                consumable
                    .facts
                    .entry(k.clone())
                    .or_insert_with(|| v.clone());
            }
            if consumable.name.starts_with("/dev/") && !kc.name.starts_with("/dev/") {
                consumable.name = kc.name.clone();
            }
        }
        out.drives.push(consumable);
    }

    // A drive the kernel can see but smartctl never listed still belongs in the
    // report. Leaving it out would understate what is in the machine.
    for (node, c) in kernel_view {
        if !out.drives.iter().any(|d| {
            d.facts.get("device").map(|f| &f.value) == c.facts.get("device").map(|f| &f.value)
        }) && !devices.iter().any(|d| same_device(&node, &d.name))
        {
            out.drives.push(c);
        }
    }

    out
}

/// smartctl addresses NVMe controllers as `/dev/nvme0` while the kernel names
/// the namespace `/dev/nvme0n1`. Match on the controller prefix so the two
/// views line up.
fn same_device(kernel_node: &str, smart_name: &str) -> bool {
    if kernel_node == smart_name {
        return true;
    }
    kernel_node.starts_with(smart_name) || smart_name.starts_with(kernel_node)
}

#[cfg(target_os = "linux")]
fn kernel_drives() -> Vec<(String, Consumable)> {
    use crate::fact::kernel;
    use crate::platform::linux::{read_trimmed, read_u64};
    use crate::report::Verdict;

    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/block") else {
        return out;
    };

    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();

    for name in names {
        // Virtual devices are not hardware anyone is buying.
        if name.starts_with("loop")
            || name.starts_with("ram")
            || name.starts_with("zram")
            || name.starts_with("dm-")
            || name.starts_with("md")
            || name.starts_with("sr")
        {
            continue;
        }
        let dir = format!("/sys/block/{name}");
        let node = format!("/dev/{name}");

        let model = read_trimmed(format!("{dir}/device/model"))
            .or_else(|| read_trimmed(format!("{dir}/device/device/model")));

        let mut c = Consumable::new("storage", model.clone().unwrap_or_else(|| name.clone()));
        c.verdict = Verdict::Unknown;
        c.push("device", kernel(node.clone(), format!("sysfs:{dir}")));
        if let Some(m) = model {
            c.push("model", kernel(m, format!("sysfs:{dir}/device/model")));
        }
        // sysfs reports size in 512-byte sectors regardless of the drive's own
        // logical block size.
        if let Some(sectors) = read_u64(format!("{dir}/size")) {
            let bytes = sectors.saturating_mul(512);
            c.push(
                "capacityBytes",
                kernel(bytes, format!("sysfs:{dir}/size")).unit("bytes"),
            );
            c.push(
                "capacity",
                derived(human_bytes(bytes), format!("sysfs:{dir}/size")),
            );
        }
        match read_trimmed(format!("{dir}/queue/rotational")).as_deref() {
            Some("0") => c.push(
                "kind",
                kernel("Solid state", format!("sysfs:{dir}/queue/rotational")),
            ),
            Some("1") => c.push(
                "kind",
                kernel("Hard disk", format!("sysfs:{dir}/queue/rotational")),
            ),
            _ => {}
        }
        if read_trimmed(format!("{dir}/removable")).as_deref() == Some("1") {
            c.push("removable", kernel(true, format!("sysfs:{dir}/removable")));
        }
        out.push((node, c));
    }
    out
}

#[cfg(not(target_os = "linux"))]
fn kernel_drives() -> Vec<(String, Consumable)> {
    // On Windows smartctl enumerates the physical drives itself, and does so
    // without needing a second source for identity.
    Vec::new()
}

/// Total storage across every drive found, for the summary line.
pub fn total_bytes(drives: &[Consumable]) -> u64 {
    drives
        .iter()
        .filter_map(|d| match d.facts.get("capacityBytes")?.value {
            crate::fact::Value::Int(v) if v > 0 => Some(v as u64),
            _ => None,
        })
        .sum()
}

/// Facts about the storage subsystem as a whole.
pub fn summary_facts(drives: &[Consumable]) -> Facts {
    let mut f = Facts::new();
    let total = total_bytes(drives);
    if total > 0 {
        f.insert(
            "storageTotal".into(),
            derived(human_bytes(total), "sum of every drive"),
        );
    }
    f.insert(
        "driveCount".into(),
        derived(drives.len() as u64, "drives found"),
    );
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nvme_controller_and_namespace_are_the_same_device() {
        // smartctl says /dev/nvme0, the kernel says /dev/nvme0n1.
        assert!(same_device("/dev/nvme0n1", "/dev/nvme0"));
        assert!(same_device("/dev/sda", "/dev/sda"));
        assert!(!same_device("/dev/sda", "/dev/sdb"));
    }

    #[test]
    fn capacities_are_rendered_at_the_scale_people_use() {
        assert_eq!(human_bytes(512_110_190_592), "512 GB");
        assert_eq!(human_bytes(1_000_204_886_016), "1.0 TB");
        assert_eq!(human_bytes(0), "0 B");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn this_machine_has_at_least_one_real_drive() {
        // Any machine running the tests boots from something, and it must not
        // be reported as a loop or zram device.
        let drives = kernel_drives();
        assert!(!drives.is_empty(), "no physical block devices found");
        for (node, _) in &drives {
            assert!(!node.contains("loop") && !node.contains("zram"));
        }
    }
}
