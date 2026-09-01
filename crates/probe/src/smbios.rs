//! Board, firmware and memory-slot facts from the SMBIOS tables.
//!
//! On Linux these come from `/sys/firmware/dmi/tables`, on Windows from
//! `GetSystemFirmwareTable('RSMB')`. Both are the firmware's own tables passed
//! through by the kernel, so changing what they say means reflashing the BIOS.
//! That puts them a long way above anything in the registry, though still below
//! what a device reports about itself.
//!
//! Type 17 (Memory Device) is the valuable part: it describes each physical
//! stick, which is how you catch a machine advertised with 16GB that turns out
//! to be one 8GB stick in a two-slot board.

use smbioslib::*;

use crate::fact::{firmware, Fact};
use crate::report::{Component, Facts};

/// Strings OEMs leave in SMBIOS when they cannot be bothered to fill a field.
///
/// Showing "To Be Filled By O.E.M." to someone deciding whether to buy a laptop
/// is worse than showing nothing, because it looks like a reading.
const PLACEHOLDERS: &[&str] = &[
    "to be filled by o.e.m.",
    "to be filled by oem",
    "default string",
    "not specified",
    "not applicable",
    "none",
    "unknown",
    "system manufacturer",
    "system product name",
    "system version",
    "system serial number",
    "oem",
    "o.e.m.",
    "chassis manufacture",
    "chassis serial number",
    "无",
    "x.x.",
    "0123456789",
    "................",
];

/// Normalise an SMBIOS string, dropping OEM placeholder junk.
pub(crate) fn clean(raw: &str) -> Option<String> {
    let t = raw.trim();
    if t.is_empty() {
        return None;
    }
    let lower = t.to_ascii_lowercase();
    if PLACEHOLDERS.contains(&lower.as_str()) {
        return None;
    }
    // Fields padded out with a single repeated character carry no information.
    if t.len() > 3 && t.chars().all(|c| c == t.chars().next().unwrap()) {
        return None;
    }
    Some(t.to_owned())
}

fn s(v: &SMBiosString) -> Option<String> {
    clean(&v.to_string())
}

/// Insert a firmware-sourced fact only when the value survived cleaning.
fn put(facts: &mut Facts, key: &str, value: Option<String>, source: &str) {
    if let Some(v) = value {
        facts.insert(key.to_owned(), firmware(v, source));
    }
}

/// Everything the SMBIOS tables gave us.
#[derive(Default)]
pub struct Smbios {
    /// Machine identity: manufacturer, model, serial, board, BIOS.
    pub system: Facts,
    /// One component per populated memory slot.
    pub memory_slots: Vec<Component>,
    /// Total capacity across populated slots, in bytes. Cross-checked against
    /// the kernel's own total by the tamper pass.
    pub memory_total_bytes: u64,
    /// Slots the board has, whether or not they hold a stick.
    pub slots_total: usize,
    pub slots_populated: usize,
    /// CPU model as the firmware describes it, for cross-checking against what
    /// the `CPUID` instruction reports.
    pub cpu_version: Option<String>,
    /// Set when the full table was unavailable and a reduced source was used.
    /// Surfaced to the user rather than swallowed, so a short section is never
    /// mistaken for a machine with little in it.
    pub degraded: Option<String>,
}

/// Read and interpret the firmware tables, degrading rather than failing.
///
/// The raw table is the good path: it carries the per-slot memory records that
/// make this tool useful. On Linux it needs root, so when that fails we fall
/// back to `/sys/class/dmi/id`, where the kernel exports the same firmware
/// fields individually with make and model world-readable and only the serials
/// restricted. A buyer therefore gets the machine identified without a password
/// prompt, and is asked to unlock only for the parts that genuinely need it.
///
/// On Windows `GetSystemFirmwareTable` needs no elevation, so the good path is
/// taken there either way.
pub fn probe() -> Smbios {
    match table_load_from_device() {
        Ok(data) => {
            let mut s = interpret(&data);
            // The raw table wins where both have an opinion, but sysfs
            // occasionally carries a field the table left blank.
            for (k, v) in crate::platform::host::dmi_id_facts() {
                s.system.entry(k).or_insert(v);
            }
            s
        }
        Err(e) => Smbios {
            system: crate::platform::host::dmi_id_facts(),
            degraded: Some(format!(
                "Could not read the raw firmware table ({e}). Machine identity came from \
                 the kernel's DMI export instead; memory slot detail and serial numbers \
                 need a full scan."
            )),
            ..Default::default()
        },
    }
}

/// Split from [`probe`] so tests can feed a table captured from a file.
pub fn interpret(data: &SMBiosData) -> Smbios {
    let mut out = Smbios::default();

    for undefined in data.iter() {
        match undefined.defined_struct() {
            DefinedStruct::Information(bios) => {
                put(
                    &mut out.system,
                    "biosVendor",
                    s(&bios.vendor()),
                    "smbios:type0.vendor",
                );
                put(
                    &mut out.system,
                    "biosVersion",
                    s(&bios.version()),
                    "smbios:type0.bios_version",
                );
                put(
                    &mut out.system,
                    "biosDate",
                    s(&bios.release_date()),
                    "smbios:type0.bios_release_date",
                );
            }
            DefinedStruct::SystemInformation(sys) => {
                put(
                    &mut out.system,
                    "manufacturer",
                    s(&sys.manufacturer()),
                    "smbios:type1.manufacturer",
                );
                put(
                    &mut out.system,
                    "model",
                    s(&sys.product_name()),
                    "smbios:type1.product_name",
                );
                put(
                    &mut out.system,
                    "version",
                    s(&sys.version()),
                    "smbios:type1.version",
                );
                put(
                    &mut out.system,
                    "serialNumber",
                    s(&sys.serial_number()),
                    "smbios:type1.serial_number",
                );
                put(
                    &mut out.system,
                    "family",
                    s(&sys.family()),
                    "smbios:type1.family",
                );
            }
            DefinedStruct::BaseBoardInformation(board) => {
                put(
                    &mut out.system,
                    "boardVendor",
                    s(&board.manufacturer()),
                    "smbios:type2.manufacturer",
                );
                put(
                    &mut out.system,
                    "boardModel",
                    s(&board.product()),
                    "smbios:type2.product",
                );
                put(
                    &mut out.system,
                    "boardSerial",
                    s(&board.serial_number()),
                    "smbios:type2.serial_number",
                );
            }
            DefinedStruct::ProcessorInformation(cpu) => {
                if out.cpu_version.is_none() {
                    out.cpu_version = s(&cpu.processor_version());
                }
            }
            DefinedStruct::MemoryDevice(mem) => {
                out.slots_total += 1;
                let locator =
                    s(&mem.device_locator()).unwrap_or_else(|| format!("Slot {}", out.slots_total));
                let bytes = memory_device_bytes(&mem);

                // An empty slot is worth reporting: "16GB in one of two slots"
                // is a materially different machine from "16GB in two".
                let Some(bytes) = bytes.filter(|b| *b > 0) else {
                    continue;
                };
                out.slots_populated += 1;
                out.memory_total_bytes += bytes;

                let mut c = Component::new("memory", locator.clone());
                c.push(
                    "sizeBytes",
                    firmware(bytes, "smbios:type17.size").unit("bytes"),
                );
                c.push("slot", firmware(locator, "smbios:type17.device_locator"));
                if let Some(t) = mem.memory_type() {
                    c.push(
                        "type",
                        firmware(format!("{:?}", t.value), "smbios:type17.memory_type"),
                    );
                }
                if let Some(sp) = mem.speed() {
                    if let Some(mts) = speed_mts(&sp) {
                        c.push(
                            "speedMts",
                            firmware(mts, "smbios:type17.speed").unit("MT/s"),
                        );
                    }
                }
                if let Some(sp) = mem.configured_memory_speed() {
                    if let Some(mts) = speed_mts(&sp) {
                        c.push(
                            "configuredSpeedMts",
                            firmware(mts, "smbios:type17.configured_memory_speed").unit("MT/s"),
                        );
                    }
                }
                if let Some(v) = s(&mem.manufacturer()) {
                    c.push("manufacturer", firmware(v, "smbios:type17.manufacturer"));
                }
                if let Some(v) = s(&mem.part_number()) {
                    c.push("partNumber", firmware(v, "smbios:type17.part_number"));
                }
                out.memory_slots.push(c);
            }
            _ => {}
        }
    }

    if out.slots_total > 0 {
        out.system.insert(
            "memorySlotsTotal".into(),
            firmware(out.slots_total as u64, "smbios:type17.count"),
        );
        out.system.insert(
            "memorySlotsPopulated".into(),
            firmware(out.slots_populated as u64, "smbios:type17.populated"),
        );
    }

    out
}

/// Size of one memory device in bytes.
///
/// SMBIOS encodes this in two places: the 16-bit `size` field, which escapes to
/// the 32-bit `extended_size` field for sticks of 32GB and above. Reading only
/// the first would under-report large modules.
fn memory_device_bytes(mem: &SMBiosMemoryDevice) -> Option<u64> {
    match mem.size() {
        Some(MemorySize::Kilobytes(kb)) => Some(u64::from(kb) * 1024),
        Some(MemorySize::Megabytes(mb)) => Some(u64::from(mb) * 1024 * 1024),
        Some(MemorySize::SeeExtendedSize) => match mem.extended_size() {
            Some(MemorySizeExtended::Megabytes(mb)) => Some(u64::from(mb) * 1024 * 1024),
            _ => None,
        },
        _ => None,
    }
}

fn speed_mts(speed: &MemorySpeed) -> Option<u64> {
    match speed {
        MemorySpeed::MTs(v) => Some(u64::from(*v)),
        _ => None,
    }
}

/// Facts describing the firmware tables themselves, so a report records
/// whether this section was readable at all.
pub fn availability_fact(ok: bool) -> Fact {
    firmware(ok, "smbios:table_load_from_device")
}

/// Cleaning exposed for the sysfs DMI fallback, which reads the same firmware
/// fields through a different kernel interface and hits the same OEM junk.
pub fn clean_public(raw: &str) -> Option<String> {
    clean(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_strings_are_dropped() {
        assert_eq!(clean("To Be Filled By O.E.M."), None);
        assert_eq!(clean("Default string"), None);
        assert_eq!(clean("  "), None);
        assert_eq!(clean("................"), None);
        assert_eq!(clean("Unknown"), None);
    }

    #[test]
    fn real_values_survive_cleaning() {
        assert_eq!(clean("  LENOVO  "), Some("LENOVO".into()));
        assert_eq!(clean("Micron Technology"), Some("Micron Technology".into()));
        // Short repeated strings are plausible values, so are kept.
        assert_eq!(clean("AAA"), Some("AAA".into()));
    }
}
