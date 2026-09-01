//! The provenance model.
//!
//! Every value RefurbMan reports is wrapped in a [`Fact`] that records where it
//! came from. That is the entire point of the tool: a seller can trivially edit
//! the Windows registry or a WMI provider to claim a pristine 2TB drive, but
//! they cannot easily forge what the storage controller returns over an NVMe
//! admin command, or what the ACPI battery driver hands the kernel.
//!
//! Sources are ranked by how hard they are to tamper with, and the UI surfaces
//! that rank so a non-technical buyer can see at a glance which numbers deserve
//! weight.

use serde::{Serialize, Serializer};

/// How resistant to tampering the origin of a value is.
///
/// Ordering matters: the UI sorts and colours by it, and [`Report`] summarises
/// the weakest link. Higher is harder to fake.
///
/// [`Report`]: crate::report::Report
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Trust {
    /// Mutable userspace configuration. Never used for a hardware claim, only
    /// for cosmetic things like the OS product name.
    Software = 0,
    /// Computed by RefurbMan from one or more of the sources below.
    Derived = 1,
    /// Read from the firmware tables (SMBIOS/DMI) that the kernel exposes
    /// verbatim. Faking this means reflashing the BIOS.
    Firmware = 2,
    /// Read from the kernel's own live state: sysfs, procfs, or a syscall.
    /// Faking this means patching a running kernel.
    Kernel = 3,
    /// The device itself answered, over a command the OS merely forwards: NVMe
    /// admin passthrough, ATA SMART, an ACPI battery IOCTL. Faking this means
    /// reflashing device firmware.
    Device = 4,
}

impl Trust {
    /// Short label shown on the provenance chip in the UI.
    pub fn label(self) -> &'static str {
        match self {
            Trust::Software => "Software",
            Trust::Derived => "Calculated",
            Trust::Firmware => "System firmware",
            Trust::Kernel => "Kernel",
            Trust::Device => "Device firmware",
        }
    }

    /// One sentence a non-technical reader can act on, shown on hover or tap.
    pub fn explanation(self) -> &'static str {
        match self {
            Trust::Software => {
                "Comes from software settings, which anyone can edit. Not proof of hardware."
            }
            Trust::Derived => "Worked out by RefurbMan from the readings below it.",
            Trust::Firmware => {
                "Comes from the motherboard firmware. Changing it means reflashing the BIOS."
            }
            Trust::Kernel => "Comes from the operating system kernel's own view of the hardware.",
            Trust::Device => {
                "The part itself reported this. Changing it means reflashing the part's firmware."
            }
        }
    }

    /// Whether a value at this rank is strong enough to base a purchase on.
    pub fn is_tamper_resistant(self) -> bool {
        self >= Trust::Firmware
    }
}

impl Serialize for Trust {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u8(*self as u8)
    }
}

/// A value the UI can render as text, a number, or a yes/no.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Value {
    Text(String),
    Int(i64),
    Float(f64),
    Bool(bool),
}

impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Text(v)
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Text(v.to_owned())
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v)
    }
}
impl From<u64> for Value {
    fn from(v: u64) -> Self {
        Value::Int(v as i64)
    }
}
impl From<u32> for Value {
    fn from(v: u32) -> Self {
        Value::Int(v as i64)
    }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::Float(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}

/// A single measured value, plus the exact path or call it came from.
///
/// `source` is deliberately literal (`sysfs:/sys/class/power_supply/BAT0/charge_full_design`,
/// `smartctl:nvme_smart_health_information_log.percentage_used`) so that a
/// sceptical reader can go and check it by hand. That auditability is what
/// separates this from a tool that just asserts numbers.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fact {
    pub value: Value,
    pub source: String,
    pub trust: Trust,
    pub trust_label: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
}

impl Fact {
    pub fn new(value: impl Into<Value>, source: impl Into<String>, trust: Trust) -> Self {
        Fact {
            value: value.into(),
            source: source.into(),
            trust,
            trust_label: trust.label(),
            unit: None,
        }
    }

    /// Attach a unit such as `GB`, `MHz`, `hours`. The UI renders it after the
    /// number rather than baking it into the string, so exports stay numeric.
    pub fn unit(mut self, unit: impl Into<String>) -> Self {
        self.unit = Some(unit.into());
        self
    }
}

/// The device itself answered. See [`Trust::Device`].
pub fn device(value: impl Into<Value>, source: impl Into<String>) -> Fact {
    Fact::new(value, source, Trust::Device)
}

/// The kernel's live state. See [`Trust::Kernel`].
pub fn kernel(value: impl Into<Value>, source: impl Into<String>) -> Fact {
    Fact::new(value, source, Trust::Kernel)
}

/// SMBIOS or another firmware table. See [`Trust::Firmware`].
pub fn firmware(value: impl Into<Value>, source: impl Into<String>) -> Fact {
    Fact::new(value, source, Trust::Firmware)
}

/// Computed by RefurbMan. See [`Trust::Derived`].
pub fn derived(value: impl Into<Value>, source: impl Into<String>) -> Fact {
    Fact::new(value, source, Trust::Derived)
}

/// Mutable userspace string. See [`Trust::Software`].
pub fn software(value: impl Into<Value>, source: impl Into<String>) -> Fact {
    Fact::new(value, source, Trust::Software)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_orders_device_above_everything() {
        assert!(Trust::Device > Trust::Kernel);
        assert!(Trust::Kernel > Trust::Firmware);
        assert!(Trust::Firmware > Trust::Derived);
        assert!(Trust::Derived > Trust::Software);
    }

    #[test]
    fn software_claims_are_never_treated_as_evidence() {
        // The whole tool rests on this: a registry-grade source must never
        // pass the bar that a hardware claim is allowed to rest on.
        assert!(!Trust::Software.is_tamper_resistant());
        assert!(!Trust::Derived.is_tamper_resistant());
        assert!(Trust::Firmware.is_tamper_resistant());
        assert!(Trust::Device.is_tamper_resistant());
    }

    #[test]
    fn fact_serialises_with_its_provenance_intact() {
        let f = device(3_i64, "smartctl:nvme.percentage_used").unit("%");
        let j = serde_json::to_value(&f).unwrap();
        assert_eq!(j["value"], 3);
        assert_eq!(j["source"], "smartctl:nvme.percentage_used");
        assert_eq!(j["trust"], 4);
        assert_eq!(j["trustLabel"], "Device firmware");
        assert_eq!(j["unit"], "%");
    }

    #[test]
    fn unit_is_omitted_rather_than_null_when_absent() {
        let j = serde_json::to_value(kernel("Fedora", "os-release")).unwrap();
        assert!(j.get("unit").is_none());
    }
}
