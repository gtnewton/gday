#!/usr/bin/env bash
# os.sh — OPERATING SYSTEM section (CLAUDE.md §11). Distro + arch, kernel, the
# §10 Desktop line (omitted when headless), uptime and derived boot time.

[[ -n ${GDAY_OS_SH:-} ]] && return 0
GDAY_OS_SH=1

# os::_uptime_seconds — integer uptime seconds from /proc/uptime, or "".
os::_uptime_seconds() {
  local raw
  raw=$(gday::read_proc uptime /proc/uptime)
  [[ -n $raw ]] || return 0
  awk '{printf "%d", $1}' <<< "$raw"
}

# os::distro — "<PRETTY_NAME>[ (rolling)] · <arch>".
os::distro() {
  local line="${GDAY_PRETTY_NAME:-Linux}"
  [[ ${GDAY_ROLLING:-0} -eq 1 ]] && line="${line} (rolling)"
  render::row 'OS' "${line} · ${GDAY_ARCH:-unknown}"
}

# os::kernel — `uname -r`.
os::kernel() {
  local k
  k=$(gday::probe uname uname -r)
  [[ -n $k ]] && render::row 'Kernel' "$k"
}

# os::desktop — installed DE + local seat session; omitted when headless (§10).
os::desktop() {
  [[ ${GDAY_HEADLESS:-1} -eq 0 ]] || return 0
  local de=${GDAY_DE:-} ses=${GDAY_SESSION:-} val=''
  [[ -n $de ]] && val=$de
  [[ -n $ses ]] && val="${val:+$val · }${ses} (seat0)"
  [[ -n $val ]] && render::row 'Desktop' "$val"
}

# os::uptime — uptime as "Nd HH:MM" plus the derived boot timestamp.
os::uptime() {
  local secs
  secs=$(os::_uptime_seconds)
  [[ -n $secs ]] || return 0
  local d=$(( secs / 86400 )) h=$(( (secs % 86400) / 3600 )) m=$(( (secs % 3600) / 60 ))
  render::row 'Uptime' "$(printf '%dd %02d:%02d' "$d" "$h" "$m")"
  local now boot epoch
  now=$(date +%s 2>/dev/null) || return 0
  epoch=$(( now - secs ))
  # GNU date uses -d @epoch; BSD/macOS uses -r epoch. Try both for portability.
  boot=$(date -d "@${epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null) \
    || boot=$(date -r "${epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null) || boot=''
  [[ -n $boot ]] && render::row 'Booted' "$boot"
}

# gday::os_section — assemble the OPERATING SYSTEM section.
gday::os_section() {
  render::header '🐧' 'OPERATING SYSTEM'
  os::distro
  os::kernel
  os::desktop
  os::uptime
}
