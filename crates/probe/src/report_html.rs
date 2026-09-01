//! A self-contained HTML report, designed to print cleanly to PDF.
//!
//! One file, no external assets, no network. It can be emailed, archived, or
//! opened on a machine with no internet, and "Print to PDF" in any browser
//! produces a tidy document. That matters because the audience for this report
//! is often a buyer showing a seller what they found, or keeping a record of
//! the condition a machine was in on the day it changed hands.
//!
//! On the visual design, two decisions are worth recording:
//!
//! **Meters, not ring gauges.** A ring gauge for a single percentage is a
//! two-slice pie, which is a harder read than a plain bar for no gain. Each
//! wear figure is a horizontal meter whose unfilled track is a lighter step of
//! the fill's own hue, so the state reads across the whole bar.
//!
//! **Never colour alone.** Measured with the palette validator, the good green
//! and the poor red sit 4.1 apart under deuteranopia, far below the readable
//! floor. For roughly one man in twelve those two verdicts would be the same
//! colour, and this report's entire job is to say whether something is fine or
//! not. So every verdict carries a distinct shape and a word as well as a
//! colour, and none of the three is load-bearing on its own.

use crate::fact::{Fact, Trust, Value};
use crate::report::{display_fields, CheckStatus, Consumable, Report, Severity, Verdict};

/// Render the whole report as one HTML document.
pub fn render(r: &Report) -> String {
    let mut h = String::with_capacity(32 * 1024);
    let machine = machine_name(r);

    h.push_str("<!doctype html>\n<html lang=\"en\">\n<head>\n");
    h.push_str("<meta charset=\"utf-8\">\n");
    h.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    h.push_str(&format!(
        "<title>RefurbMan report: {}</title>\n",
        esc(&machine)
    ));
    h.push_str("<style>\n");
    h.push_str(CSS);
    h.push_str("</style>\n</head>\n<body>\n<main class=\"page\">\n");

    header(&mut h, r, &machine);
    condition(&mut h, r);
    identity(&mut h, r);
    hardware(&mut h, r);
    checks(&mut h, r);
    findings(&mut h, r);
    provenance(&mut h, r);
    footer(&mut h, r);

    h.push_str("</main>\n</body>\n</html>\n");
    h
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

fn header(h: &mut String, r: &Report, machine: &str) {
    h.push_str("<header class=\"masthead\">\n");
    h.push_str("<div class=\"brand\">RefurbMan</div>\n");
    h.push_str(&format!("<h1>{}</h1>\n", esc(machine)));
    let mut sub = Vec::new();
    if let Some(f) = r.system.get("chassis") {
        sub.push(show(&f.value));
    }
    if let Some(f) = r.system.get("serialNumber") {
        sub.push(format!("Serial {}", show(&f.value)));
    }
    if !sub.is_empty() {
        // Escape each part first, then join with the separator entity. Joining
        // first would escape the entity's own ampersand and print it literally.
        let joined = sub
            .iter()
            .map(|p| esc(p))
            .collect::<Vec<_>>()
            .join(" &middot; ");
        h.push_str(&format!("<p class=\"sub\">{joined}</p>\n"));
    }
    h.push_str(&format!(
        "<p class=\"stamp\">Checked {} &middot; RefurbMan {} &middot; {} scan</p>\n",
        esc(&r.generated_at),
        esc(&r.tool_version),
        if r.privileged { "full" } else { "limited" }
    ));
    h.push_str("</header>\n");
}

/// The wear figures, which are what the reader came for.
fn condition(h: &mut String, r: &Report) {
    if r.consumables.is_empty() {
        return;
    }
    h.push_str("<section class=\"block\">\n<h2>Condition of the parts that wear out</h2>\n");
    h.push_str("<div class=\"cards\">\n");
    for c in &r.consumables {
        card(h, c);
    }
    h.push_str("</div>\n</section>\n");
}

fn card(h: &mut String, c: &Consumable) {
    let v = c.verdict;
    h.push_str(&format!("<article class=\"card v-{}\">\n", slug(v)));
    h.push_str("<div class=\"card-top\">\n");
    h.push_str(&format!("<h3>{}</h3>\n", esc(&c.name)));
    h.push_str(&badge(v));
    h.push_str("</div>\n");

    let label = if c.kind == "battery" {
        "Capacity remaining"
    } else {
        "Life remaining"
    };
    meter(h, label, c.percent, v);

    if !c.headline.is_empty() {
        h.push_str(&format!("<p class=\"headline\">{}</p>\n", esc(&c.headline)));
    }

    let rows: Vec<String> = display_fields(&c.kind)
        .iter()
        .filter_map(|(k, label)| c.facts.get(*k).map(|f| fact_row(label, f)))
        .collect();
    if !rows.is_empty() {
        h.push_str("<dl class=\"facts\">\n");
        for row in rows {
            h.push_str(&row);
        }
        h.push_str("</dl>\n");
    }
    h.push_str("</article>\n");
}

fn identity(h: &mut String, r: &Report) {
    let rows: Vec<String> = [
        ("manufacturer", "Manufacturer"),
        ("model", "Model"),
        ("family", "Family"),
        ("sku", "SKU"),
        ("serialNumber", "Serial number"),
        ("chassis", "Form"),
        ("boardVendor", "Motherboard maker"),
        ("boardModel", "Motherboard"),
        ("biosVendor", "BIOS maker"),
        ("biosVersion", "BIOS version"),
        ("biosDate", "BIOS date"),
    ]
    .iter()
    .filter_map(|(k, label)| r.system.get(*k).map(|f| fact_row(label, f)))
    .collect();

    if rows.is_empty() {
        return;
    }
    h.push_str("<section class=\"block\">\n<h2>This machine</h2>\n<dl class=\"facts wide\">\n");
    for row in rows {
        h.push_str(&row);
    }
    h.push_str("</dl>\n</section>\n");
}

fn hardware(h: &mut String, r: &Report) {
    for (kind, title) in [("cpu", "Processor"), ("memory", "Memory")] {
        let items: Vec<_> = r.components.iter().filter(|c| c.kind == kind).collect();
        if items.is_empty() {
            continue;
        }
        h.push_str(&format!("<section class=\"block\">\n<h2>{title}</h2>\n"));

        if kind == "memory" {
            let totals: Vec<String> = [
                ("memoryInstalled", "Installed"),
                ("memoryUsable", "System can use"),
                ("memorySlotsPopulated", "Slots in use"),
                ("memorySlotsTotal", "Slots on the board"),
            ]
            .iter()
            .filter_map(|(k, label)| r.system.get(*k).map(|f| fact_row(label, f)))
            .collect();
            if !totals.is_empty() {
                h.push_str("<dl class=\"facts wide\">\n");
                for t in totals {
                    h.push_str(&t);
                }
                h.push_str("</dl>\n");
            }
        }

        for c in items {
            if kind == "memory" {
                h.push_str(&format!("<h3 class=\"sub-head\">{}</h3>\n", esc(&c.name)));
            }
            h.push_str("<dl class=\"facts wide\">\n");
            for (key, label) in display_fields(kind) {
                if let Some(f) = c.facts.get(*key) {
                    h.push_str(&fact_row(label, f));
                }
            }
            h.push_str("</dl>\n");
        }
        h.push_str("</section>\n");
    }
}

fn checks(h: &mut String, r: &Report) {
    if r.tamper_checks.is_empty() {
        return;
    }
    h.push_str("<section class=\"block\">\n<h2>Consistency checks</h2>\n");
    h.push_str(
        "<p class=\"lede\">Each of these compares two sources that describe the same thing but \
         arrive by different routes. Faking one is easy; faking both to agree is much harder, so \
         disagreement between them is worth knowing about.</p>\n",
    );
    h.push_str("<ul class=\"checks\">\n");
    for c in &r.tamper_checks {
        let (cls, mark, word) = match c.status {
            CheckStatus::Pass => ("pass", "&#10003;", "Passed"),
            CheckStatus::Suspicious => ("look", "&#33;", "Worth a look"),
            CheckStatus::Fail => ("fail", "&#10007;", "Failed"),
            CheckStatus::Skipped => ("skip", "-", "Not checked"),
        };
        h.push_str(&format!(
            "<li class=\"check {cls}\"><span class=\"mark\" aria-hidden=\"true\">{mark}</span>\
             <div><p class=\"check-title\">{} <span class=\"check-word\">{word}</span></p>\
             <p class=\"check-detail\">{}</p></div></li>\n",
            esc(&c.title),
            esc(&c.detail)
        ));
    }
    h.push_str("</ul>\n</section>\n");
}

fn findings(h: &mut String, r: &Report) {
    h.push_str("<section class=\"block\">\n<h2>What you should know</h2>\n");
    if r.findings.is_empty() {
        h.push_str("<p class=\"lede\">Nothing of concern was found.</p>\n</section>\n");
        return;
    }
    h.push_str("<ul class=\"findings\">\n");
    for sev in [Severity::Critical, Severity::Warn, Severity::Info] {
        for f in r.findings.iter().filter(|f| f.severity == sev) {
            let (cls, mark, word) = match sev {
                Severity::Critical => ("critical", "&#10007;", "Serious"),
                Severity::Warn => ("warn", "&#33;", "Worth knowing"),
                Severity::Info => ("info", "&#105;", "For information"),
            };
            h.push_str(&format!(
                "<li class=\"finding {cls}\">\
                 <p class=\"f-head\"><span class=\"mark\" aria-hidden=\"true\">{mark}</span>\
                 <span class=\"f-word\">{word}</span>{}</p>\
                 <p class=\"f-detail\">{}</p>",
                esc(&f.title),
                esc(&f.detail)
            ));
            if let Some(e) = &f.evidence {
                h.push_str(&format!("<p class=\"evidence\">{}</p>", esc(e)));
            }
            h.push_str("</li>\n");
        }
    }
    h.push_str("</ul>\n</section>\n");
}

fn provenance(h: &mut String, r: &Report) {
    h.push_str("<section class=\"block\">\n<h2>Where these readings came from</h2>\n");
    h.push_str(&format!(
        "<p class=\"lede\">{} of {} readings come from the firmware or from the parts themselves, \
         rather than from software anyone can edit.</p>\n",
        r.trust.tamper_resistant_facts, r.trust.total_facts
    ));

    let pct = r.trust.tamper_resistant_percent;
    h.push_str("<div class=\"meter trust\">\n");
    h.push_str(&format!(
        "<div class=\"track\"><div class=\"fill\" style=\"width:{pct:.1}%\"></div></div>\n"
    ));
    h.push_str(&format!("<div class=\"meter-value\">{pct:.0}%</div>\n"));
    h.push_str("</div>\n");

    h.push_str("<dl class=\"legend\">\n");
    for t in [
        Trust::Device,
        Trust::Kernel,
        Trust::Firmware,
        Trust::Derived,
        Trust::Software,
    ] {
        h.push_str(&format!(
            "<dt><span class=\"chip t{}\">{}</span></dt><dd>{}</dd>\n",
            t as u8,
            t.label(),
            t.explanation()
        ));
    }
    h.push_str("</dl>\n</section>\n");
}

fn footer(h: &mut String, r: &Report) {
    if !r.errors.is_empty() {
        h.push_str("<section class=\"block\">\n<h2>Could not be read</h2>\n<ul class=\"plain\">\n");
        for e in &r.errors {
            h.push_str(&format!("<li>{}</li>\n", esc(e)));
        }
        h.push_str("</ul>\n</section>\n");
    }

    h.push_str("<footer class=\"disclaimer\">\n");
    h.push_str(
        "<p><strong>What this report is, and is not.</strong> It raises the effort needed to \
         deceive you from editing a text file to reflashing firmware. It is not proof. There is \
         no signing chain here and no hardware attestation, so somebody with deep enough access \
         to this machine can still lie to it. Treat this as strong evidence rather than a \
         guarantee, and weigh it against how the machine actually behaves.</p>\n",
    );
    h.push_str(
        "<p class=\"fine\">Generated by RefurbMan, which reads from the operating system kernel, \
         the motherboard firmware tables, and the parts themselves, and never from the Windows \
         registry.</p>\n",
    );
    h.push_str("</footer>\n");
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// A verdict badge. Carries a shape, a word and a colour, so that removing any
/// one of the three still leaves the meaning intact.
fn badge(v: Verdict) -> String {
    let (mark, word) = match v {
        Verdict::Good => ("&#10003;", "Good"),
        Verdict::Fair => ("&#33;", "Fair"),
        Verdict::Poor => ("&#10007;", "Poor"),
        Verdict::Unknown => ("&#63;", "Not known"),
    };
    format!(
        "<span class=\"badge b-{}\"><span class=\"mark\" aria-hidden=\"true\">{mark}</span>{word}</span>",
        slug(v)
    )
}

/// A horizontal meter. The unfilled track is a lighter step of the fill's own
/// hue, so the state reads across the full width rather than only where the
/// fill stops.
fn meter(h: &mut String, label: &str, percent: Option<f64>, v: Verdict) {
    h.push_str("<div class=\"meter-row\">\n");
    h.push_str(&format!(
        "<div class=\"meter-label\">{}</div>\n",
        esc(label)
    ));
    match percent {
        Some(p) => {
            let p = p.clamp(0.0, 100.0);
            // A figure we do not believe gets a hatched fill. A solid bar at
            // 100% reads as "excellent" at a glance, which is the opposite of
            // what an Unknown verdict means, and the badge alone is far too
            // quiet to undo that first impression.
            let doubted = if v == Verdict::Unknown {
                " doubted"
            } else {
                ""
            };
            h.push_str(&format!("<div class=\"meter v-{}{doubted}\">\n", slug(v)));
            h.push_str(&format!(
                "<div class=\"track\"><div class=\"fill\" style=\"width:{p:.1}%\"></div></div>\n"
            ));
            let qualifier = if v == Verdict::Unknown {
                "<span class=\"qualifier\">claimed</span>"
            } else {
                ""
            };
            h.push_str(&format!(
                "<div class=\"meter-value\">{p:.0}%{qualifier}</div>\n"
            ));
            h.push_str("</div>\n");
        }
        None => {
            // An empty track would read as zero life left, which is a very
            // different claim from "this could not be measured".
            h.push_str("<div class=\"meter unmeasured\"><div class=\"track\"></div>");
            h.push_str("<div class=\"meter-value muted\">not reported</div></div>\n");
        }
    }
    h.push_str("</div>\n");
}

fn fact_row(label: &str, f: &Fact) -> String {
    let mut text = show(&f.value);
    if let Some(u) = &f.unit {
        if u != "bytes" {
            text = format!("{text} {u}");
        }
    }
    format!(
        "<div class=\"fact\"><dt>{}</dt><dd>{}<span class=\"chip t{}\" title=\"{}\">{}</span></dd></div>\n",
        esc(label),
        esc(&text),
        f.trust as u8,
        esc(&f.source),
        f.trust.label()
    )
}

fn machine_name(r: &Report) -> String {
    let parts: Vec<String> = ["manufacturer", "model"]
        .iter()
        .filter_map(|k| r.system.get(*k).map(|f| show(&f.value)))
        .collect();
    if parts.is_empty() {
        "Unidentified machine".to_owned()
    } else {
        // Manufacturers often repeat themselves: "HP" plus "HP Pavilion Aero"
        // should read as one name, not two.
        let joined = parts.join(" ");
        if parts.len() == 2 && parts[1].starts_with(&parts[0]) {
            parts[1].clone()
        } else {
            joined
        }
    }
}

fn slug(v: Verdict) -> &'static str {
    match v {
        Verdict::Good => "good",
        Verdict::Fair => "fair",
        Verdict::Poor => "poor",
        Verdict::Unknown => "unknown",
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

/// Escape for HTML text and attribute contexts.
///
/// The report embeds strings that came off hardware, and a drive model or an
/// OEM asset tag is attacker-controllable on a machine you did not build.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// Stylesheet for the report.
///
/// Palette values come from the validated reference set: status colours for the
/// verdicts, neutral ink for text. Text never wears a status colour as its only
/// signal.
///
/// Print is a first-class target, not an afterthought. Colour is forced to the
/// light set, shadows are dropped, cards are kept off page boundaries, and each
/// fact's source is spelled out, because a printed page has no tooltips.
const CSS: &str = include_str!("../../../assets/report.css");

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fact::device;
    use crate::report::{Facts, TrustSummary};

    fn report_with(consumables: Vec<Consumable>) -> Report {
        Report {
            generated_at: "2026-09-01T00:00:00Z".into(),
            tool_version: "0.1.0".into(),
            platform: "linux".into(),
            privileged: true,
            system: Facts::new(),
            components: Vec::new(),
            consumables,
            findings: Vec::new(),
            tamper_checks: Vec::new(),
            trust: TrustSummary {
                total_facts: 10,
                tamper_resistant_facts: 8,
                tamper_resistant_percent: 80.0,
                full_access: true,
            },
            errors: Vec::new(),
        }
    }

    #[test]
    fn hardware_strings_cannot_inject_markup() {
        // A drive model comes off a device on a machine you did not build, so
        // it has to be treated as hostile input.
        let mut c = Consumable::new("storage", "<script>alert(1)</script>");
        c.push("model", device("\"><img onerror=x>", "test"));
        let html = render(&report_with(vec![c]));
        assert!(!html.contains("<script>alert"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(!html.contains("<img onerror"));
    }

    #[test]
    fn every_verdict_carries_a_word_and_a_shape_not_only_colour() {
        // Good green and poor red are 4.1 apart under deuteranopia, so colour
        // on its own would leave those two verdicts identical for roughly one
        // man in twelve.
        for (v, word) in [
            (Verdict::Good, "Good"),
            (Verdict::Fair, "Fair"),
            (Verdict::Poor, "Poor"),
            (Verdict::Unknown, "Not known"),
        ] {
            let b = badge(v);
            assert!(b.contains(word), "verdict {v:?} lost its word");
            assert!(b.contains("mark"), "verdict {v:?} lost its shape");
        }
    }

    #[test]
    fn a_drive_with_no_wear_figure_says_so_rather_than_showing_zero() {
        let mut c = Consumable::new("storage", "EXAMPLE HDD");
        c.verdict = Verdict::Good;
        c.percent = None;
        let html = render(&report_with(vec![c]));
        assert!(html.contains("not reported"));
        // An empty meter would read as zero life left, which is the opposite
        // of what "we could not measure it" means.
        assert!(!html.contains("width:0.0%"));
    }

    #[test]
    fn the_document_is_self_contained() {
        let html = render(&report_with(vec![]));
        assert!(html.starts_with("<!doctype html>"));
        assert!(!html.contains("http://"));
        assert!(!html.contains("https://"));
        assert!(!html.contains("<script"));
        assert!(html.contains("<style>"));
    }

    #[test]
    fn the_subtitle_separator_is_not_double_escaped() {
        let mut r = report_with(vec![]);
        r.system.insert("chassis".into(), device("Notebook", "t"));
        r.system
            .insert("serialNumber".into(), device("ABC123", "t"));
        let html = render(&r);
        assert!(html.contains("Notebook &middot; Serial ABC123"));
        assert!(!html.contains("&amp;middot;"));
    }

    #[test]
    fn repeated_manufacturer_is_not_printed_twice() {
        let mut r = report_with(vec![]);
        r.system.insert("manufacturer".into(), device("HP", "t"));
        r.system
            .insert("model".into(), device("HP Pavilion Aero", "t"));
        assert_eq!(machine_name(&r), "HP Pavilion Aero");
    }
}
