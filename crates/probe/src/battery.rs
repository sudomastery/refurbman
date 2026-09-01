//! Battery wear.
//!
//! A laptop battery is the part most likely to be quietly worn out, and the one
//! a seller can least easily replace before a sale. Health is the ratio of what
//! the pack can hold now to what it held when new, both figures reported by the
//! battery's own controller through the ACPI driver.
//!
//! The subtlety worth knowing about: a good number of laptops never update the
//! "full charge" figure, so they report perfect health forever. We detect that
//! by cross-checking against the cycle count, because a pack that has been
//! through hundreds of cycles and still claims to be factory-new is not being
//! measured, it is being assumed.

use crate::fact::{derived, device, kernel, Value};
use crate::report::{Consumable, Finding, Verdict};

/// Cycles past which a consumer lithium pack is normally considered spent.
/// Most manufacturers rate to 80% capacity at 300 to 500 cycles.
const CYCLES_END_OF_LIFE: u64 = 1000;
const CYCLES_WELL_USED: u64 = 500;

/// Above this, a health reading is "perfect" enough to be suspicious when the
/// pack has clearly been used.
const IMPLAUSIBLY_PERFECT: f64 = 99.5;

/// Cycles beyond which a perfect health reading stops being credible.
const CYCLES_IMPLYING_WEAR: u64 = 200;

pub fn probe() -> Vec<Consumable> {
    #[cfg(target_os = "linux")]
    {
        linux_batteries()
    }
    #[cfg(not(target_os = "linux"))]
    {
        portable_batteries()
    }
}

/// Turn the raw readings into a verdict and a sentence a buyer can act on.
///
/// Split out from the readers so both platforms share one judgement, and so it
/// can be tested against packs this machine does not have.
pub fn assess(c: &mut Consumable) {
    let health = c.facts.get("healthPercent").and_then(|f| match f.value {
        Value::Float(v) => Some(v),
        Value::Int(v) => Some(v as f64),
        _ => None,
    });
    let cycles = c.facts.get("cycleCount").and_then(|f| match f.value {
        Value::Int(v) if v > 0 => Some(v as u64),
        _ => None,
    });

    c.percent = health;

    let Some(health) = health else {
        c.verdict = Verdict::Unknown;
        c.headline = "This battery would not report its condition.".into();
        c.findings.push(Finding::info(
            "Battery health could not be read",
            "The battery did not report the figures needed to work out how much \
             capacity it has lost. This is common on desktops and on some older \
             laptops. It is not a sign of a fault.",
        ));
        return;
    };

    // The plausibility check comes first, because when it fires the health
    // number should not be presented as a finding at all.
    let unreliable =
        health >= IMPLAUSIBLY_PERFECT && cycles.is_some_and(|c| c > CYCLES_IMPLYING_WEAR);

    if unreliable {
        let cycles = cycles.unwrap_or(0);
        c.verdict = Verdict::Unknown;
        c.headline = format!(
            "Reports perfect health after {cycles} charge cycles, which is unlikely to be measured."
        );
        c.findings.push(
            Finding::warn(
                "Battery health figure looks unreliable",
                format!(
                    "This battery claims {health:.0}% of its original capacity while also \
                     reporting {cycles} charge cycles. A pack that has been charged that \
                     many times has almost always lost noticeable capacity, so this laptop \
                     is very likely reporting its factory rating rather than measuring the \
                     pack. Judge this battery by how long it actually lasts unplugged, not \
                     by this number."
                ),
            )
            .evidence(format!(
                "health {health:.1}% from charge_full / charge_full_design, cycle_count {cycles}"
            )),
        );
        return;
    }

    c.verdict = match health {
        h if h >= 80.0 => Verdict::Good,
        h if h >= 60.0 => Verdict::Fair,
        _ => Verdict::Poor,
    };

    c.headline = match c.verdict {
        Verdict::Good => format!("Holds {health:.0}% of its original charge. In good shape."),
        Verdict::Fair => {
            format!("Holds {health:.0}% of its original charge. Noticeably worn but usable.")
        }
        Verdict::Poor => format!(
            "Holds only {health:.0}% of its original charge. Expect a short time unplugged."
        ),
        Verdict::Unknown => String::new(),
    };

    match c.verdict {
        Verdict::Fair => c.findings.push(Finding::warn(
            "Battery has lost some capacity",
            format!(
                "This battery holds about {health:.0}% of what it held when new, so it will \
                 last roughly that share of the original time between charges. A replacement \
                 is worth pricing up when you negotiate."
            ),
        )),
        Verdict::Poor => c.findings.push(Finding::critical(
            "Battery is worn out",
            format!(
                "This battery holds only about {health:.0}% of its original capacity. It will \
                 need replacing soon, and on many laptops that is not a cheap or simple job. \
                 Factor the cost of a new pack into the price."
            ),
        )),
        _ => {}
    }

    if let Some(cycles) = cycles {
        if cycles >= CYCLES_END_OF_LIFE {
            c.findings.push(
                Finding::warn(
                    "Battery has been charged a great many times",
                    format!(
                        "This pack has been through {cycles} charge cycles. Most laptop \
                         batteries are designed for 300 to 500, so it is well past its \
                         intended service life even if it still tests reasonably."
                    ),
                )
                .evidence(format!("cycle_count {cycles}")),
            );
        } else if cycles >= CYCLES_WELL_USED {
            c.findings.push(
                Finding::info(
                    "Battery has seen regular use",
                    format!(
                        "This pack has been through {cycles} charge cycles, which is normal \
                         for a machine a few years old and worth knowing when judging the price."
                    ),
                )
                .evidence(format!("cycle_count {cycles}")),
            );
        }
    }
}

#[cfg(target_os = "linux")]
fn linux_batteries() -> Vec<Consumable> {
    use crate::platform::linux::{read_trimmed, read_u64};

    const BASE: &str = "/sys/class/power_supply";
    let mut out = Vec::new();

    let Ok(entries) = std::fs::read_dir(BASE) else {
        return out;
    };

    let mut names: Vec<_> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();

    for name in names {
        let dir = format!("{BASE}/{name}");
        // Only real batteries: mains adapters and USB-C sources live here too.
        if read_trimmed(format!("{dir}/type")).as_deref() != Some("Battery") {
            continue;
        }
        if read_u64(format!("{dir}/present")) == Some(0) {
            continue;
        }

        let model = read_trimmed(format!("{dir}/model_name"));
        let label = model.clone().unwrap_or_else(|| name.clone());
        let mut c = Consumable::new("battery", label);

        if let Some(v) = model {
            c.push("model", device(v, format!("sysfs:{dir}/model_name")));
        }
        if let Some(v) = read_trimmed(format!("{dir}/manufacturer")) {
            c.push(
                "manufacturer",
                device(v, format!("sysfs:{dir}/manufacturer")),
            );
        }
        if let Some(v) = read_trimmed(format!("{dir}/technology")) {
            c.push("technology", device(v, format!("sysfs:{dir}/technology")));
        }
        if let Some(v) = read_u64(format!("{dir}/cycle_count")) {
            c.push("cycleCount", device(v, format!("sysfs:{dir}/cycle_count")));
        }
        if let Some(v) = read_u64(format!("{dir}/capacity")) {
            c.push(
                "chargeNowPercent",
                kernel(v, format!("sysfs:{dir}/capacity")).unit("%"),
            );
        }
        if let Some(v) = read_trimmed(format!("{dir}/status")) {
            c.push("status", kernel(v, format!("sysfs:{dir}/status")));
        }

        // The kernel exposes a pack either in charge units (µAh) or energy
        // units (µWh) depending on what the firmware reports. Health is the
        // same ratio either way, so take whichever pair is present.
        let (full, design, unit_src) = if let (Some(f), Some(d)) = (
            read_u64(format!("{dir}/charge_full")),
            read_u64(format!("{dir}/charge_full_design")),
        ) {
            (Some(f), Some(d), "charge")
        } else if let (Some(f), Some(d)) = (
            read_u64(format!("{dir}/energy_full")),
            read_u64(format!("{dir}/energy_full_design")),
        ) {
            (Some(f), Some(d), "energy")
        } else {
            (None, None, "")
        };

        if let (Some(full), Some(design)) = (full, design) {
            if design > 0 {
                if unit_src == "charge" {
                    // Convert to watt-hours so the figure means something to a
                    // reader: µAh * µV / 1e12.
                    if let Some(mv) = read_u64(format!("{dir}/voltage_min_design")) {
                        let wh = |uah: u64| (uah as f64 * mv as f64) / 1e12;
                        c.push(
                            "designCapacityWh",
                            device(
                                round1(wh(design)),
                                format!("sysfs:{dir}/charge_full_design"),
                            )
                            .unit("Wh"),
                        );
                        c.push(
                            "currentCapacityWh",
                            device(round1(wh(full)), format!("sysfs:{dir}/charge_full")).unit("Wh"),
                        );
                    }
                } else {
                    c.push(
                        "designCapacityWh",
                        device(
                            round1(design as f64 / 1e6),
                            format!("sysfs:{dir}/energy_full_design"),
                        )
                        .unit("Wh"),
                    );
                    c.push(
                        "currentCapacityWh",
                        device(
                            round1(full as f64 / 1e6),
                            format!("sysfs:{dir}/energy_full"),
                        )
                        .unit("Wh"),
                    );
                }

                let health = (full as f64 / design as f64) * 100.0;
                c.push(
                    "healthPercent",
                    derived(
                        round1(health),
                        format!("sysfs:{dir}/{unit_src}_full divided by design"),
                    )
                    .unit("%"),
                );
            }
        }

        assess(&mut c);
        out.push(c);
    }

    out
}

/// Cross-platform reader used on Windows, where the crate wraps
/// `IOCTL_BATTERY_QUERY_INFORMATION` against the ACPI battery driver.
#[cfg(not(target_os = "linux"))]
fn portable_batteries() -> Vec<Consumable> {
    const SRC: &str = "ioctl:IOCTL_BATTERY_QUERY_INFORMATION";
    let mut out = Vec::new();

    let Ok(manager) = starship_battery::Manager::new() else {
        return out;
    };
    let Ok(batteries) = manager.batteries() else {
        return out;
    };

    for (i, b) in batteries.flatten().enumerate() {
        let label = b
            .model()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Battery {}", i + 1));
        let mut c = Consumable::new("battery", label);

        if let Some(v) = b.model() {
            c.push("model", device(v.to_owned(), format!("{SRC}.DeviceName")));
        }
        if let Some(v) = b.vendor() {
            c.push(
                "manufacturer",
                device(v.to_owned(), format!("{SRC}.ManufactureName")),
            );
        }
        c.push(
            "technology",
            device(b.technology().to_string(), format!("{SRC}.Chemistry")),
        );

        if let Some(v) = b.cycle_count() {
            c.push(
                "cycleCount",
                device(u64::from(v), format!("{SRC}.CycleCount")),
            );
        }

        let design = b.energy_full_design().value; // watt-hours
        let full = b.energy_full().value;
        c.push(
            "designCapacityWh",
            device(round1(f64::from(design)), format!("{SRC}.DesignedCapacity")).unit("Wh"),
        );
        c.push(
            "currentCapacityWh",
            device(
                round1(f64::from(full)),
                format!("{SRC}.FullChargedCapacity"),
            )
            .unit("Wh"),
        );
        if design > 0.0 {
            c.push(
                "healthPercent",
                derived(
                    round1(f64::from(full / design) * 100.0),
                    format!("{SRC}: FullChargedCapacity divided by DesignedCapacity"),
                )
                .unit("%"),
            );
        }

        assess(&mut c);
        out.push(c);
    }

    out
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fact::derived as d;

    fn with(health: Option<f64>, cycles: Option<i64>) -> Consumable {
        let mut c = Consumable::new("battery", "Test pack");
        if let Some(h) = health {
            c.push("healthPercent", d(h, "test"));
        }
        if let Some(n) = cycles {
            c.push("cycleCount", d(n, "test"));
        }
        assess(&mut c);
        c
    }

    #[test]
    fn healthy_pack_reads_good() {
        let c = with(Some(94.0), Some(120));
        assert_eq!(c.verdict, Verdict::Good);
        assert!(c.findings.is_empty());
    }

    #[test]
    fn worn_pack_reads_fair_and_warns() {
        let c = with(Some(71.0), Some(400));
        assert_eq!(c.verdict, Verdict::Fair);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("lost some capacity")));
    }

    #[test]
    fn spent_pack_reads_poor() {
        let c = with(Some(44.0), Some(900));
        assert_eq!(c.verdict, Verdict::Poor);
        assert!(c.findings.iter().any(|f| f.title.contains("worn out")));
    }

    #[test]
    fn perfect_health_at_high_cycles_is_called_out_not_believed() {
        // The real case this machine presents: 100% health, 766 cycles. A pack
        // charged 766 times has not kept every last percent, so the tool must
        // refuse to report Good here.
        let c = with(Some(100.0), Some(766));
        assert_eq!(c.verdict, Verdict::Unknown);
        assert!(c.findings.iter().any(|f| f.title.contains("unreliable")));
        assert!(c.headline.contains("766"));
    }

    #[test]
    fn perfect_health_on_a_nearly_new_pack_is_believed() {
        let c = with(Some(100.0), Some(12));
        assert_eq!(c.verdict, Verdict::Good);
    }

    #[test]
    fn missing_health_is_unknown_not_poor() {
        // Absence of evidence must never be reported as bad news.
        let c = with(None, Some(50));
        assert_eq!(c.verdict, Verdict::Unknown);
    }

    #[test]
    fn high_cycle_count_is_flagged_even_when_health_is_fine() {
        let c = with(Some(85.0), Some(1100));
        assert_eq!(c.verdict, Verdict::Good);
        assert!(c
            .findings
            .iter()
            .any(|f| f.title.contains("great many times")));
    }
}
