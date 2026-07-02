#!/usr/bin/env bash
# uninstall.sh — g'day uninstaller (CLAUDE.md §20).
# Restores prior state recorded during install: re-enables update-motd.d
# scripts, removes units, binary, libs, and our /etc/motd content.
# Config (/etc/gday/) and caches (/var/lib/gday/) are left unless --purge.
set -euo pipefail

PREFIX=${PREFIX:-/usr/local}
GDAY_BIN="$PREFIX/bin/gday"
GDAY_LIB_DIR="$PREFIX/lib/gday"
GDAY_ETC=/etc/gday
GDAY_VAR=/var/lib/gday
GDAY_SYSTEMD=/etc/systemd/system
GDAY_MOTD=/etc/motd
ROLLBACK="$GDAY_VAR/install-rollback.txt"
MOTD_BACKUP="$GDAY_VAR/motd.orig"

PURGE=0
for arg in "$@"; do [[ $arg == --purge ]] && PURGE=1; done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'uninstall.sh: must run as root\n' >&2; exit 1; }

say() { printf 'uninstall: %s\n' "$*"; }

# Action log, captured as the script runs (some of this — notably ROLLBACK —
# gets deleted before the script ends, so it must be recorded now, not
# reconstructed later for the final report).
RESTORED_MOTD_D=()
MOTD_OUTCOME='not present'

# ── Stop and disable timers ───────────────────────────────────────────────────
# Only the *.timer units have an [Install] section (WantedBy=timers.target) —
# the *.service units are only ever triggered by their matching timer and were
# never meant to be enabled directly (correct, standard systemd design, not a
# packaging gap). Running `is-enabled`/`disable` against them anyway makes
# systemd report them as "static" (still exit 0) and then print its "unit
# files have no installation config" warning on the pointless disable — so
# services only get stopped (in case one's mid-run), never disabled.
for unit in gday-static.timer gday-updates.timer gday-refresh.timer; do
  systemctl is-active --quiet "$unit" 2>/dev/null && systemctl stop "$unit" || true
  systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl disable "$unit" || true
done
for unit in gday-static.service gday-updates.service gday-refresh.service; do
  systemctl is-active --quiet "$unit" 2>/dev/null && systemctl stop "$unit" || true
done

# ── Remove systemd units + drop-ins ──────────────────────────────────────────
say "removing systemd units"
for unit in gday-static gday-updates gday-refresh; do
  rm -f "$GDAY_SYSTEMD/${unit}.service" "$GDAY_SYSTEMD/${unit}.timer"
  rm -rf "$GDAY_SYSTEMD/${unit}.service.d" "$GDAY_SYSTEMD/${unit}.timer.d"
done
systemctl daemon-reload

# ── Restore update-motd.d ─────────────────────────────────────────────────────
# The rollback record is removed once consumed — otherwise a later reinstall's
# idempotency check (install.sh: "skip if already recorded") would see the
# stale entry and refuse to re-neutralise scripts we just restored here,
# leaving update-motd.d silently re-enabled after an uninstall+reinstall (§3).
if [[ -r $ROLLBACK ]]; then
  say "restoring update-motd.d scripts"
  while IFS= read -r line; do
    [[ $line == motd.d:* ]] || continue
    f=${line#motd.d:}
    if [[ -f $f ]]; then
      chmod +x "$f"
      say "  restored $f"
      RESTORED_MOTD_D+=("$f")
    fi
  done < "$ROLLBACK"
  rm -f "$ROLLBACK"
fi

# ── Restore or clear /etc/motd if we own it ──────────────────────────────────
if [[ -f $GDAY_MOTD ]]; then
  if grep -q "g’day" "$GDAY_MOTD" 2>/dev/null; then
    if [[ -f $MOTD_BACKUP ]]; then
      say "restoring original $GDAY_MOTD"
      mv -f "$MOTD_BACKUP" "$GDAY_MOTD"
      MOTD_OUTCOME='restored to its pre-install content'
    else
      say "clearing $GDAY_MOTD"
      > "$GDAY_MOTD"
      MOTD_OUTCOME='cleared (no pre-install backup existed to restore)'
    fi
  else
    MOTD_OUTCOME="left untouched (didn't contain gday's content)"
  fi
fi

# ── Remove binary + libs ──────────────────────────────────────────────────────
say "removing binary and libs"
rm -f "$GDAY_BIN"
rm -rf "$GDAY_LIB_DIR"

# ── Purge config and caches ───────────────────────────────────────────────────
if (( PURGE )); then
  say "purging config ($GDAY_ETC) and caches ($GDAY_VAR)"
  rm -rf "$GDAY_ETC" "$GDAY_VAR"
else
  say "config and caches preserved (run with --purge to remove)"
fi

# ── Verification ─────────────────────────────────────────────────────────────
# Re-check the actual filesystem/systemd state rather than assuming the steps
# above worked — "no trace left" should be a checked fact, not an assertion.
say "verifying removal"
FAILURES=()

check_gone() {
  local label=$1 path=$2
  if [[ -e $path ]]; then
    FAILURES+=("$label still present: $path")
    printf '  ❌ %-16s still present: %s\n' "$label" "$path"
  else
    printf '  ✅ %-16s gone\n' "$label"
  fi
}

check_gone "binary" "$GDAY_BIN"
check_gone "libraries" "$GDAY_LIB_DIR"
for unit in gday-static gday-updates gday-refresh; do
  check_gone "${unit}.service"   "$GDAY_SYSTEMD/${unit}.service"
  check_gone "${unit}.timer"    "$GDAY_SYSTEMD/${unit}.timer"
  check_gone "${unit}.service.d" "$GDAY_SYSTEMD/${unit}.service.d"
  check_gone "${unit}.timer.d"   "$GDAY_SYSTEMD/${unit}.timer.d"
done

if systemctl list-unit-files 2>/dev/null | grep -q '^gday-'; then
  FAILURES+=("systemd still lists one or more gday-* units")
  printf '  ❌ %-16s systemd still lists gday-* unit(s)\n' "systemd"
else
  printf '  ✅ %-16s systemd no longer lists any gday-* unit\n' "systemd"
fi

for f in "${RESTORED_MOTD_D[@]:-}"; do
  [[ -n $f ]] || continue
  if [[ -x $f ]]; then
    printf '  ✅ %-16s executable again: %s\n' "update-motd.d" "$f"
  else
    FAILURES+=("update-motd.d script not restored: $f")
    printf '  ❌ %-16s NOT executable: %s\n' "update-motd.d" "$f"
  fi
done

if [[ -f $GDAY_MOTD ]] && grep -q "g’day" "$GDAY_MOTD" 2>/dev/null; then
  FAILURES+=("$GDAY_MOTD still contains gday's content")
  printf '  ❌ %-16s still contains gday content\n' "/etc/motd"
else
  printf '  ✅ %-16s %s\n' "/etc/motd" "$MOTD_OUTCOME"
fi

if (( PURGE )); then
  check_gone "config dir" "$GDAY_ETC"
  check_gone "cache dir"  "$GDAY_VAR"
else
  [[ -d $GDAY_ETC ]] && printf '  ℹ️  %-16s preserved (as requested): %s\n' "config dir" "$GDAY_ETC"
  [[ -d $GDAY_VAR ]] && printf '  ℹ️  %-16s preserved (as requested): %s\n' "cache dir"  "$GDAY_VAR"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
echo
if (( ${#FAILURES[@]} == 0 )); then
  if (( PURGE )); then
    say "done — no trace of gday remains"
  else
    say "done — gday fully removed (config and caches intentionally preserved, see below)"
  fi
else
  say "done, with ${#FAILURES[@]} problem(s) — gday is NOT fully removed:"
  for f in "${FAILURES[@]}"; do
    printf '   - %s\n' "$f"
  done
fi

if ! (( PURGE )); then
  echo
  echo "────────────────────────────────────────────────────────────────────"
  echo "NOTE: config ($GDAY_ETC) and caches ($GDAY_VAR) were left in place."
  echo "To remove those too:"
  echo "    sudo ./uninstall.sh --purge"
  echo "────────────────────────────────────────────────────────────────────"
fi

(( ${#FAILURES[@]} == 0 ))
