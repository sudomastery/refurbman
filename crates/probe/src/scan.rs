//! Assembling one complete scan.
//!
//! Every probe is run, failures are recorded rather than hidden, and the trust
//! summary is computed last from the facts that actually landed. A section that
//! is empty because it was locked must never look the same as a section that is
//! empty because the machine has nothing in it.

use crate::fact::{derived, kernel, software};
use crate::report::{CheckStatus, Component, Facts, Report, TrustSummary};
use crate::{battery, cpu, platform, report, smbios, storage, tamper, VERSION};

pub fn run() -> Report {
    let privileged = platform::is_privileged();
    let mut errors: Vec<String> = Vec::new();

    // --- firmware and identity ---
    let fw = smbios::probe();
    if let Some(note) = &fw.degraded {
        errors.push(note.clone());
    }
    let mut system: Facts = fw.system.clone();

    // --- processor ---
    let processor = cpu::probe();

    // --- memory ---
    let kernel_mem = platform::host::meminfo_total_bytes();
    if let Some(b) = kernel_mem {
        system.insert(
            "memoryUsableBytes".into(),
            kernel(b, memory_source()).unit("bytes"),
        );
        system.insert(
            "memoryUsable".into(),
            derived(format!("{:.1} GB", b as f64 / 1e9), memory_source()),
        );
    }
    if fw.memory_total_bytes > 0 {
        system.insert(
            "memoryInstalledBytes".into(),
            crate::fact::firmware(fw.memory_total_bytes, "smbios:type17 sum").unit("bytes"),
        );
    }

    // --- operating system ---
    for (k, v) in platform::host::os_facts() {
        system.insert(k, v);
    }
    system.insert("toolVersion".into(), software(VERSION, "refurbman"));

    // --- components ---
    let mut components: Vec<Component> = vec![processor.component.clone()];
    components.extend(fw.memory_slots.clone());

    // --- consumables ---
    let store = storage::probe();
    errors.extend(store.errors.clone());
    if let Some(v) = &store.smartctl_version {
        system.insert(
            "smartctlVersion".into(),
            software(v.clone(), "smartctl --version"),
        );
    }
    for (k, v) in storage::summary_facts(&store.drives) {
        system.insert(k, v);
    }

    let mut consumables = store.drives.clone();
    consumables.extend(battery::probe());

    // --- findings ---
    let mut findings: Vec<report::Finding> = Vec::new();
    if let Some(v) = &processor.hypervisor {
        findings.push(cpu::hypervisor_finding(v));
    }
    if !privileged {
        findings.push(report::Finding::info(
            "A full check needs administrator rights",
            unlock_advice(),
        ));
    }
    // Every consumable's own findings roll up into the report, so the summary
    // view can show them without walking the tree.
    for c in &consumables {
        findings.extend(c.findings.iter().cloned());
    }

    // --- consistency checks ---
    let mut tamper_checks = vec![
        tamper::not_virtual(processor.hypervisor.as_deref()),
        tamper::memory_matches(fw.memory_total_bytes, kernel_mem),
        tamper::cpu_matches(processor.cpuid_brand.as_deref(), fw.cpu_version.as_deref()),
    ];
    for d in &consumables {
        if d.kind == "storage" {
            if let Some(c) = tamper::drive_history_consistent(d) {
                tamper_checks.push(c);
            }
        }
    }

    let mut r = Report {
        generated_at: now_rfc3339(),
        tool_version: VERSION.to_owned(),
        platform: std::env::consts::OS.to_owned(),
        privileged,
        system,
        components,
        consumables,
        findings,
        tamper_checks,
        trust: TrustSummary {
            total_facts: 0,
            tamper_resistant_facts: 0,
            tamper_resistant_percent: 0.0,
            full_access: privileged,
        },
        errors,
    };
    r.recompute_trust();
    r
}

fn memory_source() -> &'static str {
    if cfg!(target_os = "linux") {
        "procfs:/proc/meminfo MemTotal"
    } else {
        "win32:GlobalMemoryStatusEx"
    }
}

fn unlock_advice() -> String {
    if cfg!(target_os = "windows") {
        "This scan ran without administrator rights, so the drives could not be asked about \
         their own condition. Everything else is complete. Close this, right click PowerShell \
         or the RefurbMan icon, choose \"Run as administrator\", and scan again."
            .to_owned()
    } else {
        "This scan ran as an ordinary user, so the drives could not be asked about their own \
         condition and the memory slot breakdown is missing. Everything else is complete. Run \
         the scan again with sudo to see the rest."
            .to_owned()
    }
}

/// How many consistency checks actually ran and passed.
pub fn check_tally(r: &Report) -> (usize, usize, usize) {
    let mut passed = 0;
    let mut failed = 0;
    let mut skipped = 0;
    for c in &r.tamper_checks {
        match c.status {
            CheckStatus::Pass => passed += 1,
            CheckStatus::Fail | CheckStatus::Suspicious => failed += 1,
            CheckStatus::Skipped => skipped += 1,
        }
    }
    (passed, failed, skipped)
}

/// UTC timestamp in RFC 3339, without pulling in a date library for one line.
fn now_rfc3339() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;

    let days = secs.div_euclid(86_400);
    let tod = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

/// Days since the Unix epoch to a calendar date, by Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_and_a_known_date_convert_correctly() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        // 2026-09-01 is 20697 days after the epoch.
        assert_eq!(civil_from_days(20_697), (2026, 9, 1));
        // A leap day, to catch an off-by-one in the era arithmetic.
        assert_eq!(civil_from_days(19_782), (2024, 2, 29));
    }

    #[test]
    fn the_timestamp_is_well_formed() {
        let t = now_rfc3339();
        assert_eq!(t.len(), 20, "unexpected timestamp: {t}");
        assert!(t.ends_with('Z'));
        assert!(t.contains('T'));
        // Sanity: this code was written well after 2025 and will not run before.
        assert!(t.starts_with("202") || t.starts_with("203"));
    }

    #[test]
    fn a_scan_of_this_machine_produces_a_usable_report() {
        let r = run();
        assert!(!r.generated_at.is_empty());
        assert_eq!(r.tool_version, VERSION);
        assert!(!r.components.is_empty(), "expected at least a processor");
        assert!(
            r.trust.total_facts > 0,
            "a scan with no facts is a broken scan"
        );

        // The core promise: every fact carries the place it came from.
        for (key, f) in r.all_facts() {
            assert!(!f.source.is_empty(), "fact {key} has no source");
        }

        // The checks must actually run rather than all being skipped. Note
        // that "passed" is the wrong thing to assert on: continuous
        // integration runs inside a virtual machine, where the physical
        // hardware check correctly fails.
        let (passed, failed, skipped) = check_tally(&r);
        assert!(
            !r.tamper_checks.is_empty(),
            "no consistency checks were built"
        );
        assert!(
            passed + failed > 0,
            "every consistency check was skipped ({skipped} skipped)"
        );
    }
}
