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
MOTD_BACKUP="$GDAY_VAR/motd.orig"

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
# Explicit ownership/mode rather than relying on umask (§17) — status.d below
# holds executables that run as root every 5 minutes, so a permissive umask
# (e.g. 0 or 002) must not leave it group/other-writable.
mkdir -p "$GDAY_ETC"
chown root:root "$GDAY_ETC"
chmod 0755 "$GDAY_ETC"
if [[ ! -f $GDAY_CONF ]]; then
  say "installing default config → $GDAY_CONF"
  install_file "$SCRIPT_DIR/etc/gday.conf" "$GDAY_CONF" 0644
  CONFIG_STATUS='newly installed'
else
  say "existing config preserved at $GDAY_CONF"
  CONFIG_STATUS='existing, preserved'
fi

# ── Plugin examples ──────────────────────────────────────────────────────────
mkdir -p "$GDAY_ETC/status.d"
chown root:root "$GDAY_ETC/status.d"
chmod 0755 "$GDAY_ETC/status.d"
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

# ── Debian/Ubuntu: disable motd-news.timer ───────────────────────────────────
# motd-news.timer periodically re-fires motd-news.service to fetch Canonical's
# promotional MOTD news snippet over the network — part of the same redundant
# Ubuntu MOTD machinery the update-motd.d neutralisation above already
# targets, but independent of that script's execute bit: left alone, it keeps
# firing on its own schedule and (commonly, e.g. no/restricted outbound
# internet) failing, showing up as permanent noise in gday's own STATUS
# section rather than a duplicated banner. Only touched if the unit actually
# exists and is currently enabled/active; recorded so uninstall.sh restores
# it, same discipline as the update-motd.d scripts above.
if systemctl list-unit-files motd-news.timer --no-legend 2>/dev/null | grep -q .; then
  touch "$ROLLBACK"
  motd_news_active=0
  systemctl is-enabled --quiet motd-news.timer 2>/dev/null && motd_news_active=1
  systemctl is-active --quiet motd-news.timer 2>/dev/null && motd_news_active=1
  if (( motd_news_active )) && ! grep -qF 'unit:motd-news.timer' "$ROLLBACK" 2>/dev/null; then
    say "disabling motd-news.timer (Ubuntu's motd-news fetcher; redundant with gday, commonly fails without outbound internet)"
    systemctl disable --now motd-news.timer 2>/dev/null || true
    printf 'unit:motd-news.timer\n' >> "$ROLLBACK"
  fi
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
  local dir; dir=$(dirname "$dropin")
  mkdir -p "$dir"
  chown root:root "$dir"   # explicit, not umask-dependent (§17) — same
  chmod 0755 "$dir"        # discipline as $GDAY_ETC/status.d
  { printf '[Timer]\n'; printf '%s\n' "$@"; } > "$dropin"
  chmod 0644 "$dropin"
}

# _cadence_clear <dropin> — remove a stale override left by a previous install
# whose gday.conf has since reverted to the default; without this, re-running
# install.sh with a since-removed override left the old cadence in effect
# forever (idempotency requires converging to the *current* config, §20).
_cadence_clear() {
  [[ -e $1 ]] && { say "clearing stale cadence override → $1"; rm -f "$1"; }
}

if [[ $GDAY_STATIC_ONCALENDAR != daily || $GDAY_STATIC_ONBOOTSEC != 30s ]]; then
  say "applying static cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-static.timer.d/cadence.conf" \
    "OnBootSec=" "OnCalendar=" \
    "OnBootSec=$GDAY_STATIC_ONBOOTSEC" "OnCalendar=$GDAY_STATIC_ONCALENDAR"
else
  _cadence_clear "$GDAY_SYSTEMD/gday-static.timer.d/cadence.conf"
fi

if [[ $GDAY_UPDATES_ONCALENDAR != hourly ]]; then
  say "applying updates cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-updates.timer.d/cadence.conf" \
    "OnCalendar=" "OnCalendar=$GDAY_UPDATES_ONCALENDAR"
else
  _cadence_clear "$GDAY_SYSTEMD/gday-updates.timer.d/cadence.conf"
fi

if [[ $GDAY_REFRESH_INTERVAL != 5min ]]; then
  say "applying refresh cadence override"
  _cadence_dropin "$GDAY_SYSTEMD/gday-refresh.timer.d/cadence.conf" \
    "OnUnitActiveSec=" "OnUnitActiveSec=$GDAY_REFRESH_INTERVAL"
else
  _cadence_clear "$GDAY_SYSTEMD/gday-refresh.timer.d/cadence.conf"
fi

# ── Activate ─────────────────────────────────────────────────────────────────
say "reloading systemd"
systemctl daemon-reload

say "enabling and starting timers"
systemctl enable --now gday-static.timer gday-updates.timer gday-refresh.timer

# ── Preserve any pre-existing /etc/motd ──────────────────────────────────────
# Some distros ship a stock /etc/motd (e.g. a security/legal banner). We're
# about to overwrite it and never touch it again on reinstall (the check
# below only fires while it's not already ours), so back it up once now —
# otherwise uninstall.sh has nothing to restore and can only blank the file.
if [[ -f $GDAY_MOTD && ! -f $MOTD_BACKUP ]] && ! grep -q "g’day" "$GDAY_MOTD" 2>/dev/null; then
  say "backing up pre-existing $GDAY_MOTD → $MOTD_BACKUP"
  cp -p -- "$GDAY_MOTD" "$MOTD_BACKUP"
  chmod 0644 "$MOTD_BACKUP"
fi

# ── Initial population ───────────────────────────────────────────────────────
say "running static tier to populate caches"
"$GDAY_BIN" --static || true          # tolerate partial populate (§5)

say "running updates tier"
"$GDAY_BIN" --updates || true

say "writing initial /etc/motd"
"$GDAY_BIN" --write-motd || true

say "done"

# ── Summary report ───────────────────────────────────────────────────────────
# Installers are run rarely enough that flags/behaviour are easy to forget
# between uses — spell out what actually changed on this machine, and what
# else is available, rather than relying on the user to remember or go look
# it up in README/CLAUDE.md.
motd_d_count=$(grep -c '^motd\.d:' "$ROLLBACK" 2>/dev/null || printf 0)
motd_news_status='n/a — not present on this system'
if systemctl list-unit-files motd-news.timer --no-legend 2>/dev/null | grep -q .; then
  if grep -qF 'unit:motd-news.timer' "$ROLLBACK" 2>/dev/null; then
    motd_news_status='disabled (was firing and failing; restored on uninstall)'
  else
    motd_news_status='present, already inactive — left as-is'
  fi
fi
echo
echo "════════════════════════════════════════════════════════════════════"
echo " g'day installed"
echo "════════════════════════════════════════════════════════════════════"
echo "  binary          $GDAY_BIN"
echo "  libraries       $GDAY_LIB_DIR"
echo "  config          $GDAY_CONF  ($CONFIG_STATUS)"
echo "  plugin dir      $GDAY_ETC/status.d  (examples only — inert until activated)"
echo "  cache dir       $GDAY_VAR"
echo "  systemd timers  gday-static.timer    (boot+${GDAY_STATIC_ONBOOTSEC}, then ${GDAY_STATIC_ONCALENDAR})"
echo "                  gday-updates.timer   (${GDAY_UPDATES_ONCALENDAR})"
echo "                  gday-refresh.timer   (every ${GDAY_REFRESH_INTERVAL})"
if [[ -d /etc/update-motd.d ]]; then
  echo "  update-motd.d   ${motd_d_count} script(s) currently neutralised (execute bit dropped, not deleted)"
else
  echo "  update-motd.d   n/a — not present on this system"
fi
echo "  motd-news.timer ${motd_news_status}"
echo
echo "  Preview now:     gday"
echo "  Change cadence:  edit $GDAY_CONF, then re-run this script"
echo "  Uninstall:       sudo ./uninstall.sh          (keeps config + caches)"
echo "                   sudo ./uninstall.sh --purge  (removes everything, config + caches too)"
echo "════════════════════════════════════════════════════════════════════"
