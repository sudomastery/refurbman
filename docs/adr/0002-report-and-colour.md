# 2. The report format, and why no verdict is carried by colour

_Status: accepted, 2026-09-01._

Two decisions taken while building the exported report and the desktop window.
Both affect every surface of the product, so they are written down rather than
left in commit messages.

## HTML with a print stylesheet, not a bundled PDF engine

RefurbMan exports one self-contained HTML file. There are no images, no scripts
and no network requests, so it opens offline, can be emailed as is, and any
browser turns it into a PDF with Print.

**Why not generate PDF directly.** The two ways to do it are a Rust PDF crate,
which means worse typography and re-solving text layout, or bundling headless
Chrome, which would multiply the download size for a tool whose whole appeal is
that it is small and needs nothing installed. Every machine that can read this
report already has a browser that makes better PDFs than either option.

**The cost, stated plainly.** The user does an extra step: open, Print, Save as
PDF. That is worth revisiting if people report it as friction, and the fix would
be shelling out to an already-installed browser in headless mode rather than
bundling one.

**Why the scripts each carry their own copy of the stylesheet.** Standing alone
is the entire point of the PowerShell and shell scripts: they are meant to be
pasted into a terminal on a machine you do not own. So the duplication is
unavoidable. It is made mechanical instead of manual by
`scripts/sync-report-css.py`, which regenerates both copies from
`assets/report.css`, and by a CI job that fails if either has drifted.

## No verdict is ever carried by colour alone

Running the palette validator over the status colours produced the finding that
shaped every surface:

```
good #0ca30c  vs  poor #d03b3b
  normal vision   ΔE 33.9   comfortable
  deuteranopia    ΔE  4.1   effectively the same colour
```

Deuteranopia is the most common form of colour blindness, affecting roughly one
man in twelve. RefurbMan's entire job is to answer "is this fine or not". Had
the verdicts been distinguished by red and green, that answer would have been
invisible to a substantial share of the people the tool exists to protect, and
invisible in a way none of them would notice: the report would look confident
and complete while conveying the opposite of the truth.

So every verdict carries three signals, none of which is load-bearing alone:

| Verdict | Shape | Word | Colour |
|---|---|---|---|
| Good | ✓ | "Good" | green |
| Fair | ! | "Fair" | amber |
| Poor | ✗ | "Poor" | red |
| Unknown | ? | "Not known" | grey |

The same rule governs the consistency checks and the findings list. It also
survives the report being printed in black and white, which is a realistic thing
for a buyer to do before going to look at a machine.

### The hatched meter

A related case, found by looking at a real report rather than by measurement.
The development laptop's battery claims 100% health after 766 charge cycles.
The engine correctly refuses to believe that and returns `Unknown`, but the
meter still rendered as a full bar, which reads as "excellent" at a glance no
matter what the badge beside it says.

A figure the tool does not believe now gets a hatched fill and the word
`claimed` under the number. The hatching is the part of that signal which
survives greyscale printing and every form of colour blindness.

### Meters, not ring gauges

A ring gauge for a single percentage is a two-slice pie, which is a harder read
than a plain bar and buys nothing. Each wear figure is a horizontal meter whose
unfilled track is a lighter step of the fill's own hue, so the state reads
across the whole bar rather than only where the fill stops.
