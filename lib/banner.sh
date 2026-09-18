#!/usr/bin/env bash
# banner.sh — top-of-MOTD hostname banner + subtitle (CLAUDE.md §11). Static
# tier: rendered once into banner.txt. figlet/toilet are refresh-time optional
# (§2.6); absent ⇒ a plain bordered fallback. Never fails the assembly.
#
# GDAY_BANNER_FILE/GDAY_BANNER_SUBTITLE are read at static-refresh time, same
# as everything else here: editing GDAY_BANNER_FILE's content changes nothing
# in /etc/motd until the next `gday --refresh`/`--static` or the next boot/
# daily timer fire, not immediately.

[[ -n ${GDAY_BANNER_SH:-} ]] && return 0
GDAY_BANNER_SH=1

# Ceiling on override-banner line count (§4.1 of
# planning/gday-development-guide.md) — protects the §9 80-column/total-length
# invariants against an oversized GDAY_BANNER_FILE.
readonly GDAY_BANNER_MAX_LINES=20

# banner::_override_art — the verbatim contents of GDAY_BANNER_FILE, when set
# and readable (§17: an externally supplied path is validated — must be a
# regular, readable file), or "" to fall through to the normal figlet/toilet/
# box logic below. Unlike the figlet path this is NOT centred: an operator
# supplying fixed art (e.g. a department logo) owns its own layout.
#
# Tabs are expanded *before* sanitizing: render::sanitize (render.sh) strips
# 0x00-0x1F/0x7F, and 0x09 (tab) is inside that range, so un-expanded tabs
# would be silently deleted, shifting every character after them — a bug if
# missed, not a style choice. Over-wide lines are truncated and the total
# line count is capped, each logged once to stderr per run if it fires.
banner::_override_art() {
  local file=${GDAY_BANNER_FILE:-}
  [[ -n $file && -f $file && -r $file ]] || return 0

  local raw
  if command -v expand >/dev/null 2>&1; then
    raw=$(expand -- "$file" 2>/dev/null) || return 0
  else
    raw=$(cat -- "$file" 2>/dev/null) || return 0
  fi
  [[ -n $raw ]] || return 0

  local line lines=() n=0 truncated=0 capped=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(render::sanitize "$line")
    if (( ${#line} > GDAY_WIDTH )); then
      line=${line:0:GDAY_WIDTH}
      truncated=1
    fi
    if (( n >= GDAY_BANNER_MAX_LINES )); then
      capped=1
      break
    fi
    lines+=("$line")
    (( n++ ))
  done <<< "$raw"

  (( truncated )) && printf \
    'gday: warning: %s has lines wider than %d columns; truncated\n' \
    "$file" "$GDAY_WIDTH" >&2
  (( capped )) && printf \
    'gday: warning: %s has more than %d lines; capped\n' \
    "$file" "$GDAY_BANNER_MAX_LINES" >&2

  printf '%s\n' "${lines[@]}"
}

# banner::_hostname — short hostname, with fallbacks. Sanitized (§17): a
# rogue DHCP server can set an arbitrary hostname, and this value is embedded
# literally in the figlet/box art and subtitle line below.
banner::_hostname() {
  local h
  h=$(gday::probe hostname hostname -s)
  [[ -n $h ]] || h=$(uname -n 2>/dev/null)
  h=${h%%.*}
  render::sanitize "${h:-localhost}"
}

# banner::_art <host> — GDAY_BANNER_FILE override if set and readable,
# otherwise the figlet/toilet art, otherwise the bordered fallback.
banner::_art() {
  local host=$1 art=''

  local override
  override=$(banner::_override_art)
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  local font=${GDAY_FIGLET_FONT:-standard}
  if command -v figlet >/dev/null 2>&1; then
    art=$(figlet -f "$font" -w "$GDAY_WIDTH" "$host" 2>/dev/null)
    # Fall back to standard font if configured font is unavailable.
    [[ -n $art || $font == standard ]] || \
      art=$(figlet -f standard -w "$GDAY_WIDTH" "$host" 2>/dev/null)
  elif command -v toilet >/dev/null 2>&1; then
    art=$(toilet -f "$font" -w "$GDAY_WIDTH" "$host" 2>/dev/null)
    [[ -n $art || $font == standard ]] || \
      art=$(toilet -f standard -w "$GDAY_WIDTH" "$host" 2>/dev/null)
  fi
  if [[ -n ${GDAY_FIXTURE_DIR:-} && -r $GDAY_FIXTURE_DIR/figlet ]]; then
    art=$(cat -- "$GDAY_FIXTURE_DIR/figlet")   # let tests exercise the art path
  fi
  if [[ -n $art ]]; then
    # Strip trailing blank lines and centre within GDAY_WIDTH (ASCII art: byte
    # length == display width so awk length() is correct here).
    printf '%s\n' "$art" | awk -v w="$GDAY_WIDTH" '
      {lines[n++]=$0}
      END{ last=n-1;
           while (last>=0 && lines[last] ~ /^[[:space:]]*$/) last--;
           mx=0; for(i=0;i<=last;i++){l=length(lines[i]);if(l>mx)mx=l}
           pad=int((w-mx)/2); if(pad<0)pad=0;
           sp=""; for(i=0;i<pad;i++) sp=sp" ";
           for (i=0;i<=last;i++) print sp lines[i] }'
  else
    local box_w pad sp
    box_w=$(( ${#host} + 4 ))
    pad=$(( (GDAY_WIDTH - box_w) / 2 ))
    (( pad < 0 )) && pad=0
    sp=$(printf '%*s' "$pad" '')
    render::box "$host" | while IFS= read -r line; do printf '%s%s\n' "$sp" "$line"; done
  fi
}

# banner::_subtitle <host> — "<host> · <PRETTY_NAME> · <DE+version · session>".
# DE clause dropped when headless (§11, §15).
banner::_subtitle() {
  local host=$1 sub
  sub="${host} · ${GDAY_PRETTY_NAME:-Linux}"
  if [[ ${GDAY_HEADLESS:-1} -eq 0 ]]; then
    local de=${GDAY_DE:-} ses=${GDAY_SESSION:-} clause=''
    [[ -n $de ]] && clause=$de
    [[ -n $ses ]] && clause="${clause:+$clause · }${ses}"
    [[ -n $clause ]] && sub="${sub} · ${clause}"
  fi
  printf '%s' "$sub"
}

# gday::banner_section — full banner (art + subtitle) to stdout.
# GDAY_BANNER_SUBTITLE=0 suppresses the subtitle line (default: on) — needed
# alongside GDAY_BANNER_FILE, since a fixed logo (e.g. a department banner)
# rarely wants the computed "<host> · <PRETTY_NAME> · ..." line under it, and
# without this knob suppressing it would mean patching lib/banner.sh, which
# is the exact fork the override hook exists to prevent.
gday::banner_section() {
  local host sub pad
  host=$(banner::_hostname)
  banner::_art "$host"
  if [[ ${GDAY_BANNER_SUBTITLE:-1} != 0 ]]; then
    printf '\n'
    sub=$(banner::_subtitle "$host")
    pad=$(( (GDAY_WIDTH - ${#sub}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s%s\n' "$pad" '' "$sub"
  fi
}
