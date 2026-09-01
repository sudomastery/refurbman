//! Cross-source consistency checks.
//!
//! Every check here compares two sources that describe the same thing but
//! arrive by different routes. Faking one is easy; faking both consistently is
//! considerably harder, and disagreement between them is the shape tampering
//! usually takes.
//!
//! Checks are phrased so that a pass reads as reassurance. A buyer working
//! through this list should be able to see what was verified, not just what
//! went wrong.

use crate::fact::Value;
use crate::report::{CheckStatus, Consumable, TamperCheck};

fn check(id: &str, title: &str, status: CheckStatus, detail: impl Into<String>) -> TamperCheck {
    TamperCheck {
        id: id.to_owned(),
        title: title.to_owned(),
        status,
        detail: detail.into(),
    }
}

/// Memory the firmware says is installed, against memory the kernel can
/// actually use.
///
/// Firmware reserves a slice for integrated graphics, so a gap of a few hundred
/// megabytes is normal and expected. A gap of gigabytes is a stick that is
/// faulty, badly seated, or absent.
pub fn memory_matches(smbios_bytes: u64, kernel_bytes: Option<u64>) -> TamperCheck {
    const ID: &str = "memory-total";
    const TITLE: &str = "Installed memory matches what the system can see";

    let Some(kernel_bytes) = kernel_bytes else {
        return check(
            ID,
            TITLE,
            CheckStatus::Skipped,
            "The kernel did not report a memory total.",
        );
    };
    if smbios_bytes == 0 {
        return check(
            ID,
            TITLE,
            CheckStatus::Skipped,
            "The per-slot memory detail needs a full scan, so there was nothing to compare against.",
        );
    }

    let gap = smbios_bytes.saturating_sub(kernel_bytes);
    // Two gigabytes is generous. Integrated graphics rarely reserves more than
    // one, so anything past this is a missing stick rather than a reservation.
    if gap > 2 * 1024 * 1024 * 1024 {
        return check(
            ID,
            TITLE,
            CheckStatus::Fail,
            format!(
                "The firmware lists {:.1} GB of memory, but the system can only use {:.1} GB. \
                 A gap this large usually means a faulty stick, one that is not seated properly, \
                 or memory that is not really there.",
                smbios_bytes as f64 / 1e9,
                kernel_bytes as f64 / 1e9
            ),
        );
    }

    check(
        ID,
        TITLE,
        CheckStatus::Pass,
        format!(
            "The firmware lists {:.1} GB and the system can use {:.1} GB. The small difference \
             is memory reserved for built-in graphics, which is normal.",
            smbios_bytes as f64 / 1e9,
            kernel_bytes as f64 / 1e9
        ),
    )
}

/// The processor's own name, against the name the motherboard firmware records.
///
/// These are written at different times by different parties, so they rarely
/// match character for character. The check looks for the same part, not the
/// same string.
pub fn cpu_matches(cpuid_brand: Option<&str>, smbios_version: Option<&str>) -> TamperCheck {
    const ID: &str = "cpu-identity";
    const TITLE: &str = "Processor is the one the motherboard expects";

    let (Some(cpuid), Some(smbios)) = (cpuid_brand, smbios_version) else {
        return check(
            ID,
            TITLE,
            CheckStatus::Skipped,
            "Only one source named the processor, so there was nothing to compare it against.",
        );
    };

    if tokens_agree(cpuid, smbios) {
        return check(
            ID,
            TITLE,
            CheckStatus::Pass,
            format!("Both the processor and the motherboard firmware describe it as {cpuid}."),
        );
    }

    check(
        ID,
        TITLE,
        CheckStatus::Suspicious,
        format!(
            "The processor reports itself as \"{cpuid}\", while the motherboard firmware records \
             \"{smbios}\". These often differ harmlessly, because the firmware string is written \
             when the board is made and is not always updated when a processor is swapped. It is \
             worth knowing if you were told this machine was never opened."
        ),
    )
}

/// Do two processor names describe the same part?
///
/// Compares the distinguishing tokens, the model numbers and series names,
/// rather than requiring an exact match, because "AMD Ryzen 5 5600U with Radeon
/// Graphics" and "AMD Ryzen 5 5600U" are the same chip.
fn tokens_agree(a: &str, b: &str) -> bool {
    let key = |s: &str| -> Vec<String> {
        s.to_ascii_lowercase()
            .split(|c: char| !c.is_ascii_alphanumeric())
            .filter(|t| t.len() > 1)
            .filter(|t| t.chars().any(|c| c.is_ascii_digit()))
            .map(str::to_owned)
            .collect()
    };
    let (ka, kb) = (key(a), key(b));
    if ka.is_empty() || kb.is_empty() {
        // No model numbers to compare, so fall back to a containment test.
        let (la, lb) = (a.to_ascii_lowercase(), b.to_ascii_lowercase());
        return la.contains(&lb) || lb.contains(&la);
    }
    // Every model number one side carries should appear on the other.
    ka.iter().all(|t| kb.contains(t)) || kb.iter().all(|t| ka.contains(t))
}

/// A drive's wear against the hours it claims to have run.
///
/// This is the check the tool exists for. Resetting a used drive's power-on
/// hours is a known trick, and it is detectable because the wear counters are
/// stored separately and are rarely reset at the same time.
pub fn drive_history_consistent(drive: &Consumable) -> Option<TamperCheck> {
    let int = |k: &str| match drive.facts.get(k)?.value {
        Value::Int(v) => Some(v as u64),
        _ => None,
    };
    let hours = int("powerOnHours")?;
    let used = int("lifeUsedPercent")?;

    let id = format!("drive-history-{}", drive.name);
    let title = format!("{}: usage history is consistent", drive.name);

    if hours < 100 && used > 5 {
        return Some(check(
            &id,
            &title,
            CheckStatus::Fail,
            format!(
                "This drive reports only {hours} hours of use but {used}% of its write life \
                 consumed. Wearing a drive that far takes far longer than {hours} hours, so the \
                 usage counters have very likely been reset to make it look newer than it is."
            ),
        ));
    }

    Some(check(
        &id,
        &title,
        CheckStatus::Pass,
        format!(
            "{used}% of its write life used across {hours} hours of running, which is consistent."
        ),
    ))
}

/// Whether this is real hardware at all.
pub fn not_virtual(hypervisor: Option<&str>) -> TamperCheck {
    const ID: &str = "physical-hardware";
    const TITLE: &str = "This is physical hardware";

    match hypervisor {
        Some(v) => check(
            ID,
            TITLE,
            CheckStatus::Fail,
            format!(
                "The processor reports that it is running under virtualisation software ({v}). \
                 Every hardware reading in this report describes what that software chose to \
                 present, not real parts."
            ),
        ),
        None => check(
            ID,
            TITLE,
            CheckStatus::Pass,
            "The processor reports no virtualisation layer, so these readings come from real parts.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fact::device;

    #[test]
    fn graphics_reservation_does_not_trip_the_memory_check() {
        // 8 GB installed, ~7.6 GB usable: the rest is the integrated GPU's.
        let c = memory_matches(8_589_934_592, Some(7_615_680_512));
        assert_eq!(c.status, CheckStatus::Pass);
    }

    #[test]
    fn a_missing_stick_fails_the_memory_check() {
        let c = memory_matches(17_179_869_184, Some(8_589_934_592));
        assert_eq!(c.status, CheckStatus::Fail);
        assert!(c.detail.contains("faulty stick"));
    }

    #[test]
    fn memory_check_is_skipped_rather_than_failed_when_locked() {
        // An unprivileged scan has no per-slot data. That is not a failure.
        assert_eq!(
            memory_matches(0, Some(8_589_934_592)).status,
            CheckStatus::Skipped
        );
        assert_eq!(
            memory_matches(8_589_934_592, None).status,
            CheckStatus::Skipped
        );
    }

    #[test]
    fn the_same_chip_described_two_ways_passes() {
        let c = cpu_matches(
            Some("AMD Ryzen 5 5600U with Radeon Graphics"),
            Some("AMD Ryzen 5 5600U"),
        );
        assert_eq!(c.status, CheckStatus::Pass);
    }

    #[test]
    fn a_different_chip_is_flagged_as_suspicious_not_failed() {
        // A swapped processor has innocent explanations, so this must not be
        // presented with the same weight as a reset drive counter.
        let c = cpu_matches(Some("Intel Core i3-8100"), Some("Intel Core i7-8700K"));
        assert_eq!(c.status, CheckStatus::Suspicious);
    }

    #[test]
    fn virtual_machines_are_reported_plainly() {
        assert_eq!(not_virtual(Some("KVM")).status, CheckStatus::Fail);
        assert_eq!(not_virtual(None).status, CheckStatus::Pass);
    }

    #[test]
    fn a_reset_drive_counter_fails_the_history_check() {
        let mut d = Consumable::new("storage", "EXAMPLE SSD");
        d.push("powerOnHours", device(12_u64, "test"));
        d.push("lifeUsedPercent", device(40_u64, "test"));
        let c = drive_history_consistent(&d).unwrap();
        assert_eq!(c.status, CheckStatus::Fail);
    }

    #[test]
    fn an_honest_drive_passes_the_history_check() {
        let mut d = Consumable::new("storage", "EXAMPLE SSD");
        d.push("powerOnHours", device(12_000_u64, "test"));
        d.push("lifeUsedPercent", device(40_u64, "test"));
        assert_eq!(
            drive_history_consistent(&d).unwrap().status,
            CheckStatus::Pass
        );
    }

    #[test]
    fn a_drive_that_reported_nothing_yields_no_check_at_all() {
        let d = Consumable::new("storage", "EXAMPLE SSD");
        assert!(drive_history_consistent(&d).is_none());
    }
}
