//! The shape of a completed scan.
//!
//! One `Report` is what the UI renders, what the CLI prints, and what the
//! export writes to disk. Keeping a single shape means the JSON a buyer saves
//! is exactly what they saw on screen.

use serde::Serialize;
use std::collections::BTreeMap;

use crate::fact::{Fact, Trust};

/// Plain-language health outcome.
///
/// Deliberately only four states, so each maps to exactly one colour and one
/// sentence. A five point scale would invite hedging, and the audience needs a
/// call, not a gradient.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Good,
    Fair,
    Poor,
    /// The part could not be read, usually for want of privileges. Distinct
    /// from `Poor`: absence of evidence is never reported as bad news.
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Info,
    Warn,
    Critical,
}

/// Something the buyer should know, written in words they will understand.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    pub severity: Severity,
    pub title: String,
    /// Full sentences aimed at a buyer, not an administrator.
    pub detail: String,
    /// The raw reading behind the claim, so the finding can be checked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evidence: Option<String>,
}

impl Finding {
    pub fn new(severity: Severity, title: impl Into<String>, detail: impl Into<String>) -> Self {
        Finding {
            severity,
            title: title.into(),
            detail: detail.into(),
            evidence: None,
        }
    }

    pub fn info(title: impl Into<String>, detail: impl Into<String>) -> Self {
        Self::new(Severity::Info, title, detail)
    }
    pub fn warn(title: impl Into<String>, detail: impl Into<String>) -> Self {
        Self::new(Severity::Warn, title, detail)
    }
    pub fn critical(title: impl Into<String>, detail: impl Into<String>) -> Self {
        Self::new(Severity::Critical, title, detail)
    }

    pub fn evidence(mut self, evidence: impl Into<String>) -> Self {
        self.evidence = Some(evidence.into());
        self
    }
}

/// Which readings a section shows, and in what order.
///
/// Facts are stored alphabetically so exports stay byte-stable, which is the
/// wrong order to read in: it puts "Bytes written 34479896576000" above the
/// drive's remaining life. This list fixes the order and, just as importantly,
/// leaves things out. A stepping number, a raw byte count that already has a
/// readable twin, and a spare-block threshold are all noise to the person this
/// report is written for. Everything omitted here is still in the JSON export.
///
/// The terminal and the HTML report both read from this, so the two can never
/// disagree about what matters.
pub fn display_fields(kind: &str) -> &'static [(&'static str, &'static str)] {
    match kind {
        "cpu" => &[
            ("model", "Processor"),
            ("vendor", "Made by"),
            ("cores", "Cores"),
            ("threads", "Threads"),
            ("maxFrequencyMhz", "Maximum speed"),
            ("hypervisor", "Virtualised under"),
        ],
        "memory" => &[
            ("size", "Size"),
            ("type", "Type"),
            ("configuredSpeedMts", "Running at"),
            ("manufacturer", "Made by"),
            ("partNumber", "Part number"),
        ],
        "storage" => &[
            ("capacity", "Capacity"),
            ("kind", "Type"),
            ("protocol", "Connection"),
            ("powerOnFor", "Powered on for"),
            ("totalWritten", "Total written"),
            ("lifeUsedPercent", "Life used"),
            ("temperatureC", "Temperature"),
            ("selfAssessment", "Drive self-check"),
            ("reallocatedSectors", "Replaced areas"),
            ("pendingSectors", "Areas it cannot read"),
            ("uncorrectableSectors", "Unrecoverable areas"),
            ("mediaErrors", "Unrecoverable errors"),
            ("powerCycles", "Times switched on"),
            ("firmware", "Firmware"),
        ],
        "battery" => &[
            ("designCapacityWh", "Capacity when new"),
            ("currentCapacityWh", "Capacity now"),
            ("cycleCount", "Charge cycles"),
            ("technology", "Chemistry"),
            ("manufacturer", "Made by"),
            ("chargeNowPercent", "Charged right now"),
            ("status", "Currently"),
        ],
        _ => &[],
    }
}

/// Render a byte count at the scale people actually use.
///
/// Decimal units, because that is what drives are sold in and what a buyer is
/// comparing against the listing. Memory is conventionally quoted in powers of
/// two, so an 8 GiB stick reads as 8.6 GB here; the exact byte count is kept
/// alongside for anyone who needs it.
pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 {
        format!("{bytes} B")
    } else if v >= 100.0 {
        format!("{v:.0} {}", UNITS[i])
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

/// An ordered bag of facts. `BTreeMap` so exports are byte-stable across runs,
/// which lets a buyer diff two scans of the same machine.
pub type Facts = BTreeMap<String, Fact>;

/// A piece of hardware with no meaningful wear model: CPU, RAM stick, GPU, NIC.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Component {
    /// Machine-readable class: `cpu`, `memory`, `gpu`, `network`, `board`.
    pub kind: String,
    pub name: String,
    #[serde(default)]
    pub facts: Facts,
}

impl Component {
    pub fn new(kind: impl Into<String>, name: impl Into<String>) -> Self {
        Component {
            kind: kind.into(),
            name: name.into(),
            facts: Facts::new(),
        }
    }

    pub fn fact(mut self, key: impl Into<String>, fact: Fact) -> Self {
        self.facts.insert(key.into(), fact);
        self
    }

    pub fn push(&mut self, key: impl Into<String>, fact: Fact) {
        self.facts.insert(key.into(), fact);
    }
}

/// A part that wears out and is the reason someone runs this tool: a drive or
/// a battery.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Consumable {
    /// `storage` or `battery`.
    pub kind: String,
    pub name: String,
    /// Remaining life, where 100 means factory-new. `None` when the part would
    /// not answer.
    pub percent: Option<f64>,
    pub verdict: Verdict,
    /// The one line shown next to the gauge.
    pub headline: String,
    #[serde(default)]
    pub facts: Facts,
    #[serde(default)]
    pub findings: Vec<Finding>,
}

impl Consumable {
    pub fn new(kind: impl Into<String>, name: impl Into<String>) -> Self {
        Consumable {
            kind: kind.into(),
            name: name.into(),
            percent: None,
            verdict: Verdict::Unknown,
            headline: String::new(),
            facts: Facts::new(),
            findings: Vec::new(),
        }
    }

    pub fn push(&mut self, key: impl Into<String>, fact: Fact) {
        self.facts.insert(key.into(), fact);
    }
}

/// Result of one cross-source consistency check.
///
/// These are what turn a spec list into a buying tool: they compare two
/// independent sources for the same fact and report when they disagree.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TamperCheck {
    pub id: String,
    /// Phrased as the reassuring outcome, so a pass reads naturally.
    pub title: String,
    pub status: CheckStatus,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CheckStatus {
    Pass,
    /// Something looks off but has an innocent explanation too.
    Suspicious,
    /// Two sources that should agree do not.
    Fail,
    /// Not enough data to run the check, usually for want of privileges.
    Skipped,
}

/// How much of this scan rests on evidence that resists tampering.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustSummary {
    pub total_facts: usize,
    pub tamper_resistant_facts: usize,
    /// Share of facts at firmware rank or above, as a percentage.
    pub tamper_resistant_percent: f64,
    /// True when the scan ran with the privileges needed to talk to devices.
    pub full_access: bool,
}

/// A completed scan.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// RFC 3339, UTC.
    pub generated_at: String,
    pub tool_version: String,
    pub platform: String,
    /// Whether the scan had root or administrator rights. Drives the "Unlock
    /// full scan" prompt in the UI.
    pub privileged: bool,
    #[serde(default)]
    pub system: Facts,
    #[serde(default)]
    pub components: Vec<Component>,
    #[serde(default)]
    pub consumables: Vec<Consumable>,
    #[serde(default)]
    pub findings: Vec<Finding>,
    #[serde(default)]
    pub tamper_checks: Vec<TamperCheck>,
    pub trust: TrustSummary,
    /// Probes that failed, kept rather than hidden so a blank section is never
    /// mistaken for a clean result.
    #[serde(default)]
    pub errors: Vec<String>,
}

impl Report {
    /// Walk every fact in the report once, in a stable order.
    pub fn all_facts(&self) -> impl Iterator<Item = (&String, &Fact)> {
        self.system
            .iter()
            .chain(self.components.iter().flat_map(|c| c.facts.iter()))
            .chain(self.consumables.iter().flat_map(|c| c.facts.iter()))
    }

    /// Recompute [`TrustSummary`] from the facts actually present.
    ///
    /// Called once at the end of a scan rather than maintained incrementally,
    /// so it cannot drift out of step with the facts it describes.
    pub fn recompute_trust(&mut self) {
        let mut total = 0usize;
        let mut resistant = 0usize;
        for (_, f) in self.all_facts() {
            total += 1;
            if f.trust.is_tamper_resistant() {
                resistant += 1;
            }
        }
        self.trust = TrustSummary {
            total_facts: total,
            tamper_resistant_facts: resistant,
            tamper_resistant_percent: if total == 0 {
                0.0
            } else {
                (resistant as f64 / total as f64) * 100.0
            },
            full_access: self.privileged,
        };
    }

    /// The weakest rank any fact in the report rests on.
    pub fn weakest_trust(&self) -> Option<Trust> {
        self.all_facts().map(|(_, f)| f.trust).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fact::{firmware, software};

    fn empty_report() -> Report {
        Report {
            generated_at: "2026-09-01T00:00:00Z".into(),
            tool_version: "0.1.0".into(),
            platform: "linux".into(),
            privileged: false,
            system: Facts::new(),
            components: Vec::new(),
            consumables: Vec::new(),
            findings: Vec::new(),
            tamper_checks: Vec::new(),
            trust: TrustSummary {
                total_facts: 0,
                tamper_resistant_facts: 0,
                tamper_resistant_percent: 0.0,
                full_access: false,
            },
            errors: Vec::new(),
        }
    }

    #[test]
    fn trust_summary_counts_across_every_section() {
        let mut r = empty_report();
        r.system
            .insert("vendor".into(), firmware("Acme", "smbios:type1"));
        r.system
            .insert("os".into(), software("Fedora", "os-release"));
        r.components.push(
            Component::new("cpu", "Ryzen 5 5600U")
                .fact("cores", crate::fact::kernel(6_u32, "sysfs")),
        );
        r.recompute_trust();

        assert_eq!(r.trust.total_facts, 3);
        // The software-sourced OS name must not be counted as evidence.
        assert_eq!(r.trust.tamper_resistant_facts, 2);
        assert!((r.trust.tamper_resistant_percent - 66.666).abs() < 0.01);
    }

    #[test]
    fn empty_report_does_not_divide_by_zero() {
        let mut r = empty_report();
        r.recompute_trust();
        assert_eq!(r.trust.tamper_resistant_percent, 0.0);
        assert_eq!(r.weakest_trust(), None);
    }

    #[test]
    fn weakest_trust_finds_the_soft_link() {
        let mut r = empty_report();
        r.system
            .insert("vendor".into(), firmware("Acme", "smbios:type1"));
        r.system
            .insert("os".into(), software("Fedora", "os-release"));
        assert_eq!(r.weakest_trust(), Some(Trust::Software));
    }
}
