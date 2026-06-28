#!/usr/bin/env bash
# render.sh — g'day rendering framework.
#
# Fixed render width of 80 columns (CLAUDE.md §9). The timer has no tty, so
# width never adapts. Every section header, body row, rule and bar flows
# through the helpers here so layout cannot drift between core and plugins.
#
# Sourceable standalone for smoke tests:
#   source lib/render.sh; render::header "🖥️" HARDWARE; render::row CPU "..."

# Guard against double-sourcing.
[[ -n ${GDAY_RENDER_SH:-} ]] && return 0
GDAY_RENDER_SH=1

# Fixed presentation constants (§9).
readonly GDAY_WIDTH=80
readonly GDAY_LABEL_WIDTH=12
readonly GDAY_BAR_WIDTH_DEFAULT=22

readonly GDAY_GLYPH_FILL='█'
readonly GDAY_GLYPH_EMPTY='░'
readonly GDAY_CAP_L='▕'
readonly GDAY_CAP_R='▏'
readonly GDAY_RULE_CHAR='─'

# Status glyphs (§9).
readonly GDAY_OK='✅'
readonly GDAY_WARN='⚠️'
readonly GDAY_FAULT='❌'

# Column where a row's value begins: indent + label column + one space.
readonly GDAY_VALUE_COL=16

# Most section/status emoji occupy two terminal cells. We treat them as such
# when computing rule fill; a terminal that renders an emoji at a different
# width will leave the trailing rule one cell long/short, which is cosmetic.
readonly GDAY_EMOJI_CELLS=2

# gday::probe <fixture-name> <command> [args...] — THE probe seam shared by all
# sections. Runs the real command (gated by command -v, failure tolerated per
# §5), or reads a captured fixture when GDAY_FIXTURE_DIR is set, so every probe
# is testable off-target. Always succeeds; emits nothing on failure/absence.
gday::probe() {
  local name=$1; shift
  if [[ -n ${GDAY_FIXTURE_DIR:-} ]]; then
    local f="$GDAY_FIXTURE_DIR/$name"
    [[ -r $f ]] && cat -- "$f"
    return 0
  fi
  command -v "$1" >/dev/null 2>&1 || return 0
  "$@" 2>/dev/null || return 0
}

# gday::read_proc <fixture-name> <real-path> — like gday::probe but for a
# /proc or /sys file, honouring the fixture seam.
gday::read_proc() {
  local name=$1 path=$2
  if [[ -n ${GDAY_FIXTURE_DIR:-} ]]; then
    [[ -r $GDAY_FIXTURE_DIR/$name ]] && cat -- "$GDAY_FIXTURE_DIR/$name"
    return 0
  fi
  [[ -r $path ]] && cat -- "$path"
  return 0
}

# render::_repeat <char> <n> — emit <char> repeated <n> times, no subshell loop.
render::_repeat() {
  local ch=$1 n=$2 pad
  (( n <= 0 )) && return 0
  printf -v pad '%*s' "$n" ''
  printf '%s' "${pad// /$ch}"
}

# render::rule — a full-width horizontal rule.
render::rule() {
  render::_repeat "$GDAY_RULE_CHAR" "$GDAY_WIDTH"
  printf '\n'
}

# render::header <emoji> <LABEL> — §9 section header:
#   space, emoji, two spaces, UPPER label, one space, rule to column 80.
render::header() {
  local emoji=$1 label=$2 used fill
  # Display width of the textual prefix, emoji counted as GDAY_EMOJI_CELLS.
  used=$(( 1 + GDAY_EMOJI_CELLS + 2 + ${#label} + 1 ))
  fill=$(( GDAY_WIDTH - used ))
  (( fill < 0 )) && fill=0
  printf ' %s  %s ' "$emoji" "$label"
  render::_repeat "$GDAY_RULE_CHAR" "$fill"
  printf '\n'
}

# render::row <label> <value> — §9 body row: three-space indent, fixed-width
# label column, value follows. THE shared alignment helper for core + plugins.
render::row() {
  local label=$1 value=$2
  printf '   %-*s %s\n' "$GDAY_LABEL_WIDTH" "$label" "$value"
}

# render::cont <value> — a continuation line aligned under the value column,
# for wrapping long values within the indent rather than overflowing (§9).
render::cont() {
  local value=$1
  printf '   %-*s %s\n' "$GDAY_LABEL_WIDTH" '' "$value"
}

# render::status <glyph> <text> — a glyph-led STATUS line: three-space indent,
# glyph, two spaces, message. The shared form for core status rows and plugins.
render::status() {
  local glyph=$1 text=$2
  printf '   %s  %s\n' "$glyph" "$text"
}

# render::wrap <label> <text> — emit <text> as a row under <label>, wrapping on
# whitespace within the value column so long values never overflow 80 (§9).
render::wrap() {
  local label=$1 text=$2 budget word line='' first=1
  budget=$(( GDAY_WIDTH - GDAY_VALUE_COL ))
  for word in $text; do
    if [[ -z $line ]]; then
      line=$word
    elif (( ${#line} + 1 + ${#word} <= budget )); then
      line="$line $word"
    else
      if (( first )); then render::row "$label" "$line"; first=0
      else render::cont "$line"; fi
      line=$word
    fi
  done
  if [[ -n $line ]]; then
    if (( first )); then render::row "$label" "$line"; else render::cont "$line"; fi
  fi
}

# render::bar <percent> [width] — §9 usage bar with caps.
render::bar() {
  local pct=$1 width=${2:-$GDAY_BAR_WIDTH_DEFAULT} filled empty
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  printf '%s' "$GDAY_CAP_L"
  render::_repeat "$GDAY_GLYPH_FILL" "$filled"
  render::_repeat "$GDAY_GLYPH_EMPTY" "$empty"
  printf '%s' "$GDAY_CAP_R"
}

# render::box <text> — bordered single-line box, the figlet-absent banner
# fallback (§11). Text is ASCII hostname; clamped to the render width.
render::box() {
  local text=" $1 " n rule
  n=${#text}
  (( n > GDAY_WIDTH - 2 )) && n=$(( GDAY_WIDTH - 2 ))
  rule=$(render::_repeat '─' "$n")
  printf '┌%s┐\n' "$rule"
  printf '│%s│\n' "$text"
  printf '└%s┘\n' "$rule"
}

# render::hkib <kib> — human-readable size from a KiB integer (e.g. 120G, 1.8T).
render::hkib() {
  awk -v k="${1:-0}" 'BEGIN{
    u="KMGTP"; v=k; i=1;
    while (v >= 1024 && i < 5) { v/=1024; i++ }
    if (v < 10 && v != int(v)) printf "%.1f%s", v, substr(u,i,1);
    else printf "%.0f%s", v, substr(u,i,1);
  }'
}
