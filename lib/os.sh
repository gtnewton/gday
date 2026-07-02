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

# os::last_login — most recent login on this machine, system-wide (§3: never
# personalized to the viewer — that's sshd's PrintLastLog's job, done
# correctly per-session at the actual moment of login; this is a global fact
# like everything else in this section, and always names the account so it
# can't read as "your" login).
#
# `last -w --time-format iso`: -w avoids truncating long host/IPv6 columns
# (default width appends a bare `*` instead, e.g. `fe80::bd3e:ab12*`);
# --time-format iso turns the timestamp into one space-free token instead of
# `Thu Jul  2 11:21` (several tokens), which is what makes the host column
# (empty for local/console logins, otherwise variable-width) unambiguous to
# split on — this is why we don't just parse `last`'s default columns.
os::last_login() {
  local out parsed user host ts val date_part
  out=$(gday::probe last last -n 5 -w --time-format iso)
  [[ -n $out ]] || return 0
  # Fields joined with `|`, not a tab: bash `read` always treats tab as IFS
  # *whitespace* regardless of what IFS is set to, collapsing consecutive
  # tabs and silently dropping the empty host field for local/console
  # logins. `|` isn't whitespace, so an empty middle field survives.
  parsed=$(awk '
    /^reboot / || /^shutdown / || /^wtmp begins/ || NF==0 { next }
    {
      user = $1; host = ""; ts = ""
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) { ts = $i; break }
        host = (host == "" ? $i : host " " $i)
      }
      if (ts != "") { printf "%s|%s|%s\n", user, host, ts; exit }
    }
  ' <<< "$out")
  [[ -n $parsed ]] || return 0
  IFS='|' read -r user host ts <<< "$parsed"
  [[ -n $user && -n $ts ]] || return 0
  date_part=$(date -d "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 0
  if [[ -n $host ]]; then
    val="${user} from ${host} · ${date_part}"
  else
    val="${user} · ${date_part}"
  fi
  render::row 'Last login' "$val"
}

# gday::os_section — assemble the OPERATING SYSTEM section.
gday::os_section() {
  render::header '🐧' 'OPERATING SYSTEM'
  os::distro
  os::kernel
  os::desktop
  os::uptime
  os::last_login
}
