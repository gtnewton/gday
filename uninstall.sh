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

PURGE=0
for arg in "$@"; do [[ $arg == --purge ]] && PURGE=1; done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'uninstall.sh: must run as root\n' >&2; exit 1; }

say() { printf 'uninstall: %s\n' "$*"; }

# ── Stop and disable timers ───────────────────────────────────────────────────
for unit in gday-static.timer gday-updates.timer gday-refresh.timer \
            gday-static.service gday-updates.service gday-refresh.service; do
  systemctl is-active --quiet "$unit" 2>/dev/null && systemctl stop "$unit" || true
  systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl disable "$unit" || true
done

# ── Remove systemd units + drop-ins ──────────────────────────────────────────
say "removing systemd units"
for unit in gday-static gday-updates gday-refresh; do
  rm -f "$GDAY_SYSTEMD/${unit}.service" "$GDAY_SYSTEMD/${unit}.timer"
  rm -rf "$GDAY_SYSTEMD/${unit}.service.d" "$GDAY_SYSTEMD/${unit}.timer.d"
done
systemctl daemon-reload

# ── Restore update-motd.d ─────────────────────────────────────────────────────
if [[ -r $ROLLBACK ]]; then
  say "restoring update-motd.d scripts"
  while IFS= read -r line; do
    [[ $line == motd.d:* ]] || continue
    f=${line#motd.d:}
    [[ -f $f ]] && chmod +x "$f" && say "  restored $f"
  done < "$ROLLBACK"
fi

# ── Clear /etc/motd if we own it ─────────────────────────────────────────────
if [[ -f $GDAY_MOTD ]]; then
  if grep -q "g’day" "$GDAY_MOTD" 2>/dev/null; then
    say "clearing $GDAY_MOTD"
    > "$GDAY_MOTD"
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

say "done"
