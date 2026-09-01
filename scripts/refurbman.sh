#!/usr/bin/env bash
#
# RefurbMan: check what is really inside a Linux PC, and how worn its parts are.
#
# A single self-contained script for checking a second-hand machine. It reads
# hardware from sources a seller cannot casually edit, and labels every reading
# with where it came from.
#
# Nothing here trusts a userspace string for a hardware claim. Identity comes
# from the firmware tables the kernel exports, the processor name comes from the
# CPU itself by way of /proc/cpuinfo, and drive and battery wear come from the
# parts' own controllers.
#
# Usage:
#   ./refurbman.sh                # full report
#   sudo ./refurbman.sh           # adds drive health and memory slot detail
#   ./refurbman.sh --json         # machine-readable
#   ./refurbman.sh --no-color     # for logs and pipes
#
# Run without installing anything:
#   curl -fsSL https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/refurbman.sh | bash
#
# Part of RefurbMan: https://github.com/sudomastery/refurbman
# Licensed GPL-3.0-or-later.

set -uo pipefail

JSON=0
COLOR=1
for arg in "$@"; do
  case "$arg" in
    --json)     JSON=1; COLOR=0 ;;
    --no-color) COLOR=0 ;;
    -h|--help)
      if [ -r "$0" ]; then sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
      else printf 'RefurbMan: see https://github.com/sudomastery/refurbman\n'; fi
      exit 0 ;;
  esac
done
[ -t 1 ] || COLOR=0

# ---------------------------------------------------------------------------
# Provenance
#
# The same five-rung ladder the desktop application uses. The rank is printed
# beside every reading so it is obvious which numbers carry weight.
# ---------------------------------------------------------------------------

if [ "$COLOR" = 1 ]; then
  R=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'
else
  R=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; GRAY=''
fi

trust_label() {
  case "$1" in
    device)   printf '%sDEVICE  %s' "$GREEN" "$R" ;;
    kernel)   printf '%sKERNEL  %s' "$CYAN" "$R" ;;
    firmware) printf '%sFIRMWARE%s' "$BLUE" "$R" ;;
    calc)     printf '%sCALC    %s' "$GRAY" "$R" ;;
    *)        printf '%sSOFTWARE%s' "$YELLOW" "$R" ;;
  esac
}

verdict_color() {
  case "$1" in
    good) printf '%s' "$GREEN" ;;
    fair) printf '%s' "$YELLOW" ;;
    poor) printf '%s' "$RED" ;;
    *)    printf '%s' "$GRAY" ;;
  esac
}

# Findings are collected as severity<TAB>title<TAB>detail<TAB>evidence and
# printed last, after everything that generates them has run.
FINDINGS_FILE="$(mktemp)"
trap 'rm -f "$FINDINGS_FILE"' EXIT

# Records are separated with the ASCII unit separator rather than a tab. Tab is
# an IFS whitespace character, which means bash collapses runs of them and
# discards empty fields, so a record with a blank middle column would shift
# every column after it. The unit separator has no such special treatment.
SEP=$'\037'

finding() { printf '%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "${4:-}" >> "$FINDINGS_FILE"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

read_file() { [ -r "$1" ] && tr -d '\0' < "$1" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//' || true; }

# OEMs leave placeholder junk in the firmware tables. Showing "To Be Filled By
# O.E.M." to someone deciding whether to buy a laptop is worse than showing
# nothing, because it looks like a reading.
clean() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$v" ] && return
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    "to be filled by o.e.m."|"to be filled by oem"|"default string"|\
    "not specified"|"not applicable"|"none"|"unknown"|"system manufacturer"|\
    "system product name"|"system version"|"system serial number"|"oem"|\
    "0123456789"|"x.x."|"chassis serial number") return ;;
  esac
  printf '%s' "$v"
}

fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b <= 0) { print ""; exit }
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    if (i == 1) printf "%d %s", b, u[i]
    else if (b >= 100) printf "%.0f %s", b, u[i]
    else printf "%.1f %s", b, u[i]
  }'
}

fmt_hours() {
  awk -v h="${1:-0}" 'BEGIN{
    if (h <= 0) { print ""; exit }
    y = h / 8760.0
    if (y >= 1) { printf "%.1f years", y; exit }
    d = h / 24.0
    if (d >= 1) { printf "%.0f days", d; exit }
    printf "%d hours", h
  }'
}

wrap() { printf '%s\n' "${1:-}" | fold -s -w "${2:-72}" | sed 's/[[:space:]]*$//'; }

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

banner() {
  printf '\n%s' "$CYAN"
  cat <<'ART'
    ____       ____           __    __  ___
   / __ \___  / __/_  _______/ /_  /  |/  /___ _____
  / /_/ / _ \/ /_/ / / / ___/ __ \/ /|_/ / __ `/ __ \
 / _, _/  __/ __/ /_/ / /  / /_/ / /  / / /_/ / / / /
/_/ |_|\___/_/  \__,_/_/  /_.___/_/  /_/\__,_/_/ /_/
ART
  printf '%s%s  what is really in this machine, and how worn it is%s\n\n' "$R" "$GRAY" "$R"
}

rule() {
  if [ -n "${1:-}" ]; then
    local t="$1" n
    n=$(( 78 - ${#t} - 4 ))
    [ "$n" -lt 0 ] && n=0
    printf '%s-- %s %s%s\n' "$CYAN" "$t" "$(printf '%*s' "$n" '' | tr ' ' '-')" "$R"
  else
    printf '%s%s%s\n' "$GRAY" "$(printf '%*s' 78 '' | tr ' ' '-')" "$R"
  fi
}

# row <label> <value> [trust] [unit]
row() {
  local label="$1" value="${2:-}" trust="${3:-firmware}" unit="${4:-}"
  [ -z "$value" ] && return
  [ -n "$unit" ] && value="$value $unit"
  printf '  %-22s %s%-40s%s %s\n' "$label" "$BOLD" "$value" "$R" "$(trust_label "$trust")"
}

note() { printf '  %-22s %s%s%s\n' '' "$GRAY" "$1" "$R"; }

# gauge <label> <percent|""> <verdict>
gauge() {
  local label="$1" pct="${2:-}" verdict="$3" col
  col="$(verdict_color "$verdict")"
  if [ -z "$pct" ]; then
    printf '  %-22s %s%-40s%s %s%s%s\n' "$label" "$GRAY" 'not reported' "$R" \
      "$col" "$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')" "$R"
    return
  fi
  local width=24 filled bar
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{v=int(p/100*w+0.5); if(v<0)v=0; if(v>w)v=w; print v}')
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $(( width - filled )) '' | tr ' ' '.')"
  printf '  %-22s %s[%s]%s %s%4.0f%%%s   %s%s%s\n' "$label" "$col" "$bar" "$R" \
    "$BOLD" "$pct" "$R" "$col" "$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')" "$R"
}

legend() {
  printf '\n  %sWhere each reading came from:%s\n' "$GRAY" "$R"
  printf '    %sDEVICE  %s the part itself answered. Faking it means reflashing the part.%s\n'    "$GREEN"  "$GRAY" "$R"
  printf '    %sKERNEL  %s the Linux kernel'"'"'s own view of the hardware.%s\n'                   "$CYAN"   "$GRAY" "$R"
  printf '    %sFIRMWARE%s the motherboard firmware tables. Faking it means reflashing the BIOS.%s\n' "$BLUE" "$GRAY" "$R"
  printf '    %sCALC    %s worked out by RefurbMan from the readings above.%s\n'                   "$GRAY"   "$GRAY" "$R"
  printf '    %sSOFTWARE%s editable settings. Never used to back a hardware claim.%s\n'            "$YELLOW" "$GRAY" "$R"
}

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

PRIVILEGED=0
[ "$(id -u)" = "0" ] && PRIVILEGED=1

# When the script is piped in from curl there is no file on disk to point at,
# so the advice has to name the pipeline rather than a path.
if [ -r "$0" ] && [ "$0" != "bash" ] && [ "$0" != "sh" ] && [ "$0" != "-" ]; then
  RERUN_HINT="sudo $0"
else
  RERUN_HINT="sudo, for example: curl -fsSL https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/refurbman.sh | sudo bash"
fi

DMI=/sys/class/dmi/id

collect_machine() {
  # The kernel exports the firmware tables field by field here and applies its
  # own permissions: make and model are world-readable, serials are root-only.
  # So an ordinary user still identifies the machine, and only the serials need
  # elevation.
  M_VENDOR="$(clean "$(read_file $DMI/sys_vendor)")"
  M_MODEL="$(clean "$(read_file $DMI/product_name)")"
  M_SERIAL="$(clean "$(read_file $DMI/product_serial)")"
  M_FAMILY="$(clean "$(read_file $DMI/product_family)")"
  M_SKU="$(clean "$(read_file $DMI/product_sku)")"
  M_BOARD="$(clean "$(read_file $DMI/board_vendor) $(read_file $DMI/board_name)")"
  M_BIOS="$(clean "$(read_file $DMI/bios_vendor) $(read_file $DMI/bios_version) $(read_file $DMI/bios_date)")"

  local ct; ct="$(read_file $DMI/chassis_type)"
  case "${ct:-0}" in
    3) M_CHASSIS="Desktop" ;;  4) M_CHASSIS="Low profile desktop" ;;
    6) M_CHASSIS="Mini tower" ;; 7) M_CHASSIS="Tower" ;;
    8) M_CHASSIS="Portable" ;; 9) M_CHASSIS="Laptop" ;;
    10) M_CHASSIS="Notebook" ;; 11) M_CHASSIS="Hand held" ;;
    13) M_CHASSIS="All in one" ;; 14) M_CHASSIS="Sub notebook" ;;
    17) M_CHASSIS="Main server chassis" ;; 23) M_CHASSIS="Rack mount" ;;
    30) M_CHASSIS="Tablet" ;; 31) M_CHASSIS="Convertible" ;; 32) M_CHASSIS="Detachable" ;;
    *) M_CHASSIS="" ;;
  esac
}

collect_cpu() {
  # The model name in /proc/cpuinfo is the brand string the kernel read out of
  # the processor with the CPUID instruction. It is the part describing itself,
  # so it ranks as a device reading rather than an operating system one.
  CPU_MODEL="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [ -z "$CPU_MODEL" ] && CPU_MODEL="$(awk -F': ' '/^Model/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"

  # A physical core is a unique package and core pair. Counting core_id alone
  # would merge cores that share an id across sockets.
  CPU_CORES="$(
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
      [ -r "$d/topology/core_id" ] || continue
      printf '%s-%s\n' "$(cat "$d/topology/physical_package_id" 2>/dev/null)" \
                       "$(cat "$d/topology/core_id" 2>/dev/null)"
    done | sort -u | grep -c . 2>/dev/null
  )"
  [ "${CPU_CORES:-0}" = "0" ] && CPU_CORES=""

  local khz; khz="$(read_file /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)"
  CPU_MAXMHZ=""
  [ -n "$khz" ] && CPU_MAXMHZ=$(( khz / 1000 ))

  # A hypervisor can forge every reading below, so it must be said plainly.
  CPU_HYPERVISOR=""
  if grep -qm1 '^flags.*\bhypervisor\b' /proc/cpuinfo 2>/dev/null; then
    CPU_HYPERVISOR="$(read_file /sys/hypervisor/type)"
    [ -z "$CPU_HYPERVISOR" ] && CPU_HYPERVISOR="unidentified"
    finding critical "This is a virtual machine, not physical hardware" \
      "The processor reports that it is running under virtualisation software. Everything else in this report describes what that software chose to present, not real parts. If you were expecting to be testing a physical computer, stop and check what you are connected to." \
      "hypervisor flag in /proc/cpuinfo, reported as $CPU_HYPERVISOR"
  fi
}

collect_memory() {
  MEM_KERNEL_BYTES="$(awk '/^MemTotal:/{print $2 * 1024; exit}' /proc/meminfo 2>/dev/null)"
  MEM_SLOTS_FILE="$(mktemp)"
  MEM_SMBIOS_BYTES=0
  MEM_SLOTS_TOTAL=0
  MEM_SLOTS_USED=0

  # Per-slot detail lives in SMBIOS type 17, which needs root. Without it the
  # kernel total is still reported, just without the breakdown.
  command -v dmidecode >/dev/null 2>&1 || return
  [ "$PRIVILEGED" = 1 ] || return

  local size locator type speed mfr part
  while IFS= read -r line; do
    case "$line" in
      "Memory Device")  size=""; locator=""; type=""; speed=""; mfr=""; part="" ;;
      *"Size: "*)       [ -z "$size" ] && size="${line#*Size: }" ;;
      *"Locator: "*)    case "$line" in *"Bank Locator"*) ;; *) locator="${line#*Locator: }" ;; esac ;;
      *"Type: "*)       case "$line" in *"Type Detail"*|*"Error Correction Type"*) ;; *) [ -z "$type" ] && type="${line#*Type: }" ;; esac ;;
      *"Configured Memory Speed: "*) speed="${line#*Configured Memory Speed: }" ;;
      *"Speed: "*)      [ -z "$speed" ] && speed="${line#*Speed: }" ;;
      *"Manufacturer: "*) mfr="$(clean "${line#*Manufacturer: }")" ;;
      *"Part Number: "*)  part="$(clean "${line#*Part Number: }")" ;;
      "")
        [ -z "${locator:-}" ] && continue
        MEM_SLOTS_TOTAL=$(( MEM_SLOTS_TOTAL + 1 ))
        local bytes=0
        case "${size:-}" in
          "No Module Installed"|""|"Unknown") bytes=0 ;;
          *" GB") bytes=$(( ${size% GB} * 1024 * 1024 * 1024 )) ;;
          *" MB") bytes=$(( ${size% MB} * 1024 * 1024 )) ;;
        esac
        if [ "$bytes" -gt 0 ]; then
          MEM_SLOTS_USED=$(( MEM_SLOTS_USED + 1 ))
          MEM_SMBIOS_BYTES=$(( MEM_SMBIOS_BYTES + bytes ))
        fi
        printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$locator" "$bytes" "${type:-}" "${speed:-}" "${mfr:-}" "${part:-}" \
          >> "$MEM_SLOTS_FILE"
        locator=""
        ;;
    esac
  done < <(dmidecode -t 17 2>/dev/null; printf '\n')

  # Firmware claiming sticks the kernel cannot see is a strong signal. Allow for
  # the slice firmware reserves for integrated graphics, which legitimately
  # hides a few hundred megabytes.
  if [ "$MEM_SMBIOS_BYTES" -gt 0 ] && [ -n "${MEM_KERNEL_BYTES:-}" ]; then
    local diff=$(( MEM_SMBIOS_BYTES - MEM_KERNEL_BYTES ))
    if [ "$diff" -gt 2147483648 ]; then
      finding critical "Installed memory does not match what the system can see" \
        "The firmware lists $(fmt_bytes $MEM_SMBIOS_BYTES) of memory across $MEM_SLOTS_USED slot(s), but the kernel only sees $(fmt_bytes $MEM_KERNEL_BYTES). A gap this large usually means a faulty stick, a stick that is not seated properly, or memory that is not really there." \
        "SMBIOS $MEM_SMBIOS_BYTES bytes against kernel $MEM_KERNEL_BYTES bytes"
    fi
  fi
}

BATT_FILE=""
collect_battery() {
  BATT_FILE="$(mktemp)"
  local d name model mfr tech cycles full design health status unit voltage
  for d in /sys/class/power_supply/*; do
    [ -d "$d" ] || continue
    [ "$(read_file "$d/type")" = "Battery" ] || continue
    [ "$(read_file "$d/present")" = "0" ] && continue

    name="$(basename "$d")"
    model="$(clean "$(read_file "$d/model_name")")"
    mfr="$(clean "$(read_file "$d/manufacturer")")"
    tech="$(clean "$(read_file "$d/technology")")"
    cycles="$(read_file "$d/cycle_count")"
    status="$(read_file "$d/status")"
    [ "${cycles:-0}" = "0" ] && cycles=""

    # The kernel exposes a pack in charge units or energy units depending on
    # what the firmware reports. Health is the same ratio either way.
    full="$(read_file "$d/charge_full")"
    design="$(read_file "$d/charge_full_design")"
    unit=charge
    if [ -z "$full" ] || [ -z "$design" ]; then
      full="$(read_file "$d/energy_full")"
      design="$(read_file "$d/energy_full_design")"
      unit=energy
    fi

    health=""; local design_wh="" now_wh=""
    if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ] 2>/dev/null; then
      health="$(awk -v f="$full" -v d="$design" 'BEGIN{printf "%.1f", f/d*100}')"
      if [ "$unit" = charge ]; then
        voltage="$(read_file "$d/voltage_min_design")"
        if [ -n "$voltage" ] && [ "$voltage" -gt 0 ] 2>/dev/null; then
          design_wh="$(awk -v c="$design" -v v="$voltage" 'BEGIN{printf "%.1f", c*v/1e12}')"
          now_wh="$(awk -v c="$full" -v v="$voltage" 'BEGIN{printf "%.1f", c*v/1e12}')"
        fi
      else
        design_wh="$(awk -v e="$design" 'BEGIN{printf "%.1f", e/1e6}')"
        now_wh="$(awk -v e="$full" 'BEGIN{printf "%.1f", e/1e6}')"
      fi
    fi

    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
      "${model:-$name}" "${mfr:-}" "${tech:-}" "${cycles:-}" "${health:-}" \
      "${design_wh:-}" "${now_wh:-}" "${status:-}" "$d" >> "$BATT_FILE"
  done
}

# Judge one battery. Echoes: verdict<TAB>percent<TAB>headline
assess_battery() {
  local name="$1" health="$2" cycles="$3" verdict percent headline

  if [ -z "$health" ]; then
    finding info "Battery health could not be read" \
      "The battery did not report the figures needed to work out how much capacity it has lost. This is common on desktops and on some older laptops, and is not a sign of a fault."
    printf 'unknown\037\037This battery would not report its condition.\n'
    return
  fi

  percent="$health"

  # A pack charged hundreds of times has not kept every last percent. When it
  # claims otherwise, the laptop is repeating its factory rating rather than
  # measuring the pack, so the figure must not be presented as a health reading.
  if [ -n "$cycles" ] && awk -v h="$health" 'BEGIN{exit !(h >= 99.5)}' && [ "$cycles" -gt 200 ] 2>/dev/null; then
    finding warn "Battery health figure looks unreliable" \
      "This battery claims $(printf '%.0f' "$health")% of its original capacity while also reporting $cycles charge cycles. A pack that has been charged that many times has almost always lost noticeable capacity, so this laptop is very likely reporting its factory rating rather than measuring the pack. Judge this battery by how long it actually lasts unplugged, not by this number." \
      "health $health% from charge_full / charge_full_design, cycle_count $cycles"
    printf 'unknown\037%s\037Reports perfect health after %s charge cycles, which is unlikely to be measured.\n' "$percent" "$cycles"
    return
  fi

  if awk -v h="$health" 'BEGIN{exit !(h >= 80)}'; then
    verdict=good
    headline="Holds $(printf '%.0f' "$health")% of its original charge. In good shape."
  elif awk -v h="$health" 'BEGIN{exit !(h >= 60)}'; then
    verdict=fair
    headline="Holds $(printf '%.0f' "$health")% of its original charge. Noticeably worn but usable."
    finding warn "Battery has lost some capacity" \
      "This battery holds about $(printf '%.0f' "$health")% of what it held when new, so it will last roughly that share of the original time between charges. A replacement is worth pricing up when you negotiate."
  else
    verdict=poor
    headline="Holds only $(printf '%.0f' "$health")% of its original charge. Expect a short time unplugged."
    finding critical "Battery is worn out" \
      "This battery holds only about $(printf '%.0f' "$health")% of its original capacity. It will need replacing soon, and on many laptops that is not a cheap or simple job. Factor the cost of a new pack into the price."
  fi

  if [ -n "$cycles" ] && [ "$cycles" -ge 1000 ] 2>/dev/null; then
    finding warn "Battery has been charged a great many times" \
      "This pack has been through $cycles charge cycles. Most laptop batteries are designed for 300 to 500, so it is well past its intended service life even if it still tests reasonably." \
      "cycle_count $cycles"
  fi

  printf '%s\037%s\037%s\n' "$verdict" "$percent" "$headline"
}

DRIVE_FILE=""
HAVE_SMARTCTL=0
collect_drives() {
  DRIVE_FILE="$(mktemp)"
  command -v smartctl >/dev/null 2>&1 && HAVE_SMARTCTL=1

  local d name size bytes rot model serial fw

  for d in /sys/block/*; do
    name="$(basename "$d")"
    # Skip virtual devices: loop, ram, zram, device mapper.
    case "$name" in loop*|ram*|zram*|dm-*|md*|sr*) continue ;; esac

    size="$(read_file "$d/size")"
    bytes=0
    [ -n "$size" ] && bytes=$(( size * 512 ))
    rot="$(read_file "$d/queue/rotational")"
    model="$(clean "$(read_file "$d/device/model")")"
    [ -z "$model" ] && model="$(clean "$(read_file "$d/device/device/model")")"
    [ -z "$model" ] && model="$name"
    fw="$(clean "$(read_file "$d/device/firmware_rev")")"

    # SMART fields, filled in below when smartctl can open the device.
    local wear="" hours="" temp="" passed="" reall="" pend="" uncorr="" crc="" media="" written=""
    local locked=1 devnode="/dev/$name"

    if [ "$HAVE_SMARTCTL" = 1 ]; then
      local json
      json="$(smartctl --json=c -a "$devnode" 2>/dev/null)"
      if [ -n "$json" ] && printf '%s' "$json" | grep -q '"model_name"\|"nvme_smart_health_information_log"\|"ata_smart_attributes"'; then
        locked=0
        eval "$(printf '%s' "$json" | smart_fields)"
      fi
    fi

    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
      "$model" "$bytes" "${rot:-}" "${fw:-}" "$locked" \
      "${wear:-}" "${hours:-}" "${temp:-}" "${passed:-}" \
      "${reall:-}" "${pend:-}" "${uncorr:-}" "${crc:-}" "${media:-}" >> "$DRIVE_FILE"
  done
}

# Read the fields we need out of smartctl JSON and emit shell assignments.
# Python is used when present because parsing JSON with a regular expression is
# how subtle bugs get in; the grep fallback covers the rare box without it.
smart_fields() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def g(*path):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur

def attr(i, field="raw"):
    for a in (g("ata_smart_attributes", "table") or []):
        if a.get("id") == i:
            return a["raw"]["value"] if field == "raw" else a.get("value")
    return None

out = {}
nvme = g("nvme_smart_health_information_log")
if nvme:
    out["wear"]  = nvme.get("percentage_used")
    out["media"] = nvme.get("media_errors")
    du = nvme.get("data_units_written")
    if du is not None:
        out["written"] = du * 512 * 1000
else:
    eu = g("endurance_used", "current_percent")
    if eu is not None:
        out["wear"] = eu
    else:
        for i in (231, 177, 202):
            v = attr(i, "value")
            if v is not None and v <= 100:
                out["wear"] = 100 - v
                break
    out["reall"]  = attr(5)
    out["pend"]   = attr(197)
    out["uncorr"] = attr(198)
    out["crc"]    = attr(199)
    lba = attr(241)
    if lba is not None:
        out["written"] = lba * 512

out["hours"] = g("power_on_time", "hours")
out["temp"]  = g("temperature", "current")
p = g("smart_status", "passed")
if p is not None:
    out["passed"] = "1" if p else "0"

for k, v in out.items():
    if v is not None:
        print("%s=%s" % (k, shlex.quote(str(v))))
'
  else
    # Minimal fallback: pull the handful of scalars we need with grep.
    local j; j="$(cat)"
    printf '%s' "$j" | grep -o '"percentage_used":[0-9]*' | head -1 | sed 's/.*:/wear=/'
    printf '%s' "$j" | grep -o '"media_errors":[0-9]*'    | head -1 | sed 's/.*:/media=/'
    printf '%s' "$j" | grep -o '"hours":[0-9]*'           | head -1 | sed 's/.*:/hours=/'
    printf '%s' "$j" | grep -o '"current":[0-9]*'         | head -1 | sed 's/.*:/temp=/'
    printf '%s' "$j" | grep -q '"passed":true' && printf 'passed=1\n'
    printf '%s' "$j" | grep -q '"passed":false' && printf 'passed=0\n'
  fi
}

# Judge one drive. Echoes: verdict<TAB>percent<TAB>headline
assess_drive() {
  local model="$1" locked="$2" wear="$3" hours="$4" passed="$5"
  local reall="${6:-0}" pend="${7:-0}" uncorr="${8:-0}" crc="${9:-0}" media="${10:-0}"
  local verdict=good percent="" headline=""

  if [ "$locked" = 1 ]; then
    printf 'unknown\037\037Health could not be read without permission.\n'
    return
  fi

  # Rank so the worst finding wins regardless of the order checks run in.
  worse() {
    local rank_cur rank_new
    case "$verdict" in good) rank_cur=0 ;; fair) rank_cur=1 ;; unknown) rank_cur=2 ;; poor) rank_cur=3 ;; esac
    case "$1"       in good) rank_new=0 ;; fair) rank_new=1 ;; unknown) rank_new=2 ;; poor) rank_new=3 ;; esac
    [ "$rank_new" -gt "$rank_cur" ] && verdict="$1"
  }

  # The drive's own overall judgement. When a drive says it is failing, nothing
  # else outranks that.
  if [ "$passed" = "0" ]; then
    worse poor
    finding critical "The drive reports that it is failing" \
      "$model has raised its own failure warning. That is the strongest signal a drive can give, and it means data loss is likely. Do not buy this machine on the assumption the drive can be relied on." \
      "smart_status.passed = false"
  fi

  if [ -n "$wear" ]; then
    percent="$(awk -v w="$wear" 'BEGIN{v=100-w; if(v<0)v=0; if(v>100)v=100; printf "%.0f", v}')"
    if [ "$wear" -ge 90 ] 2>/dev/null; then
      worse poor
      finding critical "The drive is nearly worn out" \
        "$model reports that it has used ${wear}% of the write life it was designed for. It is close to the end of its service life and should be treated as needing replacement."
    elif [ "$wear" -ge 70 ] 2>/dev/null; then
      worse fair
      finding warn "The drive is significantly worn" \
        "$model reports that it has used ${wear}% of its designed write life. It works now, but it has more life behind it than ahead of it. Price a replacement into the deal."
    elif [ "$wear" -ge 30 ] 2>/dev/null; then
      worse fair
    fi
  fi

  if [ "${reall:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$reall" -ge 50 ]; then worse poor; else worse fair; fi
    finding warn "The drive has replaced failed areas of its surface" \
      "$reall area(s) of $model stopped working and were swapped for spares. A handful can be normal on an older drive, but the count only ever goes up, so watch it. A drive doing this repeatedly is on its way out." \
      "Reallocated_Sector_Ct raw = $reall"
  fi

  if [ "${pend:-0}" -gt 0 ] 2>/dev/null || [ "${uncorr:-0}" -gt 0 ] 2>/dev/null; then
    worse poor
    finding critical "The drive has areas it can no longer read" \
      "$model has ${pend:-0} area(s) waiting to be dealt with and ${uncorr:-0} it could not recover. That means data on this drive is already being lost. Do not rely on this drive." \
      "Current_Pending_Sector ${pend:-0}, Offline_Uncorrectable ${uncorr:-0}"
  fi

  if [ "${media:-0}" -gt 0 ] 2>/dev/null; then
    worse fair
    finding warn "The drive has reported unrecoverable errors" \
      "$model logged ${media} error(s) it could not correct. On a solid state drive this usually points to failing memory cells." \
      "media_errors = $media"
  fi

  if [ "${crc:-0}" -gt 0 ] 2>/dev/null; then
    finding info "Errors seen on the cable between drive and computer" \
      "There have been ${crc} communication errors on the drive's cable. This is usually a loose or poor quality cable rather than a fault in the drive." \
      "UDMA_CRC_Error_Count = $crc"
  fi

  # The counter reset check, and the reason this tool exists. A drive with real
  # wear but almost no recorded running time has had its hours cleared, which is
  # done to make a heavily used drive look new.
  if [ -n "$hours" ] && [ -n "$wear" ]; then
    if [ "$hours" -lt 100 ] 2>/dev/null && [ "$wear" -gt 5 ] 2>/dev/null; then
      worse unknown
      finding critical "This drive's usage history does not add up" \
        "$model reports only $hours hours of use, yet also reports ${wear}% of its write life consumed. Those two figures cannot both be true: wearing a drive that far takes far longer than $hours hours. The most likely explanation is that the usage counters have been reset to make the drive look newer than it is. Treat this drive, and this seller, with caution." \
        "power_on_time.hours = $hours against life used ${wear}%"
    fi
  fi

  local age; age="$(fmt_hours "${hours:-0}")"
  if [ -n "$percent" ]; then
    case "$verdict" in
      good) if [ -n "$age" ]; then headline="Healthy, with ${percent}% of its life left after $age of use."
            else headline="Healthy, with ${percent}% of its life left."; fi ;;
      fair) headline="Worn but working, with ${percent}% of its life left." ;;
      poor) headline="Near the end of its life, with ${percent}% left." ;;
      *)    headline="This drive's reported history is inconsistent." ;;
    esac
  else
    case "$verdict" in
      good) if [ -n "$age" ]; then headline="No faults reported after $age of use."
            else headline="No faults reported."; fi ;;
      poor) headline="This drive is failing and should not be relied on." ;;
      *)    headline="This drive is showing early signs of wear." ;;
    esac
  fi

  printf '%s\037%s\037%s\n' "$verdict" "$percent" "$headline"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

collect_machine
collect_cpu
collect_memory
collect_battery
collect_drives

if [ "$PRIVILEGED" = 0 ]; then
  finding info "A full check needs administrator rights" \
    "This scan ran as an ordinary user, so the drives could not be asked about their own condition and the memory slot breakdown is missing. Everything else above is complete. To see the rest, run it again with $RERUN_HINT"
fi

if [ "$HAVE_SMARTCTL" = 0 ]; then
  finding info "Drive health tool is not installed" \
    "Drive wear is read using smartctl, which is not present on this machine. Install it to see how much life the drives have left. On Fedora: sudo dnf install smartmontools. On Debian or Ubuntu: sudo apt install smartmontools."
fi

if [ "$JSON" = 1 ]; then
  # Emitted by hand rather than with a JSON library so the script keeps its
  # promise of needing nothing installed.
  esc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{\n'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "tool": "RefurbMan shell",\n'
  printf '  "privileged": %s,\n' "$([ "$PRIVILEGED" = 1 ] && echo true || echo false)"
  printf '  "machine": {"manufacturer": "%s", "model": "%s", "serial": "%s", "chassis": "%s", "board": "%s", "bios": "%s"},\n' \
    "$(esc "$M_VENDOR")" "$(esc "$M_MODEL")" "$(esc "$M_SERIAL")" "$(esc "$M_CHASSIS")" "$(esc "$M_BOARD")" "$(esc "$M_BIOS")"
  printf '  "cpu": {"model": "%s", "cores": %s, "threads": %s, "hypervisor": "%s"},\n' \
    "$(esc "$CPU_MODEL")" "${CPU_CORES:-null}" "${CPU_THREADS:-null}" "$(esc "$CPU_HYPERVISOR")"
  printf '  "memory": {"kernelBytes": %s, "smbiosBytes": %s, "slotsUsed": %s, "slotsTotal": %s},\n' \
    "${MEM_KERNEL_BYTES:-null}" "$MEM_SMBIOS_BYTES" "$MEM_SLOTS_USED" "$MEM_SLOTS_TOTAL"
  printf '  "drives": [\n'
  first=1
  while IFS="$SEP" read -r model bytes rot fw locked wear hours temp passed reall pend uncorr crc media; do
    [ "$first" = 1 ] || printf ',\n'; first=0
    IFS="$SEP" read -r v p _ < <(assess_drive "$model" "$locked" "$wear" "$hours" "$passed" "$reall" "$pend" "$uncorr" "$crc" "$media")
    printf '    {"model": "%s", "bytes": %s, "verdict": "%s", "lifeRemaining": %s, "powerOnHours": %s}' \
      "$(esc "$model")" "${bytes:-0}" "$v" "${p:-null}" "${hours:-null}"
  done < "$DRIVE_FILE"
  printf '\n  ],\n  "batteries": [\n'
  first=1
  while IFS="$SEP" read -r model mfr tech cycles health dwh nwh status path; do
    [ "$first" = 1 ] || printf ',\n'; first=0
    IFS="$SEP" read -r v p _ < <(assess_battery "$model" "$health" "$cycles")
    printf '    {"model": "%s", "verdict": "%s", "healthPercent": %s, "cycleCount": %s}' \
      "$(esc "$model")" "$v" "${p:-null}" "${cycles:-null}"
  done < "$BATT_FILE"
  printf '\n  ]\n}\n'
  exit 0
fi

banner
rule "This machine"
echo
[ -n "$M_VENDOR$M_MODEL" ] && printf '  %s%s %s%s\n' "$BOLD" "$M_VENDOR" "$M_MODEL" "$R"
[ -n "$M_CHASSIS" ] && printf '  %s%s%s\n' "$GRAY" "$M_CHASSIS" "$R"
echo
row "Manufacturer"  "$M_VENDOR"
row "Model"         "$M_MODEL"
row "Serial number" "$M_SERIAL"
row "Motherboard"   "$M_BOARD"
row "BIOS"          "$M_BIOS"
if [ -z "$M_SERIAL" ] && [ "$PRIVILEGED" = 0 ]; then
  note "serial number needs sudo"
fi

echo
rule "Processor"
echo
row "Model"       "$CPU_MODEL" device
row "Cores"       "${CPU_CORES:-}" kernel
row "Threads"     "${CPU_THREADS:-}" kernel
row "Rated speed" "${CPU_MAXMHZ:-}" kernel "MHz"
[ -n "$CPU_HYPERVISOR" ] && row "Virtualised under" "$CPU_HYPERVISOR" device
echo
printf '  %sRead from the processor itself with the CPUID instruction, so it cannot be%s\n' "$GRAY" "$R"
printf '  %schanged by editing a configuration file.%s\n' "$GRAY" "$R"

echo
rule "Memory"
echo
[ "$MEM_SMBIOS_BYTES" -gt 0 ] && row "Installed"  "$(fmt_bytes "$MEM_SMBIOS_BYTES")"
[ "$MEM_SLOTS_TOTAL" -gt 0 ]  && row "Slots used" "$MEM_SLOTS_USED of $MEM_SLOTS_TOTAL"
row "System can see" "$(fmt_bytes "${MEM_KERNEL_BYTES:-0}")" kernel
if [ "$MEM_SLOTS_TOTAL" -gt 0 ]; then
  echo
  while IFS="$SEP" read -r locator bytes type speed mfr part; do
    if [ "${bytes:-0}" -eq 0 ]; then
      printf '  %-22s %s%s%s\n' "$locator" "$GRAY" "empty" "$R"
      continue
    fi
    line="$(fmt_bytes "$bytes")"
    [ -n "$type" ] && line="$line $type"
    case "$speed" in ""|"Unknown") ;; *) line="$line at $speed" ;; esac
    row "$locator" "$line"
    [ -n "$mfr$part" ] && note "$(printf '%s %s' "$mfr" "$part" | sed 's/^ //; s/ $//')"
  done < "$MEM_SLOTS_FILE"
elif [ "$PRIVILEGED" = 0 ]; then
  note "per-slot detail needs sudo"
fi

echo
rule "Storage"
if [ ! -s "$DRIVE_FILE" ]; then
  echo; printf '  %sNo drives reported.%s\n' "$GRAY" "$R"
fi
while IFS="$SEP" read -r model bytes rot fw locked wear hours temp passed reall pend uncorr crc media; do
  IFS="$SEP" read -r verdict percent headline < <(
    assess_drive "$model" "$locked" "$wear" "$hours" "$passed" "$reall" "$pend" "$uncorr" "$crc" "$media")
  echo
  printf '  %s%s%s\n' "$BOLD" "$model" "$R"
  printf '  %s%s%s\n' "$(verdict_color "$verdict")" "$headline" "$R"
  echo
  gauge "Life remaining" "$percent" "$verdict"
  row "Capacity" "$(fmt_bytes "$bytes")" kernel
  case "${rot:-}" in
    0) row "Type" "Solid state" kernel ;;
    1) row "Type" "Hard disk"   kernel ;;
  esac
  row "Firmware"         "$fw" device
  row "Powered on for"   "$(fmt_hours "${hours:-0}")" device
  row "Temperature"      "${temp:-}" device "C"
  [ -n "$wear" ] && row "Life used" "$wear" device "%"
  case "${passed:-}" in
    1) row "Drive self-check" "Passed" device ;;
    0) row "Drive self-check" "FAILED" device ;;
  esac
done < "$DRIVE_FILE"

if [ -s "$BATT_FILE" ]; then
  echo
  rule "Battery"
  while IFS="$SEP" read -r model mfr tech cycles health dwh nwh status path; do
    IFS="$SEP" read -r verdict percent headline < <(assess_battery "$model" "$health" "$cycles")
    echo
    printf '  %s%s%s\n' "$BOLD" "$model" "$R"
    printf '  %s%s%s\n' "$(verdict_color "$verdict")" "$headline" "$R"
    echo
    gauge "Health" "$percent" "$verdict"
    row "Capacity when new" "$dwh" device "Wh"
    row "Capacity now"      "$nwh" device "Wh"
    if [ -n "$cycles" ]; then
      row "Charge cycles" "$cycles" device
    else
      printf '  %-22s %s%s%s\n' "Charge cycles" "$GRAY" "not reported by this battery" "$R"
    fi
    row "Chemistry"    "$tech" device
    row "Manufacturer" "$mfr"  device
  done < "$BATT_FILE"
fi

echo
rule "What you should know"
echo
if [ ! -s "$FINDINGS_FILE" ]; then
  printf '  %sNothing of concern was found.%s\n\n' "$GREEN" "$R"
else
  for sev in critical warn info; do
    while IFS="$SEP" read -r s title detail evidence; do
      [ "$s" = "$sev" ] || continue
      case "$s" in
        critical) col="$RED";    mark='[!]' ;;
        warn)     col="$YELLOW"; mark='[*]' ;;
        *)        col="$CYAN";   mark='[i]' ;;
      esac
      printf '  %s%s %s%s\n' "$col" "$mark" "$title" "$R"
      wrap "$detail" 72 | while IFS= read -r l; do printf '      %s\n' "$l"; done
      [ -n "$evidence" ] && printf '      %sevidence: %s%s\n' "$GRAY" "$evidence" "$R"
      echo
    done < "$FINDINGS_FILE"
  done
fi

legend

echo
rule
printf '  %sThis report raises the effort needed to deceive you from editing a text file%s\n' "$GRAY" "$R"
printf '  %sto reflashing firmware. It is not proof. Someone with deep access to this%s\n' "$GRAY" "$R"
printf '  %smachine can still lie to it, so treat it as strong evidence rather than a%s\n' "$GRAY" "$R"
printf '  %sguarantee, and weigh it against how the machine actually behaves.%s\n' "$GRAY" "$R"
echo

rm -f "$MEM_SLOTS_FILE" "$BATT_FILE" "$DRIVE_FILE" 2>/dev/null
