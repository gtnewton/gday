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
  if (( ok_ )); then ok "$label"; fi
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
  if (( ok_ )); then ok "$label"; fi
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

# Hermetic: never read this machine's installed config, plugins or alerts —
# a local GDAY_SECTIONS or a real status.d plugin would otherwise change
# what every test sees. Individual tests override these explicitly.
export GDAY_CONF=/dev/null
export GDAY_PLUGIN_DIR="$tmpdir/no-plugins"
export GDAY_ALERTS_DIR="$tmpdir/no-alerts"
# The pre-brief-mode suite asserts on the full layout via bare `gday`, which
# previews GDAY_MOTD_STYLE (default brief). Brief-mode tests unset this.
export GDAY_MOTD_STYLE=full

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
    "HARDWARE" "DISK USAGE" "OPERATING SYSTEM" "STATUS" "g’day" "generated"

  # ── Banner ───────────────────────────────────────────────────────────────
  section=banner
  hostname_val=$(cat "$fdir/hostname" 2>/dev/null || true)
  if [[ -n $hostname_val ]]; then
    run_section "banner/hostname" "$fdir" -- "$hostname_val"
  fi
  if [[ -r $fdir/figlet ]]; then
    run_section "banner/figlet-art" "$fdir" GDAY_FIGLET_FONT=standard -- "$(head -1 "$fdir/figlet" | sed 's/ *$//')"
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
  if [[ -r $fdir/dmidecode-bios ]]; then
    run_section "hardware/bios-row" "$fdir" -- "BIOS"
  fi
  if [[ -r $fdir/lsblk ]]; then
    run_section "hardware/storage-row" "$fdir" -- "Storage"
  fi

  # ── Network ──────────────────────────────────────────────────────────────
  section=network
  if [[ -r $fdir/ip-route ]]; then
    run_section "network/header" "$fdir" -- "NETWORK"
    run_section "network/interface-row" "$fdir" -- "Interface"
    if [[ -r $fdir/ip-addr-eth0 ]]; then
      run_section "network/ipv4-row" "$fdir" -- "IPv4"
    fi
  else
    # No default-route fixture ⇒ the whole section must be omitted, not just
    # degraded (CLAUDE.md §11/§15: "do not guess").
    out_net=$(env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" "$gday" --section network 2>/dev/null) || true
    if [[ -z $out_net ]]; then
      ok "network/omitted-without-default-route"
    else
      fail "network/omitted-without-default-route: expected empty output, got: $out_net"
    fi
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
  if [[ -r $fdir/last ]]; then
    run_section "os/last-login-row" "$fdir" -- "Last login"
  else
    # Degraded fixture set has no `last` data — OS section must still render
    # fine without the row (§5: omit, don't error).
    out_os=$(env GDAY_FIXTURE_DIR="$fdir" GDAY_VAR="$tmpdir" "$gday" --section os 2>/dev/null) || true
    if grep -qF 'OPERATING SYSTEM' <<< "$out_os" && ! grep -qF 'Last login' <<< "$out_os"; then
      ok "os/last-login-omitted-without-fixture"
    else
      fail "os/last-login-omitted-without-fixture"
    fi
  fi

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

# ── Network degradation: speed unreadable (-1, wireless/virtual convention) ──
hdr "network (speed unreadable)"
net_sparse=$(mktemp -d)
cp "$here/test/fixtures/ip-route"              "$net_sparse/"
cp "$here/test/fixtures/ip-addr-eth0"          "$net_sparse/"
cp "$here/test/fixtures/sys-net-eth0-operstate" "$net_sparse/"
cp "$here/test/fixtures/sys-net-eth0-address"   "$net_sparse/"
printf -- '-1\n' > "$net_sparse/sys-net-eth0-speed"   # no sys-net-eth0-duplex either
net_var=$(mktemp -d)
out_net_deg=$(env GDAY_FIXTURE_DIR="$net_sparse" GDAY_VAR="$net_var" "$gday" --section network 2>/dev/null) || true
rm -rf "$net_sparse" "$net_var"
if grep -qF 'Interface' <<< "$out_net_deg" && ! grep -qF 'Speed/Duplex' <<< "$out_net_deg"; then
  ok "network/speed-omitted-on-negative-one"
else
  fail "network/speed-omitted-on-negative-one"
  printf '    output: %s\n' "$out_net_deg"
fi

# ── Banner override: GDAY_BANNER_FILE (§4.1 of the development guide) ────────
hdr "banner override (GDAY_BANNER_FILE)"
banner_var=$(mktemp -d)

# Plain override: content replaces figlet art verbatim.
banner_plain=$(mktemp)
printf 'ACME LAB\nDEPT OF COMPUTING\n' > "$banner_plain"
out_banner=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_plain" "$gday" --section banner 2>/dev/null) || true
if grep -qF 'ACME LAB' <<< "$out_banner" && grep -qF 'DEPT OF COMPUTING' <<< "$out_banner"; then
  ok "banner-override/content-used-verbatim"
else
  fail "banner-override/content-used-verbatim"
fi

# GDAY_BANNER_SUBTITLE=0 suppresses the computed subtitle.
out_banner_nosub=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_plain" GDAY_BANNER_SUBTITLE=0 "$gday" --section banner 2>/dev/null) || true
if ! grep -qF 'skylab' <<< "$out_banner_nosub"; then
  ok "banner-override/subtitle-suppressed"
else
  fail "banner-override/subtitle-suppressed"
fi
rm -f "$banner_plain"

# A line wider than 80 columns is truncated, with a warning, not left to
# break the §9 width invariant.
banner_wide=$(mktemp)
printf 'X%.0s' $(seq 1 120) > "$banner_wide"
printf '\n' >> "$banner_wide"
out_banner_wide=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_wide" "$gday" --section banner 2>/dev/null) || true
err_banner_wide=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_wide" "$gday" --section banner 2>&1 >/dev/null) || true
max_len=$(awk '{ print length }' <<< "$out_banner_wide" | sort -n | tail -1)
if [[ ${max_len:-0} -le 80 ]] && grep -qF 'truncated' <<< "$err_banner_wide"; then
  ok "banner-override/wide-line-truncated"
else
  fail "banner-override/wide-line-truncated: max_len=${max_len:-?} stderr=${err_banner_wide}"
fi
rm -f "$banner_wide"

# Tabs are expanded before sanitizing, not deleted (render::sanitize strips
# 0x09 — an un-expanded tab would silently drop everything after it).
banner_tabs=$(mktemp)
printf 'A\tMARKER\n' > "$banner_tabs"
out_banner_tabs=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_tabs" "$gday" --section banner 2>/dev/null) || true
if grep -qF 'MARKER' <<< "$out_banner_tabs"; then
  ok "banner-override/tabs-expanded-not-dropped"
else
  fail "banner-override/tabs-expanded-not-dropped"
fi
rm -f "$banner_tabs"

# More than 20 lines is capped, with a warning.
banner_long=$(mktemp)
for i in $(seq 1 30); do printf 'line%d\n' "$i"; done > "$banner_long"
out_banner_long=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_long" "$gday" --section banner 2>/dev/null) || true
err_banner_long=$(env GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$banner_var" \
  GDAY_BANNER_FILE="$banner_long" "$gday" --section banner 2>&1 >/dev/null) || true
line_count=$(grep -c '^line' <<< "$out_banner_long")
if [[ $line_count -eq 20 ]] && grep -qF 'capped' <<< "$err_banner_long"; then
  ok "banner-override/line-count-capped"
else
  fail "banner-override/line-count-capped: got $line_count lines, stderr=${err_banner_long}"
fi
rm -f "$banner_long"
rm -rf "$banner_var"

# ── Alerts (Phase 1.5, planning/alerts-section.md §4.6) ──────────────────────
hdr "alerts"

alerts_empty_fixtures=$(mktemp -d)   # empty GDAY_FIXTURE_DIR: sandboxes the
                                      # rest of STATUS (updates/reboot/
                                      # services/disks) so only alerts output
                                      # is under test.

# alerts_run <alerts_dir> [extra_env...] — run `gday --section status`
# against <alerts_dir>, capturing stdout and stderr separately.
alerts_run_out=''
alerts_run_err=''
alerts_run() {
  local adir=$1; shift
  local avar errfile
  avar=$(mktemp -d)
  errfile=$(mktemp)
  alerts_run_out=$(env GDAY_FIXTURE_DIR="$alerts_empty_fixtures" GDAY_VAR="$avar" \
    GDAY_ALERTS_DIR="$adir" "$@" "$gday" --section status 2>"$errfile") || true
  alerts_run_err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  rm -rf "$avar"
}

# 1. One producer file: one FAIL, one WARN, one docref-less row.
a1=$(mktemp -d); chmod 755 "$a1"
now_iso=$(date -Iseconds)
{
  printf '# gday-alerts v1\n@ source=demo-check\n@ generated=%s\n@ expires=26h\n' "$now_iso"
  printf 'FAIL\tunattended-upgrades\tu-u has never run on this box\tRUNBOOK.md#unattended-upgrades\n'
  printf 'WARN\tnetbootbuild\tjob not scheduled on this box\tRUNBOOK.md#netbootbuild\n'
  printf 'WARN\tnodocref\tno doc for this one\n'
} > "$a1/demo-check.alerts"
chmod 644 "$a1/demo-check.alerts"
alerts_run "$a1"
if grep -qF 'unattended-upgrades: u-u has never run on this box' <<< "$alerts_run_out" \
   && grep -qF 'RUNBOOK.md#unattended-upgrades' <<< "$alerts_run_out" \
   && grep -qF 'netbootbuild: job not scheduled on this box' <<< "$alerts_run_out" \
   && grep -qF 'nodocref: no doc for this one' <<< "$alerts_run_out"; then
  ok "alerts/basic-fail-warn-nodocref"
else
  fail "alerts/basic-fail-warn-nodocref"
  printf '    output: %s\n' "$alerts_run_out"
fi
# FAIL rows must render before WARN rows regardless of file order.
fail_line=$(grep -n 'unattended-upgrades' <<< "$alerts_run_out" | head -1 | cut -d: -f1)
warn_line=$(grep -n 'netbootbuild' <<< "$alerts_run_out" | head -1 | cut -d: -f1)
if [[ -n $fail_line && -n $warn_line && $fail_line -lt $warn_line ]]; then
  ok "alerts/fail-before-warn-ordering"
else
  fail "alerts/fail-before-warn-ordering"
fi
rm -rf "$a1"

# 2. Malformed row (too few fields; unknown severity) dropped, others render.
a2=$(mktemp -d); chmod 755 "$a2"
{
  printf '# gday-alerts v1\n@ source=demo2\n@ generated=%s\n' "$now_iso"
  printf 'FAIL\ttoofewfields\n'
  printf 'BADSEV\tlabel\tmessage\n'
  printf 'WARN\tgoodone\tthis one is fine\n'
} > "$a2/demo2.alerts"
chmod 644 "$a2/demo2.alerts"
alerts_run "$a2"
if grep -qF 'goodone: this one is fine' <<< "$alerts_run_out" \
   && ! grep -qF 'toofewfields' <<< "$alerts_run_out" \
   && ! grep -qF 'BADSEV' <<< "$alerts_run_out"; then
  ok "alerts/malformed-row-dropped-others-render"
else
  fail "alerts/malformed-row-dropped-others-render"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a2"

# 3. Expired file ⇒ staleness line, records suppressed.
a3=$(mktemp -d); chmod 755 "$a3"
{
  printf '# gday-alerts v1\n@ source=demo3\n@ generated=2020-01-01T00:00:00-07:00\n'
  printf 'FAIL\tshouldnotshow\tstale record\n'
} > "$a3/demo3.alerts"
chmod 644 "$a3/demo3.alerts"
alerts_run "$a3"
if grep -qF 'demo3: no report since' <<< "$alerts_run_out" \
   && ! grep -qF 'shouldnotshow' <<< "$alerts_run_out"; then
  ok "alerts/expired-file-staleness-line-records-suppressed"
else
  fail "alerts/expired-file-staleness-line-records-suppressed"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a3"

# 4. Declared-but-missing producer ⇒ warning line.
a4=$(mktemp -d); chmod 755 "$a4"   # empty: no .alerts file at all
alerts_run "$a4" GDAY_ALERTS_EXPECT=nightly-check
if grep -qF 'nightly-check: no report file' <<< "$alerts_run_out"; then
  ok "alerts/declared-missing-producer-warns"
else
  fail "alerts/declared-missing-producer-warns"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a4"

# 5. Group-writable file, producer NOT declared ⇒ skipped silently.
a5=$(mktemp -d); chmod 755 "$a5"
printf '# gday-alerts v1\n@ source=undeclared-check\n@ generated=%s\nFAIL\tx\ty\n' "$now_iso" \
  > "$a5/undeclared-check.alerts"
chmod 664 "$a5/undeclared-check.alerts"
alerts_run "$a5"
if ! grep -qF 'undeclared-check' <<< "$alerts_run_out"; then
  ok "alerts/group-writable-undeclared-silent"
else
  fail "alerts/group-writable-undeclared-silent"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a5"

# 6. Group-writable file, producer DECLARED ⇒ "report file unusable" line,
# records suppressed, reason on stderr — never in the banner (§4.3's split;
# a test that only covers case 5 would let the regression back in).
a6=$(mktemp -d); chmod 755 "$a6"
printf '# gday-alerts v1\n@ source=nightly-check\n@ generated=%s\nFAIL\tx\ty\n' "$now_iso" \
  > "$a6/nightly-check.alerts"
chmod 664 "$a6/nightly-check.alerts"
alerts_run "$a6" GDAY_ALERTS_EXPECT=nightly-check
if grep -qF 'nightly-check: report file unusable' <<< "$alerts_run_out" \
   && ! grep -qF 'FAIL' <<< "$alerts_run_out" \
   && ! grep -q 'mode\|owner\|permission' <<< "$alerts_run_out" \
   && grep -qi 'rejected' <<< "$alerts_run_err"; then
  ok "alerts/group-writable-declared-unusable-line-reason-on-stderr"
else
  fail "alerts/group-writable-declared-unusable-line-reason-on-stderr"
  printf '    stdout: %s\n    stderr: %s\n' "$alerts_run_out" "$alerts_run_err"
fi
rm -rf "$a6"

# 7. ANSI escape in a message ⇒ stripped by render::sanitize.
a7=$(mktemp -d); chmod 755 "$a7"
esc=$'\x1b'
printf '# gday-alerts v1\n@ source=demo7\n@ generated=%s\nFAIL\tcolour\thas %s[31mred%s[0mtext\n' \
  "$now_iso" "$esc" "$esc" > "$a7/demo7.alerts"
chmod 644 "$a7/demo7.alerts"
alerts_run "$a7"
if ! grep -qP '\x1b' <<< "$alerts_run_out" 2>/dev/null; then
  ok "alerts/ansi-escape-stripped"
else
  fail "alerts/ansi-escape-stripped"
fi
rm -rf "$a7"

# 8. Row cap exceeded ⇒ truncation line.
a8=$(mktemp -d); chmod 755 "$a8"
{
  printf '# gday-alerts v1\n@ source=demo8\n@ generated=%s\n' "$now_iso"
  for i in $(seq 1 10); do printf 'FAIL\tcheck%d\tmessage %d\n' "$i" "$i"; done
} > "$a8/demo8.alerts"
chmod 644 "$a8/demo8.alerts"
alerts_run "$a8"
if grep -qF 'and 2 more' <<< "$alerts_run_out" && grep -qF 'check8' <<< "$alerts_run_out" \
   && ! grep -qF 'check9' <<< "$alerts_run_out"; then
  ok "alerts/row-cap-truncation-line"
else
  fail "alerts/row-cap-truncation-line"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a8"

# 9. Empty and absent alerts.d ⇒ section renders, no alert output, exit 0.
# Checked via the FAIL/WARN glyphs (❌/⚠️), not the words "FAIL"/"WARN" —
# "No failed units" (from status::services, sharing this sandboxed run)
# contains the substring "fail" and would otherwise false-positive.
a9_empty=$(mktemp -d); chmod 755 "$a9_empty"
alerts_run "$a9_empty"
if ! grep -qi 'no report\|unusable' <<< "$alerts_run_out" \
   && ! grep -qF '❌' <<< "$alerts_run_out" \
   && ! grep -qF '⚠️' <<< "$alerts_run_out"; then
  ok "alerts/empty-dir-silent"
else
  fail "alerts/empty-dir-silent"
  printf '    output: %s\n' "$alerts_run_out"
fi
rm -rf "$a9_empty"

alerts_run "/nonexistent/gday-alerts-test-dir"
gday_exit=0
env GDAY_FIXTURE_DIR="$alerts_empty_fixtures" GDAY_VAR="$(mktemp -d)" \
  GDAY_ALERTS_DIR=/nonexistent/gday-alerts-test-dir "$gday" --section status >/dev/null 2>&1 \
  || gday_exit=$?
if [[ $gday_exit -eq 0 ]]; then
  ok "alerts/absent-dir-exit-zero"
else
  fail "alerts/absent-dir-exit-zero: exit=$gday_exit"
fi

rm -rf "$alerts_empty_fixtures"

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

# ── Banner: built-in ANSI Shadow + '=' frame ─────────────────────────────────
hdr "banner (ANSI Shadow frame)"
bv=$(mktemp -d)
out=$(GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$bv" "$gday" --section banner 2>/dev/null) || true
rule80=$(printf '=%.0s' $(seq 1 80))
first=$(head -1 <<< "$out"); last=$(tail -1 <<< "$out")
if [[ $first == "$rule80" ]] && grep -qF '███████╗' <<< "$out"; then
  ok "banner/top-rule-and-ansi-shadow-art"
else
  fail "banner/top-rule-and-ansi-shadow-art"
fi
if [[ $last =~ ^=+\ skylab\ ·\ .+\ =+$ ]] && (( $(LC_ALL=C.UTF-8 awk '{print length}' <<< "$last") == 80 )) \
   && ! grep -qiE 'wayland|x11' <<< "$last"; then
  ok "banner/titled-rule-80-no-session"
else
  fail "banner/titled-rule-80-no-session: «$last»"
fi
out=$(GDAY_FIXTURE_DIR="$here/test/fixtures" GDAY_VAR="$bv" GDAY_BANNER_SUBTITLE=0 "$gday" --section banner 2>/dev/null) || true
if [[ $(tail -1 <<< "$out") == "$rule80" ]]; then
  ok "banner/subtitle-off-plain-rule"
else
  fail "banner/subtitle-off-plain-rule"
fi
# A name too wide for ANSI Shadow falls back; nothing exceeds 80 columns.
lh=$(mktemp -d); cp "$here/test/fixtures/os-release" "$lh/"
printf 'averyveryverylonghostname\n' > "$lh/hostname"
out=$(GDAY_FIXTURE_DIR="$lh" GDAY_VAR="$bv" "$gday" --section banner 2>/dev/null) || true
if ! grep -qF '██' <<< "$out" && [[ $(LC_ALL=C.UTF-8 awk 'length > 80' <<< "$out" | wc -l) -eq 0 ]] \
   && grep -qF 'averyveryverylonghostname' <<< "$out"; then
  ok "banner/too-wide-falls-back"
else
  fail "banner/too-wide-falls-back"
fi
rm -rf "$lh"
# The built-in renderer must match real figlet for the same font (skip if absent).
if command -v figlet >/dev/null 2>&1; then
  mism=0
  for t in ACME LABPC LAB-PC-07 0123456789 ABCDEFGHIJ KLMNOPQRS TUVWXYZ; do
    mine=$(bash -c 'source "$1/lib/render.sh"; source "$1/lib/banner.sh"; banner::_figrender "$1/lib/fonts/ansi-shadow.flf" "$2"' _ "$here" "$t")
    ref=$(figlet -w 400 -f "$here/lib/fonts/ansi-shadow.flf" "$t" | sed 's/ *$//' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
    [[ $mine == "$ref" ]] || mism=$(( mism + 1 ))
  done
  if (( mism == 0 )); then ok "banner/renderer-matches-figlet"; else fail "banner/renderer-matches-figlet ($mism)"; fi
fi
rm -rf "$bv"

# ── Brief mode (planning/brief-mode-and-package-versions.md §1) ──────────────
hdr "brief mode"
unset GDAY_MOTD_STYLE
fx="$here/test/fixtures"
bvar=$(mktemp -d)
printf 'updates=3\nreboot=0\n' > "$bvar/updates.txt"

out=$(GDAY_FIXTURE_DIR="$fx" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qF 'gday --full for details' <<< "$out" && ! grep -qF 'HARDWARE' <<< "$out" \
   && ! grep -qF 'STATUS' <<< "$out"; then
  ok "brief/no-section-headers-footer-hint"
else
  fail "brief/no-section-headers-footer-hint"
fi
if grep -qF '3 updates available' <<< "$out" && grep -qF '1 failed unit' <<< "$out" \
   && grep -qF '→ systemctl status fwupd-refresh.service' <<< "$out"; then
  ok "brief/attention-lines-and-pointer-kept"
else
  fail "brief/attention-lines-and-pointer-kept"
fi
# Continuation detail (the unit name line) is dropped; ✅ lines are dropped.
if ! grep -qE '^ +fwupd-refresh\.service$' <<< "$out" && ! grep -qF '✅' <<< "$out"; then
  ok "brief/detail-and-ok-lines-dropped"
else
  fail "brief/detail-and-ok-lines-dropped"
fi
if grep -qE '^ +IPv4 +[0-9.]+ \(eth0\)$' <<< "$out" && grep -qE '^ +MAC +' <<< "$out" \
   && grep -qE '^ +Uptime +[0-9]+d [0-9]{2}:[0-9]{2}$' <<< "$out"; then
  ok "brief/identity-rows"
else
  fail "brief/identity-rows"
fi
# Logged in: distinct user-class accounts, sorted; greeter (gdm) excluded,
# greg's two sessions collapse to one name.
if grep -qE '^ +Logged in +alice, greg$' <<< "$out"; then
  ok "brief/logged-in-users"
else
  fail "brief/logged-in-users"
fi

# Disk threshold: fixture max is 54% (/data).
out=$(GDAY_FIXTURE_DIR="$fx" GDAY_VAR="$bvar" GDAY_BRIEF_DISK_PCT=50 "$gday" --brief 2>/dev/null) || true
if grep -qF '/data 54% full' <<< "$out" && ! grep -qF '/boot/efi' <<< "$out"; then
  ok "brief/disk-over-threshold-only"
else
  fail "brief/disk-over-threshold-only"
fi

# All clear: no updates, no failed units (no systemctl-failed fixture), no hot disks.
sparse_b=$(mktemp -d)
cp "$fx"/{os-release,uptime,hostname,df} "$sparse_b/"
printf 'updates=0\nreboot=0\n' > "$bvar/updates.txt"
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qF 'All clear' <<< "$out"; then
  ok "brief/all-clear"
else
  fail "brief/all-clear"
fi

# Plugin rule: only ⚠️/❌-led plugin lines reach brief; plain rows are full-only.
pdir="$bvar/status.d"; mkdir -p "$pdir"; chmod 0755 "$pdir"
cat > "$pdir/10-mixed" <<'PLUG'
#!/usr/bin/env bash
printf '       %-12s %s\n' 'Info row' 'informational only'
printf '       ⚠️  plugin needs attention\n'
PLUG
chmod 0755 "$pdir/10-mixed"
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" GDAY_PLUGIN_DIR="$pdir" "$gday" --brief 2>/dev/null) || true
full=$(GDAY_MOTD_STYLE=full GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" GDAY_PLUGIN_DIR="$pdir" "$gday" 2>/dev/null) || true
if grep -qF 'plugin needs attention' <<< "$out" && ! grep -qF 'informational only' <<< "$out" \
   && grep -qF 'informational only' <<< "$full" && ! grep -qF 'All clear' <<< "$out"; then
  ok "brief/plugin-glyph-rule"
else
  fail "brief/plugin-glyph-rule"
fi

# --write-motd: brief to the motd path, full to report.txt; --full reads it.
motd="$bvar/motd"
GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" GDAY_MOTD="$motd" "$gday" --write-motd 2>/dev/null || true
if grep -qF 'gday --full for details' "$motd" 2>/dev/null && ! grep -qF 'DISK USAGE' "$motd" \
   && grep -qF 'DISK USAGE' "$bvar/report.txt" 2>/dev/null; then
  ok "write-motd/brief-motd-full-report"
else
  fail "write-motd/brief-motd-full-report"
fi
perm=$(stat -c %a "$bvar/report.txt" 2>/dev/null || true)
if [[ $perm == 644 ]]; then ok "write-motd/report-0644"; else fail "write-motd/report-0644 (got ${perm:-none})"; fi
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" --full 2>/dev/null) || true
if [[ $out == "$(cat "$bvar/report.txt")" ]]; then
  ok "full/prints-saved-report"
else
  fail "full/prints-saved-report"
fi
rm -f "$bvar/report.txt"
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" --full 2>/dev/null) || true
if grep -qF 'DISK USAGE' <<< "$out"; then ok "full/live-fallback-without-report"
else fail "full/live-fallback-without-report"; fi

# GDAY_MOTD_STYLE=full (via config) puts the full report in the motd.
printf 'GDAY_MOTD_STYLE=full\n' > "$bvar/conf"
GDAY_CONF="$bvar/conf" GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" GDAY_MOTD="$motd" \
  "$gday" --write-motd 2>/dev/null || true
if grep -qF 'DISK USAGE' "$motd"; then ok "write-motd/style-full"; else fail "write-motd/style-full"; fi

# Invalid style warns and falls back to brief (§13: never abort).
printf 'GDAY_MOTD_STYLE=verbose\n' > "$bvar/conf"
err=$(GDAY_CONF="$bvar/conf" GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" GDAY_MOTD="$motd" \
  "$gday" --write-motd 2>&1 >/dev/null) || true
if grep -qF 'invalid GDAY_MOTD_STYLE' <<< "$err" && grep -qF 'gday --full for details' "$motd"; then
  ok "config/invalid-style-falls-back-to-brief"
else
  fail "config/invalid-style-falls-back-to-brief"
fi
# Failed-unit hints: full lists every unit + all pointers; brief keeps one.
fdir2=$(mktemp -d); cp "$sparse_b"/* "$fdir2/"
printf '● fwupd-refresh.service loaded failed failed Refresh fwupd metadata\n' > "$fdir2/systemctl-failed"
full=$(GDAY_MOTD_STYLE=full GDAY_FIXTURE_DIR="$fdir2" GDAY_VAR="$bvar" "$gday" 2>/dev/null) || true
out=$(GDAY_FIXTURE_DIR="$fdir2" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qF '→ systemctl status fwupd-refresh.service' <<< "$full" \
   && grep -qF '→ journalctl -b -u fwupd-refresh.service' <<< "$full" \
   && ! grep -qF 'systemctl --failed' <<< "$full" \
   && [[ $(grep -c '→' <<< "$out") -eq 1 ]] && grep -qF '→ systemctl status fwupd-refresh.service' <<< "$out"; then
  ok "failed-units/one-unit-hints"
else
  fail "failed-units/one-unit-hints"
fi
printf '%s\n' '● casper-md5check.service loaded failed failed casper-md5check Verify Live ISO checksums' \
  '● geoipupdate.service loaded failed failed Weekly GeoIP update' \
  '● systemd-networkd-wait-online.service loaded failed failed Wait for Network to be Configured' \
  > "$fdir2/systemctl-failed"
full=$(GDAY_MOTD_STYLE=full GDAY_FIXTURE_DIR="$fdir2" GDAY_VAR="$bvar" "$gday" 2>/dev/null) || true
out=$(GDAY_FIXTURE_DIR="$fdir2" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qF '3 failed units' <<< "$full" && grep -qF 'casper-md5check.service' <<< "$full" \
   && grep -qF 'systemd-networkd-wait-online.service' <<< "$full" \
   && grep -qF '→ systemctl --failed' <<< "$full" \
   && grep -qF '→ systemctl status <unit>' <<< "$full" \
   && grep -qF '→ journalctl -b -u <unit>' <<< "$full"; then
  ok "failed-units/full-lists-all-and-hints"
else
  fail "failed-units/full-lists-all-and-hints"
fi
if [[ $(grep -c '→' <<< "$out") -eq 1 ]] && grep -qF '→ systemctl --failed' <<< "$out" \
   && ! grep -qF 'casper-md5check' <<< "$out"; then
  ok "failed-units/brief-one-pointer"
else
  fail "failed-units/brief-one-pointer"
fi
wide=$( { printf '%s\n' "$full"; printf '%s\n' "$out"; } | awk 'length($0) > 80' | wc -l)
if (( wide == 0 )); then ok "failed-units/width-80"; else fail "failed-units/width-80 ($wide wide lines)"; fi

# Alerts keep their docref pointer in brief (one → per record, unchanged).
adir="$bvar/alerts.d"; mkdir -p "$adir"; chmod 0755 "$adir"
printf '# gday-alerts v1\nFAIL\tnightly-job\tdid not run\tRUNBOOK.md#nightly\nWARN\tother-job\tslow\tRUNBOOK.md#other\n' \
  > "$adir/demo.alerts"; chmod 0644 "$adir/demo.alerts"
out=$(GDAY_ALERTS_DIR="$adir" GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qF '→ RUNBOOK.md#nightly' <<< "$out" && grep -qF '→ RUNBOOK.md#other' <<< "$out"; then
  ok "brief/alerts-keep-docref-per-record"
else
  fail "brief/alerts-keep-docref-per-record"
fi
rm -rf "$fdir2" "$adir"

# Logged in: logind reachable but no sessions ⇒ "none"; unreachable ⇒ row omitted.
lfx=$(mktemp -d); cp "$sparse_b"/* "$lfx/"; : > "$lfx/loginctl-sessions"
out=$(GDAY_FIXTURE_DIR="$lfx" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if grep -qE '^ +Logged in +none$' <<< "$out"; then ok "logged-in/none"; else fail "logged-in/none"; fi
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" --brief 2>/dev/null) || true
if ! grep -qF 'Logged in' <<< "$out"; then ok "logged-in/omitted-without-logind"; else fail "logged-in/omitted-without-logind"; fi
rm -rf "$lfx"

# Bare `gday` previews the configured style: brief by default.
out=$(GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" 2>/dev/null) || true
if grep -qF 'gday --full for details' <<< "$out" && ! grep -qF 'DISK USAGE' <<< "$out"; then
  ok "bare/previews-brief-by-default"
else
  fail "bare/previews-brief-by-default"
fi
out=$(GDAY_MOTD_STYLE=full GDAY_FIXTURE_DIR="$sparse_b" GDAY_VAR="$bvar" "$gday" 2>/dev/null) || true
if grep -qF 'DISK USAGE' <<< "$out"; then
  ok "bare/previews-full-when-style-full"
else
  fail "bare/previews-full-when-style-full"
fi
rm -rf "$bvar" "$sparse_b"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
