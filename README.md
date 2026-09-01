# RefurbMan

Check what is actually inside a second-hand PC, and how much life its parts have
left, using readings a seller cannot easily fake.

## The problem

When you buy a used or refurbished computer, the seller had the machine before
you did. Most "system information" tools read from places that seller can edit:
the Windows registry, WMI providers, driver-supplied text. A tampered machine
can report a 2TB drive in perfect health while actually holding a worn 256GB
one, and the usual tools will repeat the lie back to you.

## What RefurbMan does differently

It reads from three places that are hard to tamper with, and it tells you which
one every single number came from:

| Rank | Source | What faking it would take |
|---|---|---|
| Device firmware | NVMe admin commands, ATA SMART, the battery controller | Reflashing the part itself |
| Kernel | sysfs, procfs, syscalls | Patching a running kernel |
| System firmware | SMBIOS/DMI tables | Reflashing the BIOS |

Anything that came from ordinary software is labelled as such and is never used
to back a hardware claim. If a reading is weak, RefurbMan says so instead of
quietly presenting it alongside the strong ones.

It answers the two questions that actually matter to a buyer:

- **What is really in this box?** CPU, memory per slot, storage, graphics,
  battery, board and firmware.
- **How much life is left in the parts that wear out?** Drive health and battery
  health, in plain language, with a Good / Fair / Poor call rather than a wall
  of raw counters.

It also runs a set of consistency checks that compare two independent sources
for the same fact, which is how tampering usually shows itself: a drive with
almost no power-on hours but heavy wear, a memory total that disagrees with the
sum of the installed sticks, a CPU name that does not match what the silicon
reports.

## Honest limits

These matter, because a tool that overstates its own certainty would hurt
exactly the people it is meant to protect.

- **A report is tamper-evident, not a hardware attestation.** There is no TPM
  quote and no signing chain. Someone with kernel-level access to the machine
  can still lie to it. RefurbMan raises the effort required from "edit a
  registry key" to "reflash firmware or patch a kernel"; it does not make
  deception impossible.
- **Battery cycle count is often unavailable on Windows**, because many OEM
  batteries never report it through ACPI. It shows as "not reported", never as
  zero.
- **CPU and motherboard temperatures are Linux only.** Reading them on Windows
  needs a signed kernel driver, which is out of scope. Drive temperature works
  on both, and that is the one that matters for judging a used machine.
- **Fake-capacity SD cards and USB sticks** are only caught when their reported
  and addressable sizes disagree. A full write-and-verify test would destroy the
  data on the card, so it is deliberately not in this version.
- **A full scan needs administrator or root.** Talking to a drive's SMART
  interface requires it. Without those rights RefurbMan still produces a report
  and clearly marks what it could not read.

## Run it without installing anything

Both scripts are self-contained. They read the same sources and apply the same
judgement as the desktop application, and print a report in the terminal.

**Windows.** Open PowerShell as administrator (right click the Start button,
choose "Terminal (Admin)" or "Windows PowerShell (Admin)"), then paste:

```powershell
irm https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/RefurbMan.ps1 | iex
```

**Linux.**

```bash
curl -fsSL https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/refurbman.sh | sudo bash
```

Both work without administrator or root as well. The machine is still fully
identified; what you lose is drive health and the memory slot breakdown, and the
report says so rather than leaving a gap.

Add `--json` (or `-Json` on Windows) for machine-readable output.

### Keeping a copy

Any of the three can write a report you can keep, print, or send to a seller:

```bash
./scripts/refurbman.sh --html report.html          # Linux
```
```powershell
.\scripts\RefurbMan.ps1 -Html report.html          # Windows
```

The result is one self-contained file with no images, scripts, or network
requests, so it opens anywhere and can be archived or emailed as is. Open it in
a browser and choose Print, then Save as PDF, for a PDF copy. There is no PDF
library here on purpose: every machine that can read the report already has a
browser that makes better PDFs than a bundled engine would.

A word on pasting commands from the internet: you should not do this without
looking first, and that applies here too. Both scripts are plain text in this
repository, they only read, and they send nothing anywhere. Read them before you
run them:
[RefurbMan.ps1](scripts/RefurbMan.ps1), [refurbman.sh](scripts/refurbman.sh).

### Why not just use Task Manager or a specs tool?

On Windows, the processor name those tools show comes from
`HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\ProcessorNameString`.
That is a registry string, and anyone with administrator rights can rewrite it
in about ten seconds. Renaming an i3 to an i7 there fools nearly every tool
people reach for, including Task Manager and the System Information panel.

RefurbMan parses the raw SMBIOS firmware table instead, and on Linux reads the
brand string the processor itself returns to the `CPUID` instruction.

## Status

Early development, but usable. The two scripts work today, the probe engine is
built and tested, and the desktop application runs. Installers are produced by
the release workflow on a version tag.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

RefurbMan reads drive health using [smartmontools](https://www.smartmontools.org/),
which is distributed under GPL-2.0-or-later and is invoked as a separate
program. Release bundles carry its licence and a matching source offer under
`third_party/smartmontools/`.
