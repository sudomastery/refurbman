#!/usr/bin/env python3
"""Copy the canonical report stylesheet into the standalone scripts.

`assets/report.css` is the single source. The Rust binary embeds it at compile
time with `include_str!`, but the PowerShell and shell scripts have to carry
their own copy, because the whole point of them is that they are one file you
can paste into a terminal on a machine you do not own.

That duplication is unavoidable, so it is made mechanical instead: this script
regenerates the embedded copies, and continuous integration runs it and fails if
anything changed. The copies therefore cannot drift from the original without
the build noticing.

Usage:
    python3 scripts/sync-report-css.py          # rewrite the embedded copies
    python3 scripts/sync-report-css.py --check  # exit 1 if they are stale
"""

import io
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CSS = ROOT / "assets" / "report.css"

# Each target names the delimiters the embedded copy sits between. The
# delimiters stay in the file; only what lies between them is replaced.
TARGETS = [
    (ROOT / "scripts" / "refurbman.sh", "<<'REFURBMAN_CSS'\n", "\nREFURBMAN_CSS\n"),
    (ROOT / "scripts" / "RefurbMan.ps1", "$css = @'\n", "\n'@\n"),
]


def read(path):
    return io.open(path, encoding="utf-8").read()


def main():
    check = "--check" in sys.argv
    css = read(CSS).strip("\n")
    stale = []

    for path, start, end in TARGETS:
        if not path.exists():
            print(f"missing target: {path}", file=sys.stderr)
            return 1
        text = read(path)
        try:
            i = text.index(start) + len(start)
            j = text.index(end, i)
        except ValueError:
            print(f"{path.name}: could not find the stylesheet markers", file=sys.stderr)
            return 1

        updated = text[:i] + css + text[j:]
        if updated == text:
            continue
        stale.append(path.name)
        if not check:
            io.open(path, "w", encoding="utf-8").write(updated)

    if check and stale:
        print(
            "These scripts carry a stale copy of assets/report.css: "
            + ", ".join(stale)
            + "\nRun: python3 scripts/sync-report-css.py",
            file=sys.stderr,
        )
        return 1

    if stale:
        print("updated: " + ", ".join(stale))
    else:
        print("stylesheet copies are already in step")
    return 0


if __name__ == "__main__":
    sys.exit(main())
