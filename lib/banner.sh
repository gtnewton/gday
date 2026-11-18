#!/usr/bin/env bash
# banner.sh — top-of-MOTD hostname banner + subtitle (CLAUDE.md §11). Static
# tier: rendered once into banner.txt. Default art is the hostname in the
# ANSI Shadow FIGfont (the old upyeros/00-hcmc look), drawn by a built-in
# renderer from lib/fonts/ansi-shadow.flf — figlet is not needed for it.
# figlet/toilet stay refresh-time optional (§2.6), used only when
# GDAY_FIGLET_FONT is set or the name is too wide. Never fails the assembly.
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

# banner::_figrender <font.flf> <text> — render <text> in a FIGfont with
# horizontal fitting (kerning), the layout ANSI Shadow declares. Printable
# ASCII only; exits non-zero on anything else. Byte-oriented on purpose so
# it behaves identically under mawk (Debian/Ubuntu's awk) and gawk: only
# ASCII spaces, the hardblank and the endmark are ever inspected, and
# multibyte glyph bytes pass through untouched. Verified byte-for-byte
# against `figlet -f ansi-shadow.flf` (A–Z, 0–9, '-') when written.
banner::_figrender() {
  local font=$1 text=$2
  [[ -r $font ]] || return 1
  awk -v text="$text" '
    # Minimal FIGfont renderer: printable ASCII, horizontal fitting (kerning).
    # Byte-oriented on purpose (mawk): only ASCII spaces, the hardblank and the
    # endmark are ever inspected; multibyte glyph bytes pass through untouched.
    NR == 1 {
      hb = substr($1, 6, 1); h = $2 + 0; skip = $6 + 0
      first = 2 + skip; code = 32; row = 0; next
    }
    NR < first { next }
    code <= 126 {
      line = $0
      em = substr(line, length(line), 1)
      while (length(line) > 0 && substr(line, length(line), 1) == em) line = substr(line, 1, length(line) - 1)
      g[code, row] = line
      if (++row == h) { row = 0; code++ }
    }
    END {
      for (r = 0; r < h; r++) acc[r] = ""
      n = length(text)
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        for (k = 32; k <= 126; k++) if (sprintf("%c", k) == c) break
        if (k > 126) exit 2
        amt = -1
        for (r = 0; r < h; r++) {
          t = 0; if (match(acc[r], / +$/)) t = RLENGTH
          l = 0; if (match(g[k, r], /^ +/)) l = RLENGTH
          if (acc[r] == "") t = 0
          if (amt < 0 || t + l < amt) amt = t + l
        }
        if (i == 1) amt = 0
        for (r = 0; r < h; r++) {
          a = acc[r]; b = g[k, r]; m = amt
          t = 0; if (match(a, / +$/)) t = RLENGTH
          d = (m < t) ? m : t; a = substr(a, 1, length(a) - d); m -= d
          b = substr(b, m + 1)
          acc[r] = a b
        }
      }
      last = h - 1
      for (r = 0; r < h; r++) { gsub(/\$/, " ", acc[r]); sub(/ +$/, "", acc[r]) }
      while (last >= 0 && acc[last] == "") last--
      for (r = 0; r <= last; r++) print acc[r]
    }
  ' "$font"
}

# banner::_center — centre stdin lines within GDAY_WIDTH as one block (common
# left pad from the widest line). Widths in characters, not bytes: the art
# is box-drawing UTF-8, so awk length() under mawk would over-count 3×.
banner::_center() {
  local -a lines
  local line w max=0 pad
  readarray -t lines
  for line in "${lines[@]}"; do
    w=$(render::_len "$line"); (( w > max )) && max=$w
  done
  pad=$(( (GDAY_WIDTH - max) / 2 )); (( pad < 0 )) && pad=0
  for line in "${lines[@]}"; do printf '%*s%s\n' "$pad" '' "$line"; done
}

# banner::_builtin_art <host> — <host> upper-cased in ANSI Shadow, or fail if
# the font is missing, a character isn't printable ASCII, or the result is
# wider than GDAY_WIDTH (≈ 10 characters fit).
banner::_builtin_art() {
  local host=$1 art line
  [[ $host =~ ^[[:print:]]+$ ]] || return 1
  art=$(banner::_figrender "${GDAY_LIB:-}/fonts/ansi-shadow.flf" "${host^^}") || return 1
  [[ -n $art ]] || return 1
  while IFS= read -r line; do
    (( $(render::_len "$line") <= GDAY_WIDTH )) || return 1
  done <<< "$art"
  printf '%s\n' "$art"
}

# banner::_figlet_art <host> <font> — figlet/toilet art, or nothing.
banner::_figlet_art() {
  local host=$1 font=$2 art=''
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
  # Strip trailing whitespace and trailing blank lines.
  [[ -n $art ]] && printf '%s\n' "$art" | sed 's/[[:space:]]*$//' \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
  return 0
}

# banner::_art <host> — in order: GDAY_BANNER_FILE override (verbatim, not
# centred); figlet in GDAY_FIGLET_FONT if that key is set (explicit opt-in);
# built-in ANSI Shadow; figlet standard (name too wide for ANSI Shadow);
# bordered box. Everything except the override is centred.
banner::_art() {
  local host=$1 art=''

  local override
  override=$(banner::_override_art)
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  if [[ -n ${GDAY_FIGLET_FONT:-} ]]; then
    art=$(banner::_figlet_art "$host" "$GDAY_FIGLET_FONT")
  fi
  [[ -n $art ]] || art=$(banner::_builtin_art "$host") || art=''
  [[ -n $art ]] || art=$(banner::_figlet_art "$host" standard)
  [[ -n $art ]] || art=$(render::box "$host")
  printf '%s\n' "$art" | banner::_center
}

# banner::_subtitle <host> — "<host> · <PRETTY_NAME> · <DE+version>". DE
# clause dropped when headless (§11, §15). The seat0 session type (wayland/
# x11) is deliberately not shown here any more (Greg, 2026-11-18); it stays
# in the full report's OS → Desktop row.
banner::_subtitle() {
  local host=$1 sub
  sub="${host} · ${GDAY_PRETTY_NAME:-Linux}"
  if [[ ${GDAY_HEADLESS:-1} -eq 0 && -n ${GDAY_DE:-} ]]; then
    sub="${sub} · ${GDAY_DE}"
  fi
  printf '%s' "$sub"
}

# banner::_titled_rule [text] — a full-width '=' rule; with <text>, centred
# in it as "==== text ====" (the old upyeros/00-hcmc frame). Text too long
# for at least "== " each side is truncated with "…".
banner::_titled_rule() {
  local text=${1:-} n left right max=$(( GDAY_WIDTH - 6 ))
  if [[ -z $text ]]; then
    render::_repeat '=' "$GDAY_WIDTH"; printf '\n'; return 0
  fi
  if (( $(render::_len "$text") > max )); then
    local LC_ALL=C.UTF-8
    text="${text:0:max-1}…"
  fi
  n=$(( $(render::_len "$text") + 2 ))
  left=$(( (GDAY_WIDTH - n) / 2 )); right=$(( GDAY_WIDTH - n - left ))
  render::_repeat '=' "$left"; printf ' %s ' "$text"; render::_repeat '=' "$right"
  printf '\n'
}

# gday::banner_section — full banner (art + subtitle) to stdout.
# GDAY_BANNER_SUBTITLE=0 suppresses the subtitle line (default: on) — needed
# alongside GDAY_BANNER_FILE, since a fixed logo (e.g. a department banner)
# rarely wants the computed "<host> · <PRETTY_NAME> · ..." line under it, and
# without this knob suppressing it would mean patching lib/banner.sh, which
# is the exact fork the override hook exists to prevent.
gday::banner_section() {
  local host
  host=$(banner::_hostname)
  banner::_titled_rule
  banner::_art "$host"
  if [[ ${GDAY_BANNER_SUBTITLE:-1} != 0 ]]; then
    banner::_titled_rule "$(banner::_subtitle "$host")"
  else
    banner::_titled_rule
  fi
}
