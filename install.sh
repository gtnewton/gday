#!/usr/bin/env bash
# install.sh — g'day installer (CLAUDE.md §20).
# Idempotent: re-running converges, does not duplicate. Must run as root.
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
PREFIX=${PREFIX:-/usr/local}
GDAY_BIN="$PREFIX/bin/gday"
GDAY_LIB_DIR="$PREFIX/lib/gday"
GDAY_ETC=/etc/gday
GDAY_VAR=/var/lib/gday
GDAY_SYSTEMD=/etc/systemd/system
GDAY_MOTD=/etc/motd
GDAY_CONF="$GDAY_ETC/gday.conf"
ROLLBACK="$GDAY_VAR/install-rollback.txt"

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ── Guards ───────────────────────────────────────────────────────────────────
[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'install.sh: must run as root\n' >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────
say() { printf 'install: %s\n' "$*"; }

# install_file <src> <dst> <mode> — install a file, creating parent dirs.
install_file() {
  local src=$1 dst=$2 mode=${3:-0644}
  install -D -m "$mode" -o root -g root -- "$src" "$dst"
}

# ── Load config for cadence overrides ────────────────────────────────────────
# Defaults matching the shipped timer files; gday.conf may override them.
GDAY_STATIC_ONCALENDAR=${GDAY_STATIC_ONCALENDAR:-daily}
GDAY_STATIC_ONBOOTSEC=${GDAY_STATIC_ONBOOTSEC:-30s}
GDAY_UPDATES_ONCALENDAR=${GDAY_UPDATES_ONCALENDAR:-hourly}
GDAY_REFRESH_INTERVAL=${GDAY_REFRESH_INTERVAL:-5min}

if [[ -r $GDAY_CONF ]]; then
  # shellcheck source=/dev/null
  source "$GDAY_CONF" 2>/dev/null || true
elif [[ -r $SCRIPT_DIR/etc/gday.conf ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/etc/gday.conf" 2>/dev/null || true
fi

# ── Binary + libs ────────────────────────────────────────────────────────────
say "installing binary → $GDAY_BIN"
install_file "$SCRIPT_DIR/gday" "$GDAY_BIN" 0755

say "installing libs → $GDAY_LIB_DIR"
mkdir -p "$GDAY_LIB_DIR"
for lib in "$SCRIPT_DIR/lib/"*.sh; do
  install_file "$lib" "$GDAY_LIB_DIR/$(basename "$lib")" 0644
done

# ── Config ───────────────────────────────────────────────────────────────────
mkdir -p "$GDAY_ETC"
if [[ ! -f $GDAY_CONF ]]; then
  say "installing default config → $GDAY_CONF"
  install_file "$SCRIPT_DIR/etc/gday.conf" "$GDAY_CONF" 0644
else
  say "existing config preserved at $GDAY_CONF"
fi

# ── Plugin examples ──────────────────────────────────────────────────────────
mkdir -p "$GDAY_ETC/status.d"
for ex in "$SCRIPT_DIR/etc/status.d/"*.sh.example; do
  [[ -f $ex ]] || continue
  dst="$GDAY_ETC/status.d/$(basename "$ex")"
  if [[ ! -f $dst ]]; then
    install_file "$ex" "$dst" 0644   # examples not executable — user opts in
  fi
done

# ── Cache directory ───────────────────────────────────────────────────────────
say "creating cache dir → $GDAY_VAR"
mkdir -p "$GDAY_VAR"
chown root:root "$GDAY_VAR"
chmod 0755 "$GDAY_VAR"

# ── Debian/Ubuntu: neutralise update-motd.d ──────────────────────────────────
# pam_motd on Debian/Ubuntu prefers /run/motd.dynamic built from
# /etc/update-motd.d/ scripts, which would override or duplicate our /etc/motd.
# We drop the execute bit on each active script and record the change so
# uninstall.sh can restore it. MUST NOT delete the scripts (§3).
if [[ -d /etc/update-motd.d ]]; then
  touch "$ROLLBACK"
  for f in /etc/update-motd.d/*; do
    [[ -f $f && -x $f ]] || continue
    # Skip if already recorded (idempotency).
    grep -qF "motd.d:$f" "$ROLLBACK" 2>/dev/null && continue
    say "neutralising $f (removing execute bit)"
    chmod -x "$f"
    printf 'motd.d:%s\n' "$f" >> "$ROLLBACK"
  done
fi

# ── systemd units ────────────────────────────────────────────────────────────
say "installing systemd units → $GDAY_SYSTEMD"
for unit in "$SCRIPT_DIR/systemd/"*; do
  [[ -f $unit ]] || continue
  install_file "$unit" "$GDAY_SYSTEMD/$(basename "$unit")" 0644
done

# Apply non-default cadences via systemd drop-in files.
# Drop-ins first reset the key to empty (clearing systemd's list) then set the
# new value — the standard pattern for overriding OnCalendar/OnUnitActiveSec.
_cadence_dropin() {
  local dropin=$1; shift   # remaining args: "KEY=value" lines to emit
  mkdir -p "$(dirname "$dropin")"
  { printf '[Timer]\n'; printf '%s\n' "$@"; } > "$dropin"
  chmod 0644 "$dropin"
}

if [[ $GDAY_STATIC_ONCALENDAR != daily || $GDAY_STATIC_ONBOOTSEC != 30s ]]; then
  say "applying static cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-static.timer.d/cadence.conf" \
    "OnBootSec=" "OnCalendar=" \
    "OnBootSec=$GDAY_STATIC_ONBOOTSEC" "OnCalendar=$GDAY_STATIC_ONCALENDAR"
fi

if [[ $GDAY_UPDATES_ONCALENDAR != hourly ]]; then
  say "applying updates cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-updates.timer.d/cadence.conf" \
    "OnCalendar=" "OnCalendar=$GDAY_UPDATES_ONCALENDAR"
fi

if [[ $GDAY_REFRESH_INTERVAL != 5min ]]; then
  say "applying refresh cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-refresh.timer.d/cadence.conf" \
    "OnUnitActiveSec=" "OnUnitActiveSec=$GDAY_REFRESH_INTERVAL"
fi

# ── Activate ─────────────────────────────────────────────────────────────────
say "reloading systemd"
systemctl daemon-reload

say "enabling and starting timers"
systemctl enable --now gday-static.timer gday-updates.timer gday-refresh.timer

# ── Initial population ───────────────────────────────────────────────────────
say "running static tier to populate caches"
"$GDAY_BIN" --static || true          # tolerate partial populate (§5)

say "running updates tier"
"$GDAY_BIN" --updates || true

say "writing initial /etc/motd"
"$GDAY_BIN" --write-motd || true

say "done. Preview with: gday"
