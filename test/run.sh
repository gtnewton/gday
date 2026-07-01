#!/usr/bin/env bash
# test/run.sh — smoke-test runner for g’day.
#
# Drives every section against each fixture set under test/fixtures*/,
# plus any test/capture-*/ dirs present. Prints a PASS/FAIL summary;
# exits non-zero if any check fails.
#
# Usage:
#   ./test/run.sh           # all fixture sets
#   ./test/run.sh test/fixtures   # one specific fixture dir
set -euo pipefail

here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gday="$here/gday"

PASS=0; FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

ok()   { printf '  ✅  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  ❌  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
hdr()  { printf '\n── %s ──\n' "$*"; }

# check <label> <fixture_dir> <env_extras...> -- <expected_patterns...>
# Runs gday (with optional extra env) and greps for each expected pattern.
# A non-empty result that contains all patterns → PASS; else → FAIL.
run_section() {
  local label=$1 fdir=$2; shift 2
  local extra_env=() patterns=() sep=0
  for arg in "$@"; do
    if [[ $arg == '--' ]]; then sep=1; continue; fi
    (( sep )) && patterns+=("$arg") || extra_env+=("$arg")
  done

  local out
  out=$(env GDAY_FIXTURE_DIR="$fdir" "${extra_env[@]+"${extra_env[@]}"}" \
        GDAY_VAR="$tmpdir" "$gday" ${section:+--section "$section"} 2>/dev/null) || true

  if [[ -z $out ]]; then
    fail "$label: empty output"
    return
  fi

  local p ok_=1
  for p in "${patterns[@]}"; do
    if ! grep -qF "$p" <<< "$out" 2>/dev/null; then
      fail "$label: missing «$p»"
      ok_=0
    fi
  done
  (( ok_ )) && ok "$label"
}

run_assemble() {
  local label=$1 fdir=$2; shift 2
  local patterns=("$@")
  local out
  out=$(env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" "$gday" 2>/dev/null) || true
  if [[ -z $out ]]; then fail "$label: empty output"; return; fi
  local p ok_=1
  for p in "${patterns[@]}"; do
    if ! grep -qF "$p" <<< "$out"; then fail "$label: missing «$p»"; ok_=0; fi
  done
  (( ok_ )) && ok "$label"
}

# ── fixture sets to test ──────────────────────────────────────────────────────

if [[ $# -gt 0 ]]; then
  fixture_dirs=("$@")
else
  fixture_dirs=()
  for d in "$here/test/fixtures" "$here/test/fixtures-degraded" "$here/test"/capture-*/; do
    [[ -d $d ]] && fixture_dirs+=("$d")
  done
fi

# ── run ───────────────────────────────────────────────────────────────────────

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

section=''

for fdir in "${fixture_dirs[@]}"; do
  fname=$(basename "$fdir")
  hdr "$fname"

  # Detect PM for this fixture set.
  pm=unknown
  if [[ -r $fdir/os-release ]]; then
    id=$(grep '^ID=' "$fdir/os-release" | cut -d= -f2 | tr -d '"')
    id_like=$(grep '^ID_LIKE=' "$fdir/os-release" | cut -d= -f2 | tr -d '"' || true)
    case "$id $id_like" in
      *ubuntu*|*debian*) pm=apt ;;
      *fedora*|*rhel*|*centos*) pm=dnf ;;
      *arch*)  pm=pacman ;;
      *suse*)  pm=zypper ;;
    esac
  fi

  # ── Full assemble ────────────────────────────────────────────────────────
  section=''
  run_assemble "assemble/full" "$fdir" \
    "HARDWARE" "DISK USAGE" "OPERATING SYSTEM" "STATUS" "g’day · generated"

  # ── Banner ───────────────────────────────────────────────────────────────
  section=banner
  hostname_val=$(cat "$fdir/hostname" 2>/dev/null || true)
  if [[ -n $hostname_val ]]; then
    run_section "banner/hostname" "$fdir" -- "$hostname_val"
  fi
  if [[ -r $fdir/figlet ]]; then
    run_section "banner/figlet-art" "$fdir" -- "$(head -1 "$fdir/figlet")"
  fi

  # ── Hardware ─────────────────────────────────────────────────────────────
  section=hardware
  run_section "hardware/header" "$fdir" -- "HARDWARE"
  if [[ -r $fdir/lscpu ]]; then
    # CPU model name (first word of the model line is enough)
    cpu_word=$(grep -i 'model name' "$fdir/lscpu" | head -1 | cut -d: -f2 | awk '{print $1}')
    [[ -n $cpu_word ]] && run_section "hardware/cpu" "$fdir" -- "$cpu_word"
  fi
  if [[ -r $fdir/dmidecode-system ]]; then
    run_section "hardware/system-row" "$fdir" -- "System"
  fi
  if [[ -r $fdir/lsblk ]]; then
    run_section "hardware/storage-row" "$fdir" -- "Storage"
  fi

  # ── Disk usage ───────────────────────────────────────────────────────────
  section=disk
  run_section "disk/header" "$fdir" -- "DISK USAGE"
  if [[ -s $fdir/df ]]; then
    # At least one bar should appear (skip if df fixture is empty/absent)
    run_section "disk/bar" "$fdir" -- "▕"
  fi

  # ── OS ───────────────────────────────────────────────────────────────────
  section=os
  run_section "os/header" "$fdir" -- "OPERATING SYSTEM"
  if [[ -r $fdir/os-release ]]; then
    pretty=$(grep '^PRETTY_NAME=' "$fdir/os-release" | cut -d= -f2 | tr -d '"')
    [[ -n $pretty ]] && run_section "os/pretty-name" "$fdir" -- "$pretty"
  fi
  if [[ -r $fdir/uname ]]; then
    kern=$(cat "$fdir/uname")
    [[ -n $kern ]] && run_section "os/kernel" "$fdir" -- "$kern"
  fi
  run_section "os/uptime-row" "$fdir" -- "Uptime"

  # ── Status ───────────────────────────────────────────────────────────────
  section=status
  run_section "status/header" "$fdir" -- "STATUS"
  if grep -q 'failed' "$fdir/systemctl-failed" 2>/dev/null && \
     [[ $(wc -l < "$fdir/systemctl-failed") -gt 0 ]]; then
    run_section "status/failed-units" "$fdir" -- "failed unit"
  fi

  # ── Packages + SMART (both need the static cache) ────────────────────────
  section=packages
  rm -f "$tmpdir/pkgs.txt" "$tmpdir/smart.txt"
  env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" "$gday" --static >/dev/null 2>&1 || true
  if [[ -r $tmpdir/pkgs.txt && $(wc -l < "$tmpdir/pkgs.txt") -gt 0 ]]; then
    run_section "packages/count" "$fdir" -- "EXPLICITLY INSTALLED" "Count"
  else
    run_section "packages/header-only" "$fdir" -- "EXPLICITLY INSTALLED"
  fi

  # SMART: if smartctl fixtures exist for this set, the cache should show healthy
  section=status
  if [[ -s $tmpdir/smart.txt ]]; then
    run_section "status/smart-healthy" "$fdir" -- "SMART healthy"
  fi

  # ── Config: GDAY_EMOJI=0 ─────────────────────────────────────────────────
  section=hardware
  run_section "emoji-off/header-plain" "$fdir" 'GDAY_EMOJI=0' -- "HARDWARE"
  # With emoji off, the emoji char should NOT appear in the header line
  out_emoji=$(env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" GDAY_EMOJI=0 \
    "$gday" --section hardware 2>/dev/null | head -1) || true
  if ! grep -qF '💻' <<< "$out_emoji" 2>/dev/null; then
    ok "emoji-off/no-emoji-in-header"
  else
    fail "emoji-off/no-emoji-in-header: emoji still present with GDAY_EMOJI=0"
  fi

  # ── Config: GDAY_SECTIONS ────────────────────────────────────────────────
  section=''
  out_sec=$(env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" \
    GDAY_SECTIONS='hardware disk' "$gday" 2>/dev/null) || true
  if grep -qF 'HARDWARE' <<< "$out_sec" && grep -qF 'DISK USAGE' <<< "$out_sec"; then
    if ! grep -qF 'OPERATING SYSTEM' <<< "$out_sec" && ! grep -qF 'STATUS' <<< "$out_sec"; then
      ok "sections-filter/only-hardware-disk"
    else
      fail "sections-filter/only-hardware-disk: unexpected sections present"
    fi
  else
    fail "sections-filter/only-hardware-disk: expected sections missing"
  fi

done

# ── Degradation: sparse fixture set (many probe outputs absent) ───────────────
# Simulates missing optional tools by providing a fixture set with only the
# bare minimum files. gday::probe returns empty for absent fixtures, which
# is exactly what happens when a real tool is absent (§5, §15).
hdr "degradation (sparse fixtures — most probes absent)"
sparse=$(mktemp -d)
# Only the bare minimum: OS identity, uptime, hostname, a df snapshot.
cp "$here/test/fixtures/os-release" "$sparse/"
cp "$here/test/fixtures/uptime"     "$sparse/"
cp "$here/test/fixtures/hostname"   "$sparse/"
cp "$here/test/fixtures/df"         "$sparse/"
# No dmidecode, no lscpu, no lspci, no lsblk, no figlet, no gnome-shell,
# no loginctl, no systemctl-failed, no apt/dnf data.

section=''
sparse_var=$(mktemp -d)
out=$(GDAY_FIXTURE_DIR="$sparse" GDAY_VAR="$sparse_var" "$gday" 2>/dev/null) || true
rm -rf "$sparse" "$sparse_var"

# Assembly must produce output with all key sections present (§5).
if grep -qF 'HARDWARE' <<< "$out" && grep -qF 'DISK USAGE' <<< "$out" && \
   grep -qF 'OPERATING SYSTEM' <<< "$out" && grep -qF "g’day" <<< "$out"; then
  ok "degraded/assembly-succeeds-with-sparse-fixtures"
else
  fail "degraded/assembly-succeeds-with-sparse-fixtures"
  printf '    output: %s\n' "$(head -3 <<< "$out")"
fi

# With no lscpu fixture, HARDWARE should still render (header at least).
if grep -qF 'HARDWARE' <<< "$out"; then
  ok "degraded/hardware-section-present-without-lscpu"
else
  fail "degraded/hardware-section-present-without-lscpu"
fi

# With no dmidecode fixtures, System/Mainboard rows should be absent.
if ! grep -qF 'System' <<< "$out" && ! grep -qF 'Mainboard' <<< "$out"; then
  ok "degraded/no-system-row-without-dmidecode"
else
  fail "degraded/no-system-row-without-dmidecode: System or Mainboard appeared without fixture"
fi

# OS section should still render uptime from the sparse uptime fixture.
if grep -qF 'Uptime' <<< "$out"; then
  ok "degraded/os-uptime-from-sparse-fixture"
else
  fail "degraded/os-uptime-from-sparse-fixture"
fi

# Disk bars should appear from the df fixture.
if grep -qF '▕' <<< "$out"; then
  ok "degraded/disk-bars-from-sparse-fixture"
else
  fail "degraded/disk-bars-from-sparse-fixture"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
