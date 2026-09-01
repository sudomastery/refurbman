//! Turning smartctl JSON into a verdict.
//!
//! Two drive families need different reasoning. A solid state drive wears out
//! predictably and reports how much of its rated life it has spent, so it gets
//! a percentage. A spinning disk has no such counter: it is fine until sectors
//! start failing, so it is judged on defect counts instead, and reporting a
//! percentage for one would be inventing a number.

use serde_json::Value as Json;

use crate::fact::{derived, device, Fact};
use crate::report::{Consumable, Finding, Verdict};
use crate::smart::DeviceRef;

/// One NVMe data unit is 1000 blocks of 512 bytes, per the NVMe specification.
const NVME_DATA_UNIT_BYTES: u64 = 512 * 1000;

/// Hours below which a drive is effectively unused. A drive claiming fewer
/// hours than this while showing real wear has had its counters reset.
const IMPLAUSIBLY_FEW_HOURS: u64 = 100;

/// Life used above which "barely used" stops being credible.
const WEAR_IMPLYING_USE: f64 = 5.0;

pub fn devices(json: &Json) -> Vec<DeviceRef> {
    json.get("devices")
        .and_then(Json::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|d| {
                    Some(DeviceRef {
                        name: d.get("name")?.as_str()?.to_owned(),
                        kind: d.get("type").and_then(Json::as_str).map(str::to_owned),
                        open_error: d
                            .get("open_error")
                            .and_then(Json::as_str)
                            .map(str::to_owned),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn u64_at(json: &Json, path: &[&str]) -> Option<u64> {
    let mut cur = json;
    for k in path {
        cur = cur.get(k)?;
    }
    cur.as_u64()
}

fn str_at<'a>(json: &'a Json, path: &[&str]) -> Option<&'a str> {
    let mut cur = json;
    for k in path {
        cur = cur.get(k)?;
    }
    cur.as_str().map(str::trim).filter(|s| !s.is_empty())
}

/// Look up one ATA SMART attribute's raw value by id.
fn ata_raw(json: &Json, id: u64) -> Option<u64> {
    json.get("ata_smart_attributes")?
        .get("table")?
        .as_array()?
        .iter()
        .find(|a| a.get("id").and_then(Json::as_u64) == Some(id))?
        .get("raw")?
        .get("value")?
        .as_u64()
}

/// Look up one attribute's normalised value, which for wear indicators counts
/// down from 100 and is the closest a SATA SSD gets to "life remaining".
fn ata_normalised(json: &Json, id: u64) -> Option<u64> {
    json.get("ata_smart_attributes")?
        .get("table")?
        .as_array()?
        .iter()
        .find(|a| a.get("id").and_then(Json::as_u64) == Some(id))?
        .get("value")?
        .as_u64()
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 {
        format!("{} {}", bytes, UNITS[0])
    } else if v >= 100.0 {
        format!("{v:.0} {}", UNITS[i])
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

/// Turn one drive's full smartctl output into a consumable with a verdict.
pub fn drive(json: &Json, fallback_name: &str) -> Consumable {
    let model = str_at(json, &["model_name"])
        .or_else(|| str_at(json, &["device", "name"]))
        .unwrap_or(fallback_name)
        .to_owned();

    let mut c = Consumable::new("storage", model.clone());
    let src = |field: &str| format!("smartctl:{field}");

    c.push("model", device(model, src("model_name")));
    if let Some(v) = str_at(json, &["firmware_version"]) {
        c.push("firmware", device(v, src("firmware_version")));
    }
    if let Some(v) = str_at(json, &["device", "protocol"]) {
        c.push("protocol", device(v, src("device.protocol")));
    }
    if let Some(bytes) = u64_at(json, &["user_capacity", "bytes"]) {
        c.push(
            "capacityBytes",
            device(bytes, src("user_capacity.bytes")).unit("bytes"),
        );
        c.push(
            "capacity",
            derived(human_bytes(bytes), src("user_capacity.bytes")),
        );
    }

    let rotation = u64_at(json, &["rotation_rate"]);
    let is_ssd = matches!(rotation, Some(0) | None)
        && str_at(json, &["device", "protocol"]) != Some("ATA")
        || rotation == Some(0);
    if let Some(rpm) = rotation.filter(|r| *r > 0) {
        c.push("rotationRpm", device(rpm, src("rotation_rate")).unit("rpm"));
    }
    c.push(
        "kind",
        derived(
            if is_ssd { "Solid state" } else { "Hard disk" },
            src("rotation_rate"),
        ),
    );

    let hours = u64_at(json, &["power_on_time", "hours"]);
    if let Some(h) = hours {
        c.push(
            "powerOnHours",
            device(h, src("power_on_time.hours")).unit("hours"),
        );
        // "11512 hours" is a number; "1.3 years" is an answer to the question
        // the reader is actually asking.
        c.push("powerOnFor", derived(humanise_hours(h), "power on hours"));
    }
    if let Some(v) = u64_at(json, &["power_cycle_count"]) {
        c.push("powerCycles", device(v, src("power_cycle_count")));
    }
    if let Some(v) = u64_at(json, &["temperature", "current"]) {
        c.push(
            "temperatureC",
            device(v, src("temperature.current")).unit("C"),
        );
    }

    let passed = json
        .get("smart_status")
        .and_then(|s| s.get("passed"))
        .and_then(Json::as_bool);
    if let Some(p) = passed {
        // A bare yes/no beside "Self assessment" is not a sentence anyone
        // reads correctly under pressure.
        c.push(
            "selfAssessment",
            device(
                if p { "Passed" } else { "FAILED" },
                src("smart_status.passed"),
            ),
        );
    }

    // Protocol-specific wear.
    let life_used = if json.get("nvme_smart_health_information_log").is_some() {
        nvme(json, &mut c, &src)
    } else {
        ata(json, &mut c, &src)
    };

    assess(&mut c, life_used, passed, hours, is_ssd);
    c
}

/// NVMe health log. `percentage_used` is the vendor's own estimate of rated
/// life consumed, and can exceed 100 on a drive used past its warranty.
fn nvme(json: &Json, c: &mut Consumable, src: &dyn Fn(&str) -> String) -> Option<f64> {
    const LOG: &str = "nvme_smart_health_information_log";
    let log = json.get(LOG)?;
    let f = |k: &str| src(&format!("{LOG}.{k}"));

    let used = log.get("percentage_used").and_then(Json::as_u64);
    if let Some(u) = used {
        c.push("lifeUsedPercent", device(u, f("percentage_used")).unit("%"));
    }
    if let Some(v) = log.get("available_spare").and_then(Json::as_u64) {
        c.push(
            "spareAvailablePercent",
            device(v, f("available_spare")).unit("%"),
        );
    }
    if let Some(v) = log.get("available_spare_threshold").and_then(Json::as_u64) {
        c.push(
            "spareThresholdPercent",
            device(v, f("available_spare_threshold")).unit("%"),
        );
    }
    if let Some(v) = log.get("media_errors").and_then(Json::as_u64) {
        c.push("mediaErrors", device(v, f("media_errors")));
    }
    if let Some(v) = log.get("critical_warning").and_then(Json::as_u64) {
        c.push("criticalWarning", device(v, f("critical_warning")));
    }
    if let Some(v) = log.get("unsafe_shutdowns").and_then(Json::as_u64) {
        c.push("unsafeShutdowns", device(v, f("unsafe_shutdowns")));
    }
    if let Some(v) = log.get("data_units_written").and_then(Json::as_u64) {
        let bytes = v.saturating_mul(NVME_DATA_UNIT_BYTES);
        c.push(
            "bytesWritten",
            device(bytes, f("data_units_written")).unit("bytes"),
        );
        c.push(
            "totalWritten",
            derived(human_bytes(bytes), f("data_units_written")),
        );
    }
    used.map(|u| u as f64)
}

/// ATA attributes. Solid state drives expose a countdown attribute; spinning
/// disks expose defect counters instead.
fn ata(json: &Json, c: &mut Consumable, src: &dyn Fn(&str) -> String) -> Option<f64> {
    let attr = |id: u64, name: &str| src(&format!("ata_smart_attributes.{id} {name}"));

    for (id, key, name) in [
        (5u64, "reallocatedSectors", "Reallocated_Sector_Ct"),
        (197, "pendingSectors", "Current_Pending_Sector"),
        (198, "uncorrectableSectors", "Offline_Uncorrectable"),
        (199, "interfaceCrcErrors", "UDMA_CRC_Error_Count"),
    ] {
        if let Some(v) = ata_raw(json, id) {
            c.push(key, device(v, attr(id, name)));
        }
    }

    if let Some(v) = ata_raw(json, 241) {
        // Logical sectors written, 512 bytes each.
        let bytes = v.saturating_mul(512);
        c.push(
            "bytesWritten",
            device(bytes, attr(241, "Total_LBAs_Written")).unit("bytes"),
        );
        c.push(
            "totalWritten",
            derived(human_bytes(bytes), attr(241, "Total_LBAs_Written")),
        );
    }

    // Newer smartctl computes this across protocols; prefer it when present.
    if let Some(v) = u64_at(json, &["endurance_used", "current_percent"]) {
        c.push(
            "lifeUsedPercent",
            device(v, src("endurance_used.current_percent")).unit("%"),
        );
        return Some(v as f64);
    }

    // Otherwise fall back to whichever wear countdown this vendor implements.
    for (id, name) in [
        (231u64, "SSD_Life_Left"),
        (177, "Wear_Leveling_Count"),
        (202, "Percent_Lifetime_Remain"),
    ] {
        if let Some(remaining) = ata_normalised(json, id) {
            if remaining <= 100 {
                let used = 100.0 - remaining as f64;
                c.push(
                    "lifeUsedPercent",
                    device(used as u64, attr(id, name)).unit("%"),
                );
                return Some(used);
            }
        }
    }
    None
}

/// Decide the verdict and write the sentences a buyer reads.
fn assess(
    c: &mut Consumable,
    life_used: Option<f64>,
    passed: Option<bool>,
    hours: Option<u64>,
    is_ssd: bool,
) {
    let raw = |k: &str| -> Option<u64> {
        c.facts.get(k).and_then(|f| match f.value {
            crate::fact::Value::Int(v) => Some(v as u64),
            _ => None,
        })
    };

    let reallocated = raw("reallocatedSectors").unwrap_or(0);
    let pending = raw("pendingSectors").unwrap_or(0);
    let uncorrectable = raw("uncorrectableSectors").unwrap_or(0);
    let crc = raw("interfaceCrcErrors").unwrap_or(0);
    let media_errors = raw("mediaErrors").unwrap_or(0);
    let critical_warning = raw("criticalWarning").unwrap_or(0);
    let spare = raw("spareAvailablePercent");
    let spare_threshold = raw("spareThresholdPercent");

    let mut verdict = Verdict::Good;
    let mut worst = |v: Verdict| {
        let rank = |x: Verdict| match x {
            Verdict::Good => 0,
            Verdict::Fair => 1,
            Verdict::Unknown => 2,
            Verdict::Poor => 3,
        };
        if rank(v) > rank(verdict) {
            verdict = v;
        }
    };

    // The drive's own overall judgement. When a drive says it is failing,
    // nothing else in the report outranks that.
    if passed == Some(false) {
        worst(Verdict::Poor);
        c.findings.push(
            Finding::critical(
                "The drive reports that it is failing",
                "This drive's own controller has raised its failure warning. That is the \
                 strongest signal a drive can give, and it means data loss is likely. Do not \
                 buy this machine on the assumption the drive can be relied on, and do not \
                 store anything on it that is not backed up elsewhere.",
            )
            .evidence("smart_status.passed = false"),
        );
    }

    if critical_warning != 0 {
        worst(Verdict::Poor);
        c.findings.push(
            Finding::critical(
                "The drive has raised a critical warning",
                "The drive is reporting a critical condition, such as running too hot, \
                 having spare capacity nearly exhausted, or having switched itself to \
                 read-only. Treat this drive as unreliable.",
            )
            .evidence(format!("critical_warning bitfield = {critical_warning}")),
        );
    }

    if let (Some(spare), Some(threshold)) = (spare, spare_threshold) {
        if spare <= threshold {
            worst(Verdict::Poor);
            c.findings.push(
                Finding::critical(
                    "The drive has run out of spare capacity",
                    "Solid state drives keep spare blocks to replace ones that wear out. \
                     This drive has used nearly all of them, which means it is at the end \
                     of its working life.",
                )
                .evidence(format!(
                    "available_spare {spare}% at threshold {threshold}%"
                )),
            );
        }
    }

    // Life remaining, for drives that report it.
    if let Some(used) = life_used {
        let remaining = (100.0 - used).clamp(0.0, 100.0);
        c.percent = Some(remaining);
        c.push(
            "lifeRemainingPercent",
            derived(round1(remaining), "100 minus reported life used").unit("%"),
        );

        match used {
            u if u >= 90.0 => {
                worst(Verdict::Poor);
                c.findings.push(Finding::critical(
                    "The drive is nearly worn out",
                    format!(
                        "This drive reports that it has used {u:.0}% of the write life it \
                         was designed for. It is close to the end of its service life and \
                         should be treated as needing replacement."
                    ),
                ));
            }
            u if u >= 70.0 => {
                worst(Verdict::Fair);
                c.findings.push(Finding::warn(
                    "The drive is significantly worn",
                    format!(
                        "This drive reports that it has used {u:.0}% of its designed write \
                         life. It works now, but it has more life behind it than ahead of \
                         it. Price a replacement into the deal."
                    ),
                ));
            }
            u if u >= 30.0 => worst(Verdict::Fair),
            _ => {}
        }
    }

    // Spinning disk defects. A single reallocated sector is not a crisis, but
    // pending and uncorrectable sectors mean the drive is losing data now.
    if reallocated > 0 {
        worst(if reallocated >= 50 {
            Verdict::Poor
        } else {
            Verdict::Fair
        });
        c.findings.push(
            Finding::warn(
                "The drive has replaced failed areas of its surface",
                format!(
                    "{reallocated} area{} of this drive stopped working and were swapped for \
                     spares. A handful can be normal on an older drive, but the count only \
                     ever goes up, so watch it. A drive doing this repeatedly is on its way out.",
                    if reallocated == 1 { "" } else { "s" }
                ),
            )
            .evidence(format!("Reallocated_Sector_Ct raw = {reallocated}")),
        );
    }
    if pending > 0 || uncorrectable > 0 {
        worst(Verdict::Poor);
        c.findings.push(
            Finding::critical(
                "The drive has areas it can no longer read",
                format!(
                    "This drive has {pending} area{} waiting to be dealt with and \
                     {uncorrectable} it could not recover. That means data on this drive is \
                     already being lost. Do not rely on this drive.",
                    if pending == 1 { "" } else { "s" }
                ),
            )
            .evidence(format!(
                "Current_Pending_Sector {pending}, Offline_Uncorrectable {uncorrectable}"
            )),
        );
    }
    if media_errors > 0 {
        worst(Verdict::Fair);
        c.findings.push(
            Finding::warn(
                "The drive has reported unrecoverable errors",
                format!(
                    "The drive logged {media_errors} error{} it could not correct. On a solid \
                     state drive this usually points to failing memory cells.",
                    if media_errors == 1 { "" } else { "s" }
                ),
            )
            .evidence(format!("media_errors = {media_errors}")),
        );
    }
    if crc > 0 {
        c.findings.push(
            Finding::info(
                "Errors seen on the cable between drive and computer",
                format!(
                    "There have been {crc} communication errors on the drive's cable. This is \
                     usually a loose or poor quality cable rather than a fault in the drive."
                ),
            )
            .evidence(format!("UDMA_CRC_Error_Count = {crc}")),
        );
    }

    // Counter reset check. A drive with real wear but almost no recorded
    // running time has had its hours cleared, which is done to make a heavily
    // used drive look new.
    if let (Some(h), Some(used)) = (hours, life_used) {
        if h < IMPLAUSIBLY_FEW_HOURS && used > WEAR_IMPLYING_USE {
            worst(Verdict::Unknown);
            c.findings.push(
                Finding::critical(
                    "This drive's usage history does not add up",
                    format!(
                        "The drive reports only {h} hours of use, yet also reports {used:.0}% of \
                         its write life consumed. Those two figures cannot both be true: wearing \
                         a drive that far takes far longer than {h} hours. The most likely \
                         explanation is that the usage counters have been reset to make the drive \
                         look newer than it is. Treat this drive, and this seller, with caution."
                    ),
                )
                .evidence(format!(
                    "power_on_time.hours = {h} against life used {used:.0}%"
                )),
            );
        }
    }

    if c.percent.is_none() && verdict == Verdict::Good && passed == Some(true) {
        // A healthy spinning disk with no wear counter. Say so rather than
        // inventing a percentage.
        c.headline = match hours {
            Some(h) if h > 0 => format!("No faults reported after {} of use.", humanise_hours(h)),
            _ => "No faults reported.".into(),
        };
    }

    if c.headline.is_empty() {
        c.headline = headline(verdict, c.percent, hours, is_ssd);
    }
    c.verdict = verdict;
}

fn headline(verdict: Verdict, percent: Option<f64>, hours: Option<u64>, is_ssd: bool) -> String {
    let life = percent.map(|p| format!("{p:.0}% of its life left"));
    let age = hours.filter(|h| *h > 0).map(humanise_hours);
    let thing = if is_ssd { "drive" } else { "disk" };

    match (verdict, life, age) {
        (Verdict::Good, Some(l), Some(a)) => format!("Healthy, with {l} after {a} of use."),
        (Verdict::Good, Some(l), None) => format!("Healthy, with {l}."),
        (Verdict::Good, None, Some(a)) => format!("Healthy after {a} of use."),
        (Verdict::Good, None, None) => "Healthy.".into(),
        (Verdict::Fair, Some(l), _) => format!("Worn but working, with {l}."),
        (Verdict::Fair, None, _) => format!("This {thing} is showing early signs of wear."),
        (Verdict::Poor, Some(l), _) => format!("Near the end of its life, with {l}."),
        (Verdict::Poor, None, _) => format!("This {thing} is failing and should not be relied on."),
        (Verdict::Unknown, _, _) => format!("This {thing}'s reported history is inconsistent."),
    }
}

fn humanise_hours(h: u64) -> String {
    let years = h as f64 / 8760.0;
    if years >= 1.0 {
        format!("{years:.1} years")
    } else {
        let days = h as f64 / 24.0;
        if days >= 1.0 {
            format!("{days:.0} days")
        } else {
            format!("{h} hours")
        }
    }
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

/// Facts describing a drive we could see but not open, so the report shows the
/// hardware exists and explains why its health is missing.
pub fn locked(dev: &DeviceRef, reason: &str) -> Consumable {
    let mut c = Consumable::new("storage", dev.name.clone());
    c.verdict = Verdict::Unknown;
    c.headline = "Health could not be read without permission.".into();
    c.push(
        "device",
        crate::fact::kernel(dev.name.clone(), "smartctl:--scan-open"),
    );
    c.findings.push(
        Finding::info(
            "This drive needs permission before it can be checked",
            "RefurbMan found this drive but was not allowed to ask it about its health. \
             Run the full scan and approve the permission prompt to see how much life it \
             has left.",
        )
        .evidence(reason.to_owned()),
    );
    c
}

/// Extra facts merged in from the kernel's own view of the block device, used
/// both to fill gaps and to cross-check what the drive claims.
pub fn merge_kernel_facts(c: &mut Consumable, facts: Vec<(String, Fact)>) {
    for (k, v) in facts {
        c.facts.entry(k).or_insert(v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A healthy NVMe drive. Values are fabricated, not captured, so that no
    /// real hardware serial can ever reach this repository.
    fn nvme_json(used: u64, hours: u64, media_errors: u64) -> Json {
        json!({
            "device": {"name": "/dev/nvme0", "type": "nvme", "protocol": "NVMe"},
            "model_name": "EXAMPLE NVMe SSD 512GB",
            "firmware_version": "1.0.0",
            "user_capacity": {"bytes": 512_110_190_592u64},
            "rotation_rate": 0,
            "smart_status": {"passed": true},
            "power_on_time": {"hours": hours},
            "power_cycle_count": 900,
            "temperature": {"current": 34},
            "nvme_smart_health_information_log": {
                "critical_warning": 0,
                "available_spare": 100,
                "available_spare_threshold": 10,
                "percentage_used": used,
                "media_errors": media_errors,
                "unsafe_shutdowns": 20,
                "data_units_written": 40_000_000u64
            }
        })
    }

    fn hdd_json(reallocated: u64, pending: u64, uncorrectable: u64, passed: bool) -> Json {
        json!({
            "device": {"name": "/dev/sda", "type": "sat", "protocol": "ATA"},
            "model_name": "EXAMPLE HDD 1TB",
            "user_capacity": {"bytes": 1_000_204_886_016u64},
            "rotation_rate": 7200,
            "smart_status": {"passed": passed},
            "power_on_time": {"hours": 21_000},
            "ata_smart_attributes": {"table": [
                {"id": 5,   "name": "Reallocated_Sector_Ct", "value": 100, "raw": {"value": reallocated}},
                {"id": 197, "name": "Current_Pending_Sector", "value": 100, "raw": {"value": pending}},
                {"id": 198, "name": "Offline_Uncorrectable",  "value": 100, "raw": {"value": uncorrectable}},
                {"id": 199, "name": "UDMA_CRC_Error_Count",   "value": 200, "raw": {"value": 0}}
            ]}
        })
    }

    #[test]
    fn healthy_nvme_reads_good_and_reports_life_left() {
        let c = drive(&nvme_json(3, 1200, 0), "fallback");
        assert_eq!(c.verdict, Verdict::Good);
        assert_eq!(c.percent, Some(97.0));
        assert!(c.headline.contains("97%"), "headline was {:?}", c.headline);
        assert!(c.findings.is_empty());
    }

    #[test]
    fn capacity_and_writes_are_rendered_for_humans() {
        let c = drive(&nvme_json(3, 1200, 0), "fallback");
        let cap = &c.facts["capacity"].value;
        assert_eq!(cap, &crate::fact::Value::Text("512 GB".into()));
        // 40,000,000 data units * 512,000 bytes = 20.48 TB
        let written = &c.facts["totalWritten"].value;
        assert_eq!(written, &crate::fact::Value::Text("20.5 TB".into()));
    }

    #[test]
    fn heavily_worn_nvme_reads_poor() {
        let c = drive(&nvme_json(94, 40_000, 0), "fallback");
        assert_eq!(c.verdict, Verdict::Poor);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("nearly worn out")));
    }

    #[test]
    fn moderately_worn_nvme_reads_fair() {
        let c = drive(&nvme_json(75, 30_000, 0), "fallback");
        assert_eq!(c.verdict, Verdict::Fair);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("significantly worn")));
    }

    #[test]
    fn drive_reporting_its_own_failure_is_always_poor() {
        // Even with otherwise clean counters, the drive's own verdict wins.
        let mut j = nvme_json(2, 500, 0);
        j["smart_status"]["passed"] = json!(false);
        let c = drive(&j, "fallback");
        assert_eq!(c.verdict, Verdict::Poor);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("reports that it is failing")));
    }

    #[test]
    fn exhausted_spare_capacity_is_critical() {
        let mut j = nvme_json(60, 20_000, 0);
        j["nvme_smart_health_information_log"]["available_spare"] = json!(8);
        let c = drive(&j, "fallback");
        assert_eq!(c.verdict, Verdict::Poor);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("run out of spare")));
    }

    #[test]
    fn reset_usage_counters_are_caught() {
        // The scam this tool exists for: a drive worn to 40% of its life that
        // claims 12 hours of use. The two readings contradict each other.
        let c = drive(&nvme_json(40, 12, 0), "fallback");
        assert_eq!(c.verdict, Verdict::Unknown);
        let f = c
            .findings
            .iter()
            .find(|f| f.title.contains("does not add up"))
            .expect("counter reset should be flagged");
        assert!(f.detail.contains("reset"));
    }

    #[test]
    fn low_hours_on_a_genuinely_new_drive_are_not_flagged() {
        // The same low hour count with no wear is simply a new drive, and must
        // not be accused of anything.
        let c = drive(&nvme_json(0, 12, 0), "fallback");
        assert_eq!(c.verdict, Verdict::Good);
        assert!(!c
            .findings
            .iter()
            .any(|f| f.title.contains("does not add up")));
    }

    #[test]
    fn healthy_spinning_disk_has_no_percentage_invented_for_it() {
        let c = drive(&hdd_json(0, 0, 0, true), "fallback");
        assert_eq!(c.verdict, Verdict::Good);
        // A hard disk has no wear counter, so claiming a percentage would be
        // making one up.
        assert_eq!(c.percent, None);
        assert!(
            c.headline.contains("2.4 years"),
            "headline was {:?}",
            c.headline
        );
    }

    #[test]
    fn pending_sectors_make_a_disk_poor() {
        let c = drive(&hdd_json(4, 8, 2, true), "fallback");
        assert_eq!(c.verdict, Verdict::Poor);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("can no longer read")));
    }

    #[test]
    fn a_few_reallocated_sectors_are_fair_not_fatal() {
        let c = drive(&hdd_json(3, 0, 0, true), "fallback");
        assert_eq!(c.verdict, Verdict::Fair);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("replaced failed areas")));
    }

    #[test]
    fn many_reallocated_sectors_are_poor() {
        let c = drive(&hdd_json(120, 0, 0, true), "fallback");
        assert_eq!(c.verdict, Verdict::Poor);
    }

    #[test]
    fn media_errors_are_surfaced() {
        let c = drive(&nvme_json(5, 3000, 7), "fallback");
        assert_eq!(c.verdict, Verdict::Fair);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("unrecoverable errors")));
    }

    #[test]
    fn ata_ssd_wear_countdown_is_converted_to_life_used() {
        let j = json!({
            "device": {"name": "/dev/sda", "type": "sat", "protocol": "ATA"},
            "model_name": "EXAMPLE SATA SSD 256GB",
            "rotation_rate": 0,
            "smart_status": {"passed": true},
            "power_on_time": {"hours": 9000},
            "ata_smart_attributes": {"table": [
                {"id": 231, "name": "SSD_Life_Left", "value": 88, "raw": {"value": 88}}
            ]}
        });
        let c = drive(&j, "fallback");
        // 88 remaining means 12 used.
        assert_eq!(c.percent, Some(88.0));
        assert_eq!(c.verdict, Verdict::Good);
    }

    #[test]
    fn endurance_used_is_preferred_over_vendor_attributes() {
        let j = json!({
            "device": {"name": "/dev/sda", "type": "sat", "protocol": "ATA"},
            "model_name": "EXAMPLE SATA SSD 256GB",
            "rotation_rate": 0,
            "smart_status": {"passed": true},
            "endurance_used": {"current_percent": 45},
            "ata_smart_attributes": {"table": [
                {"id": 231, "name": "SSD_Life_Left", "value": 99, "raw": {"value": 99}}
            ]}
        });
        let c = drive(&j, "fallback");
        assert_eq!(c.percent, Some(55.0));
    }

    #[test]
    fn cable_errors_are_information_not_an_accusation() {
        let mut j = hdd_json(0, 0, 0, true);
        j["ata_smart_attributes"]["table"][3]["raw"]["value"] = json!(14);
        let c = drive(&j, "fallback");
        assert_eq!(c.verdict, Verdict::Good);
        let f = c
            .findings
            .iter()
            .find(|f| f.title.contains("cable"))
            .unwrap();
        assert!(matches!(f.severity, crate::report::Severity::Info));
    }

    #[test]
    fn locked_drive_is_unknown_and_explains_itself() {
        let dev = DeviceRef {
            name: "/dev/nvme0".into(),
            kind: Some("nvme".into()),
            open_error: Some("Permission denied".into()),
        };
        let c = locked(&dev, "Permission denied");
        assert_eq!(c.verdict, Verdict::Unknown);
        assert!(c.findings[0].title.contains("needs permission"));
    }

    #[test]
    fn every_fact_carries_a_source() {
        let c = drive(&nvme_json(3, 1200, 0), "fallback");
        for (k, f) in &c.facts {
            assert!(!f.source.is_empty(), "fact {k} has no source");
        }
    }
}
