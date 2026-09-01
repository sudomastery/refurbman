# smartmontools: licence and source offer

RefurbMan reads drive health by running **smartmontools** (`smartctl`) as a
separate program and parsing its JSON output. smartmontools is not part of
RefurbMan; it is a complete, unmodified program that RefurbMan invokes.

## What is bundled, and why

`smartctl` speaks to a drive's own controller: NVMe admin Get-Log-Page for NVMe
devices, ATA SMART passthrough for SATA, and per-vendor command encodings for
the USB-to-SATA bridges that external drives hide behind. It also carries
`drivedb.h`, a database mapping vendor-specific SMART attribute IDs to their
actual meanings, because attribute 231 means one thing on an Intel drive and
something else on a Kingston.

Reimplementing that is not realistic, and getting it subtly wrong does not
produce no answer, it produces a confidently wrong one. On a tool whose whole
purpose is telling somebody whether a drive is worn out, that is the worst
possible failure.

A copy is bundled rather than relying on whatever the machine has installed,
because the machine being tested usually belongs to the seller.

## Licence

smartmontools is licensed **GPL-2.0-or-later**. The full licence text as
shipped by the project is in [COPYING](COPYING) beside this file.

RefurbMan itself is licensed GPL-3.0-or-later. GPL-2.0-or-later permits use
under GPL-3.0, so the combined distribution is consistent. RefurbMan was
licensed this way deliberately, to remove any question about the bundle rather
than rely on an argument about aggregation.

## Written offer of source

Section 3 of GPL-2.0 requires that source accompany any binary distribution.

**Every RefurbMan release carries the complete, unmodified source of the exact
smartmontools version it bundles**, attached to the GitHub release as
`smartmontools-<version>.tar.gz`. Nothing is patched: the released bytes are
the upstream release, verified by checksum.

If you received a RefurbMan binary without that source, you may obtain it from:

- The releases page: <https://github.com/sudomastery/refurbman/releases>
- Upstream directly: <https://www.smartmontools.org/>
- Or by opening an issue on this repository.

## The pinned version

The version and its checksums live in [pinned.env](pinned.env) and are read by
both vendoring scripts, so there is one place to change and nothing can drift.

Checksums are SHA-256. Upstream signs releases with GPG and publishes MD5, so
each pinned SHA-256 was computed locally from a download whose published MD5 had
already been verified. Pinning them means the bundle cannot change underneath us
even if the release files are later replaced.

## Fetching it

```
./scripts/vendor-smartmontools.sh          # Linux and macOS
.\scripts\vendor-smartmontools.ps1         # Windows
```

Each downloads the pinned release, refuses to continue if the checksum does not
match, and places `smartctl` (with `drivedb.h` on Windows) where the application
looks for it. The downloaded binaries are deliberately not committed to this
repository: `.gitignore` excludes them, so the repository stays source-only and
the binaries are fetched and verified at build time.
