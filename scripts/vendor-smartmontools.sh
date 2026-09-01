#!/usr/bin/env bash
#
# Fetch the pinned smartmontools release and place smartctl where RefurbMan
# looks for it.
#
# The version and its checksums come from third_party/smartmontools/pinned.env,
# so there is one place to change them. A download whose checksum does not match
# is deleted rather than used: a silently substituted smartctl would report drive
# health that nobody could account for, which is the one thing this project must
# never do.
#
# Usage:
#   ./scripts/vendor-smartmontools.sh              # host platform
#   ./scripts/vendor-smartmontools.sh --windows    # also fetch the Windows build
#   ./scripts/vendor-smartmontools.sh --source     # only the source tarball
#
# The source tarball is what satisfies the GPL-2.0 written offer; see
# third_party/smartmontools/SOURCE-OFFER.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party/smartmontools"
# shellcheck source=../third_party/smartmontools/pinned.env
. "$VENDOR/pinned.env"

WANT_WINDOWS=0
WANT_SOURCE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --windows) WANT_WINDOWS=1 ;;
    --source)  WANT_SOURCE_ONLY=1 ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

V="$SMARTMONTOOLS_VERSION"
BASE="$SMARTMONTOOLS_BASE_URL/$V"
OUT="$VENDOR/src"
BIN="$VENDOR/bin"
mkdir -p "$OUT" "$BIN"

say() { printf '  %s\n' "$*"; }

# fetch <url> <destination> <expected sha256>
fetch() {
  local url="$1" dest="$2" want="$3" got
  if [ -f "$dest" ]; then
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
      say "already have $(basename "$dest")"
      return 0
    fi
    say "re-downloading $(basename "$dest"): checksum did not match"
    rm -f "$dest"
  fi

  say "downloading $(basename "$dest")"
  if ! curl -fsSL --retry 3 -o "$dest" "$url"; then
    printf 'error: could not download %s\n' "$url" >&2
    rm -f "$dest"
    exit 1
  fi

  got="$(sha256sum "$dest" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    # Refuse rather than continue. An unverified smartctl would produce health
    # figures this project could not stand behind.
    printf 'error: checksum mismatch for %s\n  expected %s\n  got      %s\n' \
      "$(basename "$dest")" "$want" "$got" >&2
    rm -f "$dest"
    exit 1
  fi
  say "verified $(basename "$dest")"
}

printf '\nsmartmontools %s\n\n' "$V"

# --- source, always: this is what the GPL written offer points at ------------
SRC_TGZ="$OUT/smartmontools-$V.tar.gz"
fetch "$BASE/smartmontools-$V.tar.gz/download" "$SRC_TGZ" "$SMARTMONTOOLS_SOURCE_SHA256"

if [ "$WANT_SOURCE_ONLY" = 1 ]; then
  printf '\nSource is at %s\n\n' "$SRC_TGZ"
  exit 0
fi

# --- Windows binary ----------------------------------------------------------
if [ "$WANT_WINDOWS" = 1 ]; then
  if ! command -v 7z >/dev/null 2>&1; then
    printf 'error: 7z is needed to unpack the Windows installer.\n' >&2
    printf '  Fedora: sudo dnf install p7zip-plugins\n  Debian: sudo apt install p7zip-full\n' >&2
    exit 1
  fi
  WIN_EXE="$OUT/smartmontools-$V.win32-setup.exe"
  fetch "$BASE/smartmontools-$V.win32-setup.exe/download" "$WIN_EXE" "$SMARTMONTOOLS_WIN32_SHA256"

  say "unpacking the Windows build"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  7z x -o"$TMP" -y "$WIN_EXE" >/dev/null

  # bin/ is the x86-64 build, bin32/ the 32-bit one. drivedb.h has to travel
  # with smartctl: without it, vendor-specific attributes lose their meaning.
  mkdir -p "$BIN/windows-x86_64"
  cp "$TMP/bin/smartctl.exe" "$BIN/windows-x86_64/"
  cp "$TMP/bin/drivedb.h"    "$BIN/windows-x86_64/"
  say "placed smartctl.exe and drivedb.h in bin/windows-x86_64"
fi

# --- host binary -------------------------------------------------------------
# On Linux the distribution package is preferred: it is built against the local
# system, gets security updates, and is what a user can independently re-run to
# check RefurbMan's arithmetic.
if [ "$WANT_WINDOWS" = 0 ]; then
  if command -v smartctl >/dev/null 2>&1; then
    say "using the system smartctl: $(command -v smartctl)"
    say "$(smartctl --version | head -1)"
  else
    printf '\n  No smartctl on this system. Drive health needs it.\n'
    printf '    Fedora: sudo dnf install smartmontools\n'
    printf '    Debian: sudo apt install smartmontools\n'
    printf '    Arch:   sudo pacman -S smartmontools\n'
  fi
fi

printf '\nSource for the GPL offer: %s\n' "$SRC_TGZ"
printf 'Licence and offer:        %s\n\n' "$VENDOR/SOURCE-OFFER.md"
