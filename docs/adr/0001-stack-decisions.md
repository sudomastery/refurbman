# 1. Stack decisions: Tauri, bundled smartmontools, public repo

_Status: accepted, 2026-09-01._


## 1. Tauri v2 with a Rust probe engine

**Advantages**

- Installer is roughly 9 to 12 MB against 60 to 70 MB for a bundled Python
  runtime. For an audience downloading this on a phone tether in a shop, that is
  a real difference.
- Real native installers (MSI, NSIS, AppImage, deb, rpm). No "install Python
  first", no console window flashing, no unpack-to-temp delay on launch.
- **Antivirus and SmartScreen behaviour is the decisive advantage.** PyInstaller
  one-file executables are heavily false-positived by Defender and most AV
  engines, because malware uses the same packer. A tool whose entire pitch is
  "trust these numbers" cannot ship a binary that Windows flags as suspicious.
  A signed MSI does not have that problem.
- One language for the privileged syscall work. Hand-written `ctypes` struct
  layouts for `IOCTL_STORAGE_QUERY_PROPERTY` are easy to get subtly wrong and
  fail silently; the `windows` crate's bindings are generated from the real
  Windows metadata.
- Near-instant startup, with no local HTTP server and no port to collide.

**Tradeoffs**

- It does not match your preferred backend stack. The frontend half still does
  (TypeScript, React, Tailwind), but the Python and FastAPI half is gone.
- Slower for me to write. Windows storage IOCTLs in Rust FFI are more verbose
  than the `ctypes` equivalent, and Rust compile times will slow iteration.
- Needs GUI build dependencies this machine lacks (the `dnf install` above).
- Cross-compiling to Windows from Fedora is painful in practice, so Windows
  builds happen in GitHub Actions. Iterating on Windows-only code is therefore
  bound by CI latency, not by local edit-and-run.
- Now that the repo is public, Rust narrows the contributor pool relative to
  Python.

## 2. Bundling smartmontools

**Advantages**

- Twenty years of device quirk handling. USB-to-SATA bridges (JMicron, ASMedia,
  Sandforce and others) each need their own passthrough encoding; getting these
  wrong yields "no SMART data" on exactly the external drives a buyer is most
  suspicious of.
- One stable JSON schema across ATA, NVMe, SCSI, SAS and USB bridges, on both
  operating systems, versioned via `json_format_version`.
- Its `drivedb.h` maps vendor-specific attribute IDs to actual meanings.
  Attribute 231 means one thing on Intel and another on Kingston. Rebuilding
  that database is not realistic, and guessing wrong produces confidently wrong
  health numbers, which is worse than none.
- Independently auditable. A sceptical buyer can run `smartctl` themselves and
  compare against RefurbMan's output, which reinforces the trust story rather
  than asking for faith.

**Tradeoffs**

- GPL-2.0-or-later. Invoking it as a separate process is mere aggregation, but
  the distributed bundle must still carry its source. Handled by the vendoring
  script and the release tarball.
- **This is the choice that forecloses a closed-source commercial version
  later.** If you ever want to sell a proprietary RefurbMan, you would have to
  rip out the smartctl dependency and write the native passthrough anyway. Worth
  knowing now while it is cheap to change.
- A second binary to ship, sign, and keep updated. Around 2 MB, and raw disk
  access tools occasionally get AV attention of their own.
- One process spawn per device rather than an in-process ioctl. Around 50 ms per
  drive, so irrelevant here.
- Parser must tolerate schema drift across smartctl versions. Mitigated by
  pinning the vendored version and asserting on `json_format_version`.
- No privilege advantage either way: native passthrough would need root or admin
  just the same.

## 3. Public repository

**Advantages**

- The trust argument only works if the code is inspectable. Asking someone not
  to trust the seller's word, from inside an opaque binary, asks them to trust
  your word instead. Public source is closer to a functional requirement here
  than a preference.
- Build artifacts produced by GitHub Actions are publicly verifiable against the
  source that produced them.
- The long tail of hardware quirks is exactly the kind of problem that gets
  fixed by strangers with odd drives.

**Tradeoffs**

- Everything is visible from the first push, and git history is permanent.
  **The concrete risk is test fixtures.** The natural way to build the parser
  tests is to save `smartctl --json` and `dmidecode` output from this laptop,
  and that output contains your drive serial, board serial, and product UUID.
  Committed once, it is public forever. Mitigation: every fixture gets serials,
  UUIDs and asset tags scrubbed before it is committed, and I will add a
  pre-commit check plus a CI grep that fails the build on anything resembling a
  serial. I will flag this again when I create the first fixture.
- GPL plus public together mean no closed commercial path later without a
  rewrite and contributor consent.
- Publishing the tamper-detection logic tells a scammer which checks to defeat.
  This is a real but weak objection: the checks read device firmware directly,
  and that is the hard part to defeat regardless of whether the source is
  visible. Obscurity would buy little and cost the trust argument a lot.
- A public issue tracker on a hardware tool attracts a steady stream of "does
  not work on my drive" reports. Worth deciding up front how much of that you
  want to carry.

