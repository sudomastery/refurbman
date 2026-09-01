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

## Status

Early development. The probe engine is being built first; the desktop interface
follows.

## Building

The probe engine has no GUI dependencies:

```
cargo test -p refurbman-probe
cargo run  -p refurbman-probe --bin refurbman-probe -- --json
```

The desktop application additionally needs the Tauri toolchain. On Fedora:

```
sudo dnf install webkit2gtk4.1-devel gtk3-devel libsoup3-devel \
                 librsvg2-devel libappindicator-gtk3-devel
```

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

RefurbMan reads drive health using [smartmontools](https://www.smartmontools.org/),
which is distributed under GPL-2.0-or-later and is invoked as a separate
program. Release bundles carry its licence and a matching source offer under
`third_party/smartmontools/`.
