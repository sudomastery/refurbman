//! Headless CLI for the probe engine.
//!
//! Emits the same report the desktop application renders, so a power user can
//! script it and continuous integration can assert on it.

use refurbman_probe::fact::{Trust, Value};
use refurbman_probe::report::{display_fields, CheckStatus, Report, Severity, Verdict};
use refurbman_probe::{scan, VERSION};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().any(|a| a == "--json" || a == "-j");
    let color = !args.iter().any(|a| a == "--no-color")
        && std::io::IsTerminal::is_terminal(&std::io::stdout());

    if args.iter().any(|a| a == "-h" || a == "--help") {
        print_help();
        return;
    }
    if args.iter().any(|a| a == "-V" || a == "--version") {
        println!("refurbman-probe {VERSION}");
        return;
    }

    let report = scan::run();

    // --html <path> writes a self-contained document. Any browser turns it
    // into a PDF with Print, which avoids bundling a PDF engine for a job the
    // reader already has one for.
    if let Some(i) = args.iter().position(|a| a == "--html") {
        let Some(path) = args.get(i + 1) else {
            eprintln!("--html needs a file to write to, for example: --html report.html");
            std::process::exit(2);
        };
        let html = refurbman_probe::report_html::render(&report);
        if let Err(e) = std::fs::write(path, html) {
            eprintln!("Could not write {path}: {e}");
            std::process::exit(1);
        }
        println!("Report written to {path}");
        println!("Open it in a browser and choose Print, then Save as PDF, for a PDF copy.");
        return;
    }

    if json {
        match serde_json::to_string_pretty(&report) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("Could not render the report: {e}");
                std::process::exit(1);
            }
        }
        return;
    }

    render(&report, color);
}

fn print_help() {
    println!(
        "refurbman-probe {VERSION}

Reads what is really in this machine, and how worn its parts are, from the
kernel, the firmware tables and the devices themselves.

USAGE:
    refurbman-probe [OPTIONS]

OPTIONS:
    -j, --json        Emit the full report as JSON
        --html FILE   Write a self-contained HTML report, ready to print to PDF
        --no-color    Disable colour
    -h, --help        Show this help
    -V, --version     Show the version

A full check needs root or administrator rights, because asking a drive about
its own health requires direct device access. Without them the machine is still
identified and the report says what it could not read."
    );
}

struct Paint(bool);

impl Paint {
    fn c(&self, code: &str, s: &str) -> String {
        if self.0 {
            format!("\x1b[{code}m{s}\x1b[0m")
        } else {
            s.to_owned()
        }
    }
    fn dim(&self, s: &str) -> String {
        self.c("90", s)
    }
    fn bold(&self, s: &str) -> String {
        self.c("1", s)
    }
    fn verdict(&self, v: Verdict, s: &str) -> String {
        self.c(
            match v {
                Verdict::Good => "32",
                Verdict::Fair => "33",
                Verdict::Poor => "31",
                Verdict::Unknown => "90",
            },
            s,
        )
    }
    fn trust(&self, t: Trust) -> String {
        let (code, label) = match t {
            Trust::Device => ("32", "DEVICE  "),
            Trust::Kernel => ("36", "KERNEL  "),
            Trust::Firmware => ("34", "FIRMWARE"),
            Trust::Derived => ("90", "CALC    "),
            Trust::Software => ("33", "SOFTWARE"),
        };
        self.c(code, label)
    }
}

fn show(v: &Value) -> String {
    match v {
        Value::Text(s) => s.clone(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => format!("{f:.1}"),
        Value::Bool(b) => (if *b { "yes" } else { "no" }).to_owned(),
    }
}

fn rule(p: &Paint, title: &str) {
    let pad = 78usize.saturating_sub(title.len() + 4);
    println!("{}", p.c("36", &format!("-- {title} {}", "-".repeat(pad))));
}

fn row(p: &Paint, label: &str, f: &refurbman_probe::Fact) {
    let mut text = show(&f.value);
    if let Some(u) = &f.unit {
        if u != "bytes" {
            text = format!("{text} {u}");
        }
    }
    println!("  {label:<22} {:<40} {}", p.bold(&text), p.trust(f.trust));
}

fn gauge(p: &Paint, label: &str, percent: Option<f64>, v: Verdict) {
    let name = format!("{v:?}").to_uppercase();
    match percent {
        None => println!(
            "  {label:<22} {:<40} {}",
            p.dim("not reported"),
            p.verdict(v, &name)
        ),
        Some(pct) => {
            let width = 24usize;
            let filled = ((pct / 100.0) * width as f64)
                .round()
                .clamp(0.0, width as f64) as usize;
            let bar = format!("{}{}", "#".repeat(filled), ".".repeat(width - filled));
            println!(
                "  {label:<22} {} {:>4.0}%   {}",
                p.verdict(v, &format!("[{bar}]")),
                pct,
                p.verdict(v, &name)
            );
        }
    }
}

fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        if line.is_empty() {
            line = word.to_owned();
        } else if line.len() + 1 + word.len() <= width {
            line.push(' ');
            line.push_str(word);
        } else {
            out.push(std::mem::take(&mut line));
            line = word.to_owned();
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

fn render(r: &Report, color: bool) {
    let p = Paint(color);

    println!();
    for line in BANNER.lines() {
        println!("{}", p.c("36", line));
    }
    println!(
        "{}",
        p.dim("  what is really in this machine, and how worn it is")
    );
    println!();

    // --- identity ---
    rule(&p, "This machine");
    println!();
    let name = ["manufacturer", "model"]
        .iter()
        .filter_map(|k| r.system.get(*k).map(|f| show(&f.value)))
        .collect::<Vec<_>>()
        .join(" ");
    if !name.is_empty() {
        println!("  {}", p.bold(&name));
    }
    if let Some(c) = r.system.get("chassis") {
        println!("  {}", p.dim(&show(&c.value)));
    }
    println!();
    for (label, key) in [
        ("Manufacturer", "manufacturer"),
        ("Model", "model"),
        ("Serial number", "serialNumber"),
        ("Motherboard", "boardModel"),
        ("BIOS version", "biosVersion"),
        ("BIOS date", "biosDate"),
    ] {
        if let Some(f) = r.system.get(key) {
            row(&p, label, f);
        }
    }

    // --- components ---
    for (kind, title) in [("cpu", "Processor"), ("memory", "Memory")] {
        let items: Vec<_> = r.components.iter().filter(|c| c.kind == kind).collect();
        if items.is_empty() {
            continue;
        }
        println!();
        rule(&p, title);
        if kind == "memory" {
            println!();
            for key in ["memoryInstalled", "memoryUsable"] {
                if let Some(f) = r.system.get(key) {
                    let label = if key == "memoryUsable" {
                        "System can use"
                    } else {
                        "Installed"
                    };
                    row(&p, label, f);
                }
            }
        }
        for c in items {
            println!();
            if kind == "memory" {
                println!("  {}", p.bold(&c.name));
            }
            for (key, label) in display_fields(kind) {
                if let Some(f) = c.facts.get(*key) {
                    row(&p, label, f);
                }
            }
        }
    }

    // --- consumables ---
    for (kind, title) in [("storage", "Storage"), ("battery", "Battery")] {
        let items: Vec<_> = r.consumables.iter().filter(|c| c.kind == kind).collect();
        if items.is_empty() {
            continue;
        }
        println!();
        rule(&p, title);
        for c in items {
            println!();
            println!("  {}", p.bold(&c.name));
            if !c.headline.is_empty() {
                println!("  {}", p.verdict(c.verdict, &c.headline));
            }
            println!();
            let label = if kind == "battery" {
                "Health"
            } else {
                "Life remaining"
            };
            gauge(&p, label, c.percent, c.verdict);
            for (key, label) in display_fields(kind) {
                if let Some(f) = c.facts.get(*key) {
                    row(&p, label, f);
                }
            }
        }
    }

    // --- consistency checks ---
    println!();
    rule(&p, "Consistency checks");
    println!();
    for c in &r.tamper_checks {
        let (code, mark) = match c.status {
            CheckStatus::Pass => ("32", "[pass]"),
            CheckStatus::Suspicious => ("33", "[look]"),
            CheckStatus::Fail => ("31", "[FAIL]"),
            CheckStatus::Skipped => ("90", "[skip]"),
        };
        println!("  {} {}", p.c(code, mark), c.title);
        if c.status != CheckStatus::Pass {
            for l in wrap(&c.detail, 70) {
                println!("         {}", p.dim(&l));
            }
        }
    }

    // --- findings ---
    println!();
    rule(&p, "What you should know");
    println!();
    if r.findings.is_empty() {
        println!("  {}", p.c("32", "Nothing of concern was found."));
        println!();
    }
    for sev in [Severity::Critical, Severity::Warn, Severity::Info] {
        for f in r.findings.iter().filter(|f| f.severity == sev) {
            let (code, mark) = match sev {
                Severity::Critical => ("31", "[!]"),
                Severity::Warn => ("33", "[*]"),
                Severity::Info => ("36", "[i]"),
            };
            println!("  {} {}", p.c(code, mark), p.c(code, &f.title));
            for l in wrap(&f.detail, 72) {
                println!("      {l}");
            }
            if let Some(e) = &f.evidence {
                println!("      {}", p.dim(&format!("evidence: {e}")));
            }
            println!();
        }
    }

    // --- trust summary ---
    rule(&p, "How much of this can be trusted");
    println!();
    println!(
        "  {} of {} readings come from the firmware or the parts themselves ({:.0}%).",
        r.trust.tamper_resistant_facts, r.trust.total_facts, r.trust.tamper_resistant_percent
    );
    println!();
    println!(
        "  {} {}",
        p.c("32", "DEVICE  "),
        p.dim("the part itself answered. Faking it means reflashing the part.")
    );
    println!(
        "  {} {}",
        p.c("36", "KERNEL  "),
        p.dim("the operating system kernel's own view of the hardware.")
    );
    println!(
        "  {} {}",
        p.c("34", "FIRMWARE"),
        p.dim("the motherboard firmware tables. Faking it means reflashing the BIOS.")
    );
    println!(
        "  {} {}",
        p.c("90", "CALC    "),
        p.dim("worked out by RefurbMan from the readings above.")
    );
    println!(
        "  {} {}",
        p.c("33", "SOFTWARE"),
        p.dim("editable settings. Never used to back a hardware claim.")
    );

    if !r.errors.is_empty() {
        println!();
        rule(&p, "Could not be read");
        println!();
        for e in &r.errors {
            for l in wrap(e, 72) {
                println!("  {}", p.dim(&l));
            }
        }
    }

    println!();
    println!("{}", p.dim(&"-".repeat(78)));
    for l in [
        "This report raises the effort needed to deceive you from editing a text file",
        "to reflashing firmware. It is not proof. Someone with deep access to this",
        "machine can still lie to it, so treat it as strong evidence rather than a",
        "guarantee, and weigh it against how the machine actually behaves.",
    ] {
        println!("  {}", p.dim(l));
    }
    println!();
}

const BANNER: &str = r"    ____       ____           __    __  ___
   / __ \___  / __/_  _______/ /_  /  |/  /___ _____
  / /_/ / _ \/ /_/ / / / ___/ __ \/ /|_/ / __ `/ __ \
 / _, _/  __/ __/ /_/ / /  / /_/ / /  / / /_/ / / / /
/_/ |_|\___/_/  \__,_/_/  /_.___/_/  /_/\__,_/_/ /_/";
