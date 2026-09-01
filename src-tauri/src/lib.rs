//! The desktop shell.
//!
//! All the thinking lives in `refurbman-probe`; this crate only exposes it to
//! the interface and handles the two things a GUI has to deal with that a CLI
//! does not: asking for privileges, and letting the user pick where to save a
//! report.

use std::path::PathBuf;
use std::sync::Mutex;

use refurbman_probe::{platform, report_html, scan, Report};
use serde::Serialize;

/// The most recent scan, kept so a report can be rendered from exactly the
/// value the window is showing rather than from a copy sent back over the
/// bridge.
#[derive(Default)]
struct LastScan(Mutex<Option<Report>>);

impl LastScan {
    /// Take the lock, recovering it if a previous holder panicked.
    ///
    /// There is no invariant here to protect, only the most recent report, so
    /// a poisoned lock is worth recovering rather than propagating. Refusing
    /// would disable saving for the life of the process, and the user would
    /// see scans succeed while Save report failed forever.
    fn lock(&self) -> std::sync::MutexGuard<'_, Option<Report>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// What the interface needs to know before it has run anything.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Readiness {
    /// Whether this process can already talk to devices.
    pub privileged: bool,
    /// The platform, so the interface can word the elevation prompt correctly:
    /// "Run as administrator" means nothing on Linux.
    pub platform: String,
    /// Whether relaunching with privileges is something we can actually offer.
    /// On Linux that needs a polkit agent; without one the button would open a
    /// prompt nobody ever sees.
    pub can_elevate: bool,
    pub tool_version: String,
}

#[tauri::command]
fn readiness() -> Readiness {
    Readiness {
        privileged: platform::is_privileged(),
        platform: std::env::consts::OS.to_owned(),
        can_elevate: can_elevate(),
        tool_version: refurbman_probe::VERSION.to_owned(),
    }
}

/// Run a full scan. Returns the report as JSON.
///
/// This blocks for a second or two while smartctl is asked about each drive, so
/// it runs on Tauri's blocking pool rather than the async runtime; holding the
/// latter up would freeze the window.
#[tauri::command(async)]
fn run_scan(state: tauri::State<'_, LastScan>) -> Result<serde_json::Value, String> {
    let report = scan::run();
    let json =
        serde_json::to_value(&report).map_err(|e| format!("Could not prepare the report: {e}"))?;
    if let Ok(mut last) = state.0.lock() {
        *last = Some(report);
    }
    Ok(json)
}

/// Save an already-rendered report, so exporting does not rescan the machine.
///
/// Rescanning would be slower and, worse, could produce a document that differs
/// from what the user is looking at.
#[tauri::command(async)]
fn save_html(path: String, html: String) -> Result<String, String> {
    let path = PathBuf::from(path);
    std::fs::write(&path, html).map_err(|e| format!("Could not write {}: {e}", path.display()))?;
    Ok(path.display().to_string())
}

/// Render the most recent scan as HTML, without touching the disk.
#[tauri::command(async)]
fn render_html(state: tauri::State<'_, LastScan>) -> Result<String, String> {
    // Cloned so the lock is released before rendering. Holding it across the
    // render would mean a panic in there poisons the report for good.
    let report = state
        .lock()
        .clone()
        .ok_or_else(|| "Nothing has been checked yet.".to_owned())?;
    Ok(report_html::render(&report))
}

/// Whether an elevation path exists on this machine.
fn can_elevate() -> bool {
    if platform::is_privileged() {
        return false;
    }
    #[cfg(target_os = "linux")]
    {
        // pkexec without a running polkit agent opens a prompt the user never
        // sees, so the button is only offered when one is present.
        which("pkexec") && polkit_agent_running()
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

#[cfg(target_os = "linux")]
fn which(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(name).is_file()))
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn polkit_agent_running() -> bool {
    // A desktop session normally has an agent; a bare tty or a stripped
    // container does not.
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return false;
    };
    for e in entries.flatten() {
        let name = e.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        if let Ok(cmd) = std::fs::read_to_string(e.path().join("cmdline")) {
            if cmd.contains("polkit") && cmd.contains("agent") {
                return true;
            }
        }
    }
    false
}

/// Relaunch with privileges so drives can be asked about their own health.
///
/// The running unprivileged window stays open on purpose. If authentication is
/// cancelled or fails, the user still has the partial report in front of them
/// rather than an application that vanished.
#[tauri::command(async)]
fn relaunch_elevated() -> Result<(), String> {
    let exe =
        std::env::current_exe().map_err(|e| format!("Could not find the application: {e}"))?;

    #[cfg(target_os = "linux")]
    {
        // Pass the session through so the relaunched window can find the
        // display. pkexec clears the environment by default.
        let mut cmd = std::process::Command::new("pkexec");
        for var in [
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "XAUTHORITY",
            "XDG_RUNTIME_DIR",
        ] {
            if let Ok(v) = std::env::var(var) {
                cmd.arg(format!("{var}={v}"));
            }
        }
        cmd.arg(&exe);
        cmd.spawn()
            .map(|_| ())
            .map_err(|e| format!("Could not ask for permission: {e}"))
    }

    #[cfg(target_os = "windows")]
    {
        // "runas" is what raises the consent dialog. Spawning through the shell
        // is the documented way to request it for an already-running process.
        std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-WindowStyle",
                "Hidden",
                "-Command",
                &format!("Start-Process -FilePath '{}' -Verb RunAs", exe.display()),
            ])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("Could not ask for permission: {e}"))
    }

    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        let _ = exe;
        Err("Raising privileges is not supported on this platform.".to_owned())
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(LastScan::default())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            readiness,
            run_scan,
            save_html,
            render_html,
            relaunch_elevated
        ])
        .run(tauri::generate_context!())
        .expect("could not start RefurbMan");
}
