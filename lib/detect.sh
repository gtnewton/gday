#!/usr/bin/env bash
# detect.sh — resolve environment once, export, reuse (CLAUDE.md §10).
#
# Populates GDAY_* globals: distro identity, arch, package manager, privilege,
# and (later tiers) desktop/session. Every probe degrades silently; absence is
# represented as an empty string, never an error.

[[ -n ${GDAY_DETECT_SH:-} ]] && return 0
GDAY_DETECT_SH=1

# detect::_osrelease <KEY> — print value of KEY from /etc/os-release, unquoted.
# Parsed (not sourced) so os-release content is treated as data, not code (§17).
detect::_osrelease() {
  local key=$1 line val file=/etc/os-release
  [[ -n ${GDAY_FIXTURE_DIR:-} && -r $GDAY_FIXTURE_DIR/os-release ]] \
    && file=$GDAY_FIXTURE_DIR/os-release
  [[ -r $file ]] || return 1
  while IFS= read -r line; do
    [[ $line == "$key="* ]] || continue
    val=${line#*=}
    val=${val#\"}; val=${val%\"}
    printf '%s' "$val"
    return 0
  done < "$file"
  return 1
}

# detect::_pkg_manager — resolve PM from ID/ID_LIKE, falling back to probing.
detect::_pkg_manager() {
  local id=$1 like=$2 tok
  for tok in "$id" $like; do
    case $tok in
      debian|ubuntu|linuxmint|raspbian|pop) printf 'apt';    return 0 ;;
      fedora|rhel|centos|rocky|almalinux)   printf 'dnf';    return 0 ;;
      arch|manjaro|endeavouros)             printf 'pacman'; return 0 ;;
      opensuse*|suse|sles)                  printf 'zypper'; return 0 ;;
    esac
  done
  # Last resort: probe for a binary.
  local pm
  for pm in apt-get dnf pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then
      [[ $pm == apt-get ]] && pm=apt
      printf '%s' "$pm"
      return 0
    fi
  done
  return 1
}

# detect::_seat0_session — id of the active graphical session on seat0, or "".
detect::_seat0_session() {
  local s
  s=$(gday::probe loginctl-seat0 loginctl show-seat seat0 -p ActiveSession)
  s=${s#ActiveSession=}; s=${s//[$'\r\n']/}
  if [[ -n $s ]]; then printf '%s' "$s"; return 0; fi
  # Fallback: first session listed on seat0.
  gday::probe loginctl-sessions loginctl list-sessions --no-legend \
    | awk '$4=="seat0"{print $1; exit}'
}

# detect::desktop — installed DE + version, seat0 session type, headless flag
# (§10). Reports the *installed* DE and the *local* seat's session, never the
# SSH session. Sets GDAY_DE, GDAY_SESSION, GDAY_HEADLESS.
detect::desktop() {
  GDAY_DE='' GDAY_SESSION='' GDAY_HEADLESS=1
  local v
  v=$(gday::probe gnome-shell gnome-shell --version)
  if [[ -n $v ]]; then
    v=${v##* }
    GDAY_DE="GNOME ${v}"
  else
    v=$(gday::probe plasmashell plasmashell --version)
    if [[ -n $v ]]; then
      v=${v##* }
      GDAY_DE="KDE Plasma ${v}"
    fi
  fi

  local sid t
  sid=$(detect::_seat0_session)
  if [[ -n $sid ]]; then
    t=$(gday::probe "loginctl-session-${sid}" loginctl show-session "$sid" -p Type)
    t=${t#Type=}; t=${t//[$'\r\n']/}
    [[ $t == wayland || $t == x11 ]] && GDAY_SESSION=$t
  fi

  if [[ -n $GDAY_DE || -n $GDAY_SESSION ]]; then
    GDAY_HEADLESS=0
  elif [[ -z ${GDAY_FIXTURE_DIR:-} ]] \
       && command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet display-manager 2>/dev/null; then
    GDAY_HEADLESS=0
  fi
  export GDAY_DE GDAY_SESSION GDAY_HEADLESS
}

# gday::detect — run once; sets and exports the GDAY_* environment globals.
gday::detect() {
  GDAY_ID=$(detect::_osrelease ID || true)
  GDAY_ID_LIKE=$(detect::_osrelease ID_LIKE || true)
  GDAY_PRETTY_NAME=$(detect::_osrelease PRETTY_NAME || true)
  GDAY_VERSION_ID=$(detect::_osrelease VERSION_ID || true)
  # Absent VERSION_ID ⇒ a rolling release (§10).
  if [[ -z $GDAY_VERSION_ID ]]; then
    GDAY_ROLLING=1
  else
    GDAY_ROLLING=0
  fi

  GDAY_ARCH=$(uname -m 2>/dev/null || printf 'unknown')

  GDAY_PM=$(detect::_pkg_manager "$GDAY_ID" "$GDAY_ID_LIKE" || true)

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    GDAY_ROOT=1
  else
    GDAY_ROOT=0
  fi

  detect::desktop

  export GDAY_ID GDAY_ID_LIKE GDAY_PRETTY_NAME GDAY_VERSION_ID GDAY_ROLLING
  export GDAY_ARCH GDAY_PM GDAY_ROOT
}
