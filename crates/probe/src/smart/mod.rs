//! Drive health, by way of smartmontools.
//!
//! `smartctl` is invoked as a separate program and asked for JSON. It is doing
//! the part that is genuinely hard: encoding an NVMe admin Get-Log-Page or an
//! ATA SMART command, and knowing the per-vendor quirks of the USB-to-SATA
//! bridges that external drives hide behind. Twenty years of that knowledge
//! lives in its drive database, and getting it wrong does not produce no answer,
//! it produces a confidently wrong one.
//!
//! Everything smartctl returns came from the drive's own controller, so it
//! carries [`Trust::Device`].
//!
//! [`Trust::Device`]: crate::fact::Trust::Device

pub mod parse;

use std::path::PathBuf;
use std::process::Command;

use serde_json::Value as Json;

/// A drive smartctl knows how to open.
#[derive(Debug, Clone)]
pub struct DeviceRef {
    /// Path to pass back to smartctl, such as `/dev/nvme0` or `/dev/sda`.
    pub name: String,
    /// smartctl's device type, such as `nvme` or `sat`.
    pub kind: Option<String>,
    /// Present when smartctl could see the device but not open it, which
    /// almost always means the scan is running without privileges.
    pub open_error: Option<String>,
}

/// Locates and runs the smartctl binary.
pub struct Smartctl {
    binary: PathBuf,
}

impl Smartctl {
    /// Find smartctl, preferring the copy shipped beside the application.
    ///
    /// A bundled binary means a buyer gets the same answers regardless of what
    /// the machine they are testing happens to have installed, which matters
    /// when the machine belongs to the seller.
    pub fn locate() -> Option<Self> {
        for candidate in Self::candidates() {
            if candidate.is_file() {
                return Some(Smartctl { binary: candidate });
            }
        }
        // Fall back to whatever is on PATH.
        let name = if cfg!(windows) {
            "smartctl.exe"
        } else {
            "smartctl"
        };
        let out = Command::new(name).arg("--version").output().ok()?;
        out.status.success().then(|| Smartctl {
            binary: PathBuf::from(name),
        })
    }

    fn candidates() -> Vec<PathBuf> {
        let exe = std::env::current_exe().ok();
        let dir = exe.as_ref().and_then(|p| p.parent()).map(PathBuf::from);
        let name = if cfg!(windows) {
            "smartctl.exe"
        } else {
            "smartctl"
        };

        let mut v = Vec::new();
        if let Some(dir) = dir {
            v.push(dir.join(name));
            v.push(dir.join("smartmontools").join(name));
            // Tauri lays resources out beside the executable on Windows and
            // under ../lib on Linux packages.
            v.push(dir.join("..").join("lib").join("refurbman").join(name));
        }
        v
    }

    pub fn binary(&self) -> &PathBuf {
        &self.binary
    }

    /// Version string, recorded in the report so a reader can reproduce it.
    pub fn version(&self) -> Option<String> {
        let out = Command::new(&self.binary).arg("--version").output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        text.lines().next().map(|l| l.trim().to_owned())
    }

    /// Enumerate drives. Works without privileges: devices that cannot be
    /// opened come back carrying their `open_error`, which is how the scan
    /// knows to prompt for elevation rather than report an empty machine.
    pub fn scan(&self) -> anyhow::Result<Vec<DeviceRef>> {
        let json = self.run(&["--json=c", "--scan-open"])?;
        Ok(parse::devices(&json))
    }

    /// Full health report for one drive.
    pub fn inspect(&self, dev: &DeviceRef) -> anyhow::Result<Json> {
        let mut args = vec!["--json=c".to_string(), "-a".to_string()];
        if let Some(k) = &dev.kind {
            args.push("-d".into());
            args.push(k.clone());
        }
        args.push(dev.name.clone());
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run(&refs)
    }

    /// Run smartctl and parse its JSON.
    ///
    /// A non-zero exit is not treated as failure: smartctl uses its exit code
    /// as a bitfield, and sets bits for things like "drive is failing", which
    /// is precisely the case we most want the output for.
    fn run(&self, args: &[&str]) -> anyhow::Result<Json> {
        let out = Command::new(&self.binary).args(args).output()?;
        let text = String::from_utf8_lossy(&out.stdout);
        if text.trim().is_empty() {
            anyhow::bail!(
                "smartctl produced no output (exit {:?}): {}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(serde_json::from_str(&text)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_output_is_parsed_including_permission_errors() {
        // Real output from this machine, unprivileged.
        let json: Json = serde_json::from_str(
            r#"{"json_format_version":[1,0],
                "devices":[{"name":"/dev/nvme0","info_name":"/dev/nvme0",
                            "type":"nvme","protocol":"NVMe",
                            "open_error":"Permission denied"}]}"#,
        )
        .unwrap();
        let devs = parse::devices(&json);
        assert_eq!(devs.len(), 1);
        assert_eq!(devs[0].name, "/dev/nvme0");
        assert_eq!(devs[0].kind.as_deref(), Some("nvme"));
        assert_eq!(devs[0].open_error.as_deref(), Some("Permission denied"));
    }
}
