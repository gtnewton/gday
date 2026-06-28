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
  if command -v figlet >/dev/null 2>&1; then
    art=$(figlet -f standard -w "$GDAY_WIDTH" "$host" 2>/dev/null)
  elif command -v toilet >/dev/null 2>&1; then
    art=$(toilet -f standard -w "$GDAY_WIDTH" "$host" 2>/dev/null)
  fi
  if [[ -n ${GDAY_FIXTURE_DIR:-} && -r $GDAY_FIXTURE_DIR/figlet ]]; then
    art=$(cat -- "$GDAY_FIXTURE_DIR/figlet")   # let tests exercise the art path
  fi
  if [[ -n $art ]]; then
    # Strip trailing all-blank lines figlet tends to emit (portable awk).
    printf '%s\n' "$art" | awk '
      {lines[n++]=$0}
      END{ last=n-1;
           while (last>=0 && lines[last] ~ /^[[:space:]]*$/) last--;
           for (i=0;i<=last;i++) print lines[i] }'
  else
    render::box "$host"
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
  local host
  host=$(banner::_hostname)
  banner::_art "$host"
  printf '\n'
  render::row '' "$(banner::_subtitle "$host")"
}
