#!/usr/bin/env bash
# banner.sh — top-of-MOTD hostname banner + subtitle (CLAUDE.md §11). Static
# tier: rendered once into banner.txt. figlet/toilet are refresh-time optional
# (§2.6); absent ⇒ a plain bordered fallback. Never fails the assembly.

[[ -n ${GDAY_BANNER_SH:-} ]] && return 0
GDAY_BANNER_SH=1

# banner::_hostname — short hostname, with fallbacks.
banner::_hostname() {
  local h
  h=$(gday::probe hostname hostname -s)
  [[ -n $h ]] || h=$(uname -n 2>/dev/null)
  h=${h%%.*}
  printf '%s' "${h:-localhost}"
}

# banner::_art <host> — the figlet/toilet art, or the bordered fallback.
banner::_art() {
  local host=$1 art=''
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
gday::banner_section() {
  local host sub pad
  host=$(banner::_hostname)
  banner::_art "$host"
  printf '\n'
  sub=$(banner::_subtitle "$host")
  pad=$(( (GDAY_WIDTH - ${#sub}) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%*s%s\n' "$pad" '' "$sub"
}
