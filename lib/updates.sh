#!/usr/bin/env bash
# updates.sh — UPDATES tier (CLAUDE.md §6, §11). Reads already-synced package
# state only; MUST NOT synchronise databases (no apt-get update / pacman -Sy /
# dnf makecache). Produces updates.txt: `updates=<n>` and `reboot=<0|1>`.

[[ -n ${GDAY_UPDATES_SH:-} ]] && return 0
GDAY_UPDATES_SH=1

# updates::_count_lines — count non-empty lines on stdin.
updates::_count_lines() { grep -c '[^[:space:]]' || true; }

# updates::count — pending update count for the detected PM, or "" if unknown.
updates::count() {
  case ${GDAY_PM:-} in
    apt)
      # Prefer update-notifier's apt-check ("updates;security" on stderr).
      if [[ -z ${GDAY_FIXTURE_DIR:-} ]] && [[ -x /usr/lib/update-notifier/apt-check ]]; then
        local pair
        pair=$(/usr/lib/update-notifier/apt-check 2>&1) || return 0
        printf '%s' "${pair%%;*}"
        return 0
      fi
      # Fallback: simulate the upgrade and count ^Inst lines. Does NOT sync.
      gday::probe apt-check apt-get -s -o Debug::NoLocking=true upgrade \
        | grep -c '^Inst' || true
      ;;
    dnf)
      # `dnf check-update` exits 100 when updates exist; count package rows.
      gday::probe dnf-check-update dnf -q check-update \
        | awk 'NF>=3 && $1 !~ /^(Obsoleting|Last|Security:)/ {n++} END{print n+0}'
      ;;
    pacman)
      # checkupdates (pacman-contrib) uses a temp DB copy — safe, never -Sy.
      command -v checkupdates >/dev/null 2>&1 || [[ -n ${GDAY_FIXTURE_DIR:-} ]] || return 0
      gday::probe checkupdates checkupdates | updates::_count_lines
      ;;
    zypper)
      gday::probe zypper-updates zypper -q list-updates \
        | awk -F'|' '/^v |^i /{n++} END{print n+0}'
      ;;
    *) return 0 ;;
  esac
}

# updates::reboot_required — 1 if a reboot is pending, else 0.
updates::reboot_required() {
  if [[ -n ${GDAY_FIXTURE_DIR:-} ]]; then
    [[ -e $GDAY_FIXTURE_DIR/reboot-required ]] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  # Debian/Ubuntu: a flag file.
  [[ -e /run/reboot-required ]] && { printf '1'; return 0; }
  # Fedora: needs-restarting -r exits 1 when a reboot is advised.
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || { printf '1'; return 0; }
  fi
  printf '0'
}

# gday::build_updates — write updates.txt for the updates tier.
gday::build_updates() {
  gday::detect
  mkdir -p "$GDAY_VAR"
  local count reboot tmp
  count=$(updates::count 2>/dev/null) || count=''
  count=${count//[![:digit:]]/}
  reboot=$(updates::reboot_required 2>/dev/null) || reboot=0
  tmp=$(mktemp "${GDAY_VAR}/.updates.XXXXXX") || return 1
  printf 'updates=%s\nreboot=%s\n' "${count}" "${reboot}" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$GDAY_VAR/updates.txt"
}
