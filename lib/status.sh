#!/usr/bin/env bash
# status.sh — STATUS section (CLAUDE.md §11, §12). Assemble tier. Glyph-flagged
# lines for updates, reboot, failed services and SMART, then user plugins from
# status.d. Every line is isolated; a failure drops only its own line (§5).

[[ -n ${GDAY_STATUS_SH:-} ]] && return 0
GDAY_STATUS_SH=1

# status::updates — from the cached updates count (updates.txt).
status::updates() {
  [[ -r $GDAY_VAR/updates.txt ]] || return 0
  local line count=''
  while IFS= read -r line; do
    [[ $line == updates=* ]] && count=${line#updates=}
  done < "$GDAY_VAR/updates.txt"
  [[ $count =~ ^[0-9]+$ ]] || return 0
  if (( count > 0 )); then
    render::status "$GDAY_WARN" "${count} update$([[ $count -ne 1 ]] && printf s) available"
  else
    render::status "$GDAY_OK" 'System up to date'
  fi
}

# status::reboot — from the cached reboot flag (updates.txt).
status::reboot() {
  [[ -r $GDAY_VAR/updates.txt ]] || return 0
  local line reboot=0
  while IFS= read -r line; do
    [[ $line == reboot=* ]] && reboot=${line#reboot=}
  done < "$GDAY_VAR/updates.txt"
  [[ $reboot == 1 ]] && render::status "$GDAY_WARN" 'Reboot required'
}

# status::_hint <command> <gloss> — a pointer line with its gloss aligned in a
# column. Padded by character count (render::_len), not printf's %-Ns, which
# pads by bytes and so under-pads anything containing the 3-byte "→".
status::_hint() {
  local cmd=$1 gloss=$2 pad
  pad=$(( 28 - $(render::_len "$cmd") ))
  (( pad < 1 )) && pad=1
  render::cont "${cmd}$(printf '%*s' "$pad" '')${gloss}"
}

# status::services — live count of failed systemd units.
status::services() {
  command -v systemctl >/dev/null 2>&1 || [[ -n ${GDAY_FIXTURE_DIR:-} ]] || return 0
  local out n
  out=$(gday::probe systemctl-failed systemctl --failed --no-legend)
  n=$(printf '%s' "$out" | grep -c '[^[:space:]]' || true)
  if (( n > 0 )); then
    render::status "$GDAY_FAULT" "${n} failed unit$([[ $n -ne 1 ]] && printf s)"
    local line name first=''
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      # `systemctl --failed` prefixes each row with a state glyph (●) before
      # the unit name on modern systemd, so the naive "first whitespace-
      # delimited token" grabs the glyph, not the name. Unit types are a
      # fixed, closed set, so scan for the first field ending in a known
      # suffix — works whether or not the glyph column is present.
      name=$(awk '{
        for (i = 1; i <= NF; i++) {
          if ($i ~ /\.(service|socket|target|mount|automount|swap|timer|path|slice|scope|device)$/) {
            print $i; exit
          }
        }
      }' <<< "$line")
      [[ -n $name ]] || name=${line%%[[:space:]]*}   # best-effort fallback
      [[ -z $first ]] && first=$name
      render::cont "$name"
    done <<< "$out"
    # How to find out more, and why it failed. The first pointer is the one
    # brief mode keeps (gday::_brief_status_filter keeps only the first →
    # line), and brief drops the unit names — so with several units the
    # first pointer must stand alone: `--failed`, not a `<unit>` placeholder.
    if (( n == 1 )) && [[ -n $first ]]; then
      render::cont "→ systemctl status $first"
      render::cont "→ journalctl -b -u $first"
    else
      render::cont "→ systemctl --failed"
      status::_hint '→ systemctl status <unit>' 'why it failed + recent log'
      status::_hint '→ journalctl -b -u <unit>' 'full log since boot'
    fi
  else
    render::status "$GDAY_OK" 'No failed units'
  fi
}

# status::disks — summarise SMART results cached by the static tier (smart.txt:
# one "device: PASSED|FAILED" line per disk).
status::disks() {
  [[ -r $GDAY_VAR/smart.txt ]] || return 0
  local line res total=0 bad=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    res=${line##*:}
    (( total++ ))
    [[ $res == *FAIL* ]] && (( bad++ ))
  done < "$GDAY_VAR/smart.txt"
  (( total > 0 )) || return 0
  if (( bad > 0 )); then
    render::status "$GDAY_FAULT" "SMART: ${bad} of ${total} disk$([[ $total -ne 1 ]] && printf s) failing"
  else
    render::status "$GDAY_OK" "SMART healthy (${total} disk$([[ $total -ne 1 ]] && printf s))"
  fi
}

# status::_plugin_safe <path> — defense-in-depth (§17): status.d executables
# run with this process's privileges (root, under the shipped systemd
# service). Require the same discipline as sudoers.d — owned by root or the
# invoking user, never group/other-writable — so a local user who somehow got
# write access to the directory or a file in it can't plant or swap a script
# that then runs as root every 5 minutes.
status::_plugin_safe() {
  local path=$1 owner perm
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  perm=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ $owner == 0 || $owner == "${EUID:-$(id -u)}" ]] || return 1
  (( 8#$perm & 0022 )) && return 1
  return 0
}

# status::plugins — run executables in status.d in filename order; append their
# stdout verbatim (control bytes stripped per line — §17: a plugin reading an
# attacker-influenced log could otherwise carry terminal escape sequences into
# /etc/motd). A plugin that exits non-zero or prints nothing is skipped (§12).
status::plugins() {
  local dir=${GDAY_PLUGIN_DIR:-/etc/gday/status.d}
  [[ -d $dir ]] || return 0
  status::_plugin_safe "$dir" || return 0
  local f out line
  for f in "$dir"/*; do
    [[ -f $f && -x $f ]] || continue
    status::_plugin_safe "$f" || continue
    out=$("$f" 2>/dev/null) || continue
    [[ -n $out ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      printf '%s\n' "$(render::sanitize "$line")"
    done <<< "$out"
  done
}

# gday::status_section — assemble STATUS.
gday::status_section() {
  render::header '📊' 'STATUS'
  status::updates
  status::reboot
  status::services
  status::disks
  status::alerts
  status::plugins
}
