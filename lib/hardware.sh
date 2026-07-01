#!/usr/bin/env bash
# hardware.sh — HARDWARE section (CLAUDE.md §11). Static tier: probes the
# machine and renders a cache file. Privileged fields (serials, per-DIMM
# detail, SMART) degrade gracefully when not root (§5, §15).
#
# Probes flow through hw::_probe, which either runs the real command (gated by
# command -v, failure tolerated) or, when GDAY_FIXTURE_DIR is set, reads a
# captured fixture file. The fixture seam makes every row testable off-target.

[[ -n ${GDAY_HARDWARE_SH:-} ]] && return 0
GDAY_HARDWARE_SH=1

# hw::_probe — thin alias over the shared probe seam (render.sh).
hw::_probe() { gday::probe "$@"; }

# hw::_lsblk_out — memoized lsblk probe, one call per process. hw::storage and
# hw::smart_build both need this exact field set; without memoizing, a single
# `gday::build_static` run invoked lsblk twice (§18: no repeated expensive
# probes within a run).
HW_LSBLK_CACHED=0
HW_LSBLK_CACHE=''
hw::_lsblk_out() {
  if [[ $HW_LSBLK_CACHED -eq 0 ]]; then
    HW_LSBLK_CACHE=$(hw::_probe lsblk lsblk -d -e7 -n -o NAME,MODEL,SERIAL,SIZE,TYPE)
    HW_LSBLK_CACHED=1
  fi
  printf '%s' "$HW_LSBLK_CACHE"
}

# hw::_dmi_field <text> <Field Name> — value from a `dmidecode -t` block.
hw::_dmi_field() {
  local block=$1 field=$2 line val
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}   # ltrim
    [[ $line == "$field":* ]] || continue
    val=${line#*:}
    val=${val#"${val%%[![:space:]]*}"}       # ltrim value
    # Skip placeholder junk dmidecode commonly emits.
    case $val in
      ''|'To be filled by O.E.M.'|'Not Specified'|'Default string'|\
      'System manufacturer'|'System Product Name'|'System Version'|\
      'System Serial Number'|'Board Manufacturer'|'Board Product Name'|\
      'Board Version'|'Board Serial Number'|\
      'None'|'Unknown'|'Not Available'|'N/A') return 0 ;;
    esac
    printf '%s' "$val"
    return 0
  done <<< "$block"
}

# hw::system — System row from `dmidecode -t system`.
hw::system() {
  local out mfr prod ver serial val
  out=$(hw::_probe dmidecode-system dmidecode -t system)
  [[ -n $out ]] || return 0
  mfr=$(hw::_dmi_field "$out" 'Manufacturer')
  prod=$(hw::_dmi_field "$out" 'Product Name')
  ver=$(hw::_dmi_field "$out" 'Version')
  val="${mfr:+$mfr }${prod}"
  [[ -n $ver ]] && val="${val} (rev ${ver})"
  val=${val#"${val%%[![:space:]]*}"}
  [[ -n $val ]] || return 0
  render::wrap 'System' "$val"
  if [[ ${GDAY_ROOT:-0} -eq 1 ]]; then
    serial=$(hw::_dmi_field "$out" 'Serial Number')
    [[ -n $serial ]] && render::cont "S/N ${serial}"
  fi
}

# hw::mainboard — Mainboard row from `dmidecode -t baseboard`.
hw::mainboard() {
  local out mfr prod ver val
  out=$(hw::_probe dmidecode-baseboard dmidecode -t baseboard)
  [[ -n $out ]] || return 0
  mfr=$(hw::_dmi_field "$out" 'Manufacturer')
  prod=$(hw::_dmi_field "$out" 'Product Name')
  ver=$(hw::_dmi_field "$out" 'Version')
  val="${mfr:+$mfr }${prod}"
  [[ -n $ver ]] && val="${val} (rev ${ver})"
  val=${val#"${val%%[![:space:]]*}"}
  [[ -n $val ]] || return 0
  render::wrap 'Mainboard' "$val"
}

# hw::cpu — CPU row from `lscpu`: model name + cores/threads as "4C / 8T".
hw::cpu() {
  local out line model cores=0 threads_per=0 sockets=1 threads val
  out=$(hw::_probe lscpu lscpu)
  [[ -n $out ]] || return 0
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}   # ltrim; lscpu indents its keys
    case $line in
      'Model name:'*)            model=${line#*:} ;;
      'Core(s) per socket:'*)    cores=${line#*:} ;;
      'Thread(s) per core:'*)    threads_per=${line#*:} ;;
      'Socket(s):'*)             sockets=${line#*:} ;;
    esac
  done <<< "$out"
  model=${model#"${model%%[![:space:]]*}"}
  cores=${cores//[![:digit:]]/}
  threads_per=${threads_per//[![:digit:]]/}
  sockets=${sockets//[![:digit:]]/}
  [[ -n $model ]] || return 0
  val=$model
  if [[ ${cores:-0} -gt 0 && ${sockets:-0} -gt 0 ]]; then
    local total_cores=$(( cores * sockets ))
    threads=$(( total_cores * ${threads_per:-1} ))
    val="${model} — ${total_cores}C / ${threads}T"
  fi
  render::row 'CPU' "$val"
}

# hw::memory — total from /proc/meminfo (always); per-DIMM from dmidecode (root).
hw::memory() {
  local kb total line val
  if [[ -n ${GDAY_FIXTURE_DIR:-} && -r $GDAY_FIXTURE_DIR/meminfo ]]; then
    kb=$(awk '/^MemTotal:/{print $2}' "$GDAY_FIXTURE_DIR/meminfo" 2>/dev/null)
  elif [[ -r /proc/meminfo ]]; then
    kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
  fi
  if [[ -n $kb ]]; then
    # KiB → GiB, one decimal, integer math.
    total=$(( (kb * 10 + 524288) / 1048576 ))
    val="$(( total / 10 )).$(( total % 10 )) GiB"
    render::row 'Memory' "$val"
  fi
  [[ ${GDAY_ROOT:-0} -eq 1 ]] || return 0
  local out dimms
  out=$(hw::_probe dmidecode-memory dmidecode -t memory)
  [[ -n $out ]] || return 0
  # One continuation line per populated DIMM: "<size> <type> @ <speed>".
  dimms=$(awk '
    /^Memory Device/ {sz=""; ty=""; sp=""}
    /^[[:space:]]*Size:/ {s=$0; sub(/^[[:space:]]*Size:[[:space:]]*/,"",s); sz=s}
    /^[[:space:]]*Type:/ {s=$0; sub(/^[[:space:]]*Type:[[:space:]]*/,"",s); ty=s}
    /^[[:space:]]*Speed:/ {s=$0; sub(/^[[:space:]]*Speed:[[:space:]]*/,"",s); sp=s
      if (sz !~ /No Module|Not|Unknown|^$/) printf "%s %s @ %s\n", sz, ty, sp}
  ' <<< "$out")
  [[ -n $dimms ]] || return 0
  while IFS= read -r line; do
    [[ -n $line ]] && render::cont "$line"
  done <<< "$dimms"
}

# hw::gpu — one row per VGA/3D/Display device from `lspci`.
hw::gpu() {
  local out line name first=1
  out=$(hw::_probe lspci lspci)
  [[ -n $out ]] || return 0
  while IFS= read -r line; do
    case $line in
      *' VGA compatible controller: '*|*' 3D controller: '*|*' Display controller: '*)
        name=${line#*: }
        name=${name#*: }
        [[ -n $name ]] || continue
        if [[ $first -eq 1 ]]; then
          render::row 'GPU' "$name"; first=0
        else
          render::cont "$name"
        fi
        ;;
    esac
  done <<< "$out"
}

# hw::storage — one row per real disk from `lsblk`; serials are root-only.
hw::storage() {
  local out line name model serial size type first=1
  out=$(hw::_lsblk_out)
  [[ -n $out ]] || return 0
  # Collapse lsblk's column-padding (multiple spaces) to single spaces so
  # back-word parsing of TYPE, SIZE, SERIAL is not confused by trailing spaces.
  out=$(awk '{$1=$1; print}' <<< "$out")
  while IFS= read -r line; do
    # Fields are single-space-separated; MODEL may contain spaces, so parse
    # by stripping fixed trailing columns: TYPE, SIZE, SERIAL from the end.
    read -r name rest <<< "$line"
    [[ -n $name ]] || continue
    type=${rest##* }
    [[ $type == disk ]] || continue
    # zram is a virtual compressed-RAM device, not a storage disk; skip it.
    [[ $name == zram* ]] && continue
    rest=${rest% *}            # drop TYPE
    size=${rest##* }
    rest=${rest% *}            # drop SIZE
    serial=${rest##* }
    model=${rest% *}
    model=${model%"${model##*[![:space:]]}"}
    model=${model:-disk}
    local val="${name}: ${model} (${size})"
    if [[ $first -eq 1 ]]; then
      render::row 'Storage' "$val"; first=0
    else
      render::cont "$val"
    fi
    if [[ ${GDAY_ROOT:-0} -eq 1 && -n $serial && $serial != '-' ]]; then
      render::cont "  S/N ${serial}"
    fi
  done <<< "$out"
}

# hw::smart_build — run smartctl -H on each real disk and write smart.txt.
# Called by gday::build_static (static tier, root). Each line: "name: PASSED|FAILED".
hw::smart_build() {
  # In fixture mode, skip the root and tool checks so SMART is testable without root.
  if [[ -z ${GDAY_FIXTURE_DIR:-} ]]; then
    [[ ${GDAY_ROOT:-0} -eq 1 ]] || return 0
    command -v smartctl >/dev/null 2>&1 || return 0
  fi
  local lsblk_out line name rest type tmp result
  lsblk_out=$(hw::_lsblk_out)
  [[ -n $lsblk_out ]] || return 0
  lsblk_out=$(awk '{$1=$1; print}' <<< "$lsblk_out")
  tmp=$(mktemp "${GDAY_VAR}/.smart.XXXXXX") || return 0
  while IFS= read -r line; do
    read -r name rest <<< "$line"
    [[ -n $name ]] || continue
    type=${rest##* }
    [[ $type == disk ]] || continue
    [[ $name == zram* ]] && continue
    result=$(gday::probe "smartctl-${name}" smartctl -H "/dev/${name}") || true
    if grep -q 'PASSED' <<< "$result"; then
      printf '%s: PASSED\n' "$name" >> "$tmp"
    elif grep -q 'FAILED' <<< "$result"; then
      printf '%s: FAILED\n' "$name" >> "$tmp"
    fi
  done <<< "$lsblk_out"
  if [[ -s $tmp ]]; then
    chmod 0644 "$tmp"
    mv -f "$tmp" "${GDAY_VAR}/smart.txt"
  else
    rm -f "$tmp"
  fi
}

# hw::advisory — the single not-root advisory line (§11, §15).
hw::advisory() {
  [[ ${GDAY_ROOT:-0} -eq 1 ]] && return 0
  render::row '' '(run the static tier as root for serial numbers and SMART)'
}

# gday::hardware_section — assemble the full HARDWARE section to stdout.
gday::hardware_section() {
  render::header '💻' 'HARDWARE'
  hw::system
  hw::mainboard
  hw::cpu
  hw::memory
  hw::gpu
  hw::storage
  hw::advisory
}
