#!/usr/bin/env bash
# alerts.sh — external health-check consumer (CLAUDE.md §11/§12,
# planning/alerts-section.md). Assemble tier. Renders non-PASS rows from
# `*.alerts` files dropped by producers gday does not itself run (a server's
# nightly-job checker is the motivating case) into STATUS, between
# status::disks and status::plugins.
#
# Format is `gday-alerts v1`: tab-separated records, never JSON (see
# alerts-section.md §2 — a jq dependency, and JSON's all-or-nothing parsing
# is incompatible with gday's per-row degradation contract, §5).
#
# `/etc/motd` is a phishing surface (§17), so files here get the same
# ownership/mode discipline as `status.d` plugins — status::_plugin_safe
# (lib/status.sh) is reused unchanged, not reimplemented.

[[ -n ${GDAY_ALERTS_SH:-} ]] && return 0
GDAY_ALERTS_SH=1

# alerts::_dir — the resolved alerts directory, or "" if it doesn't exist.
# An absent directory is a normal, silent state (§4.6) — most machines never
# run a producer — not a warning.
alerts::_dir() {
  local d=${GDAY_ALERTS_DIR:-/var/lib/gday/alerts.d}
  [[ -d $d ]] && printf '%s' "$d"
}

# alerts::_is_expected <name> — true if <name> is in GDAY_ALERTS_EXPECT
# (space-separated). Identity is always the file's basename minus `.alerts`
# — the header's `@ source=` is display text only (§3's own header table),
# never used for matching, so a rejected file (whose header we refuse to
# trust) can still be recognised as a declared producer from its filename.
alerts::_is_expected() {
  local name=$1 want
  for want in ${GDAY_ALERTS_EXPECT:-}; do
    [[ $name == "$want" ]] && return 0
  done
  return 1
}

# alerts::_header <file> <key> — value of "@ key=value", or "".
alerts::_header() {
  local file=$1 key=$2 line
  while IFS= read -r line; do
    case $line in
      "@ ${key}="*) printf '%s' "${line#"@ ${key}="}"; return 0 ;;
    esac
  done < "$file"
}

# alerts::_seconds_from_age <NNh|NNm> — seconds, or "" if malformed.
alerts::_seconds_from_age() {
  local age=$1
  if [[ $age =~ ^([0-9]+)h$ ]]; then
    printf '%d' $(( 10#${BASH_REMATCH[1]} * 3600 ))
  elif [[ $age =~ ^([0-9]+)m$ ]]; then
    printf '%d' $(( 10#${BASH_REMATCH[1]} * 60 ))
  fi
}

# alerts::_max_age_for_file <file> — this file's `@ expires` (falling back to
# GDAY_ALERTS_MAX_AGE, falling back to 26h), in seconds. §5: an invalid value
# warns and falls back rather than aborting.
alerts::_max_age_for_file() {
  local file=$1 hdr secs
  hdr=$(alerts::_header "$file" expires)
  if [[ -n $hdr ]]; then
    secs=$(alerts::_seconds_from_age "$hdr")
    [[ -n $secs ]] && { printf '%d' "$secs"; return 0; }
  fi
  local default=${GDAY_ALERTS_MAX_AGE:-26h}
  secs=$(alerts::_seconds_from_age "$default")
  if [[ -n $secs ]]; then
    printf '%d' "$secs"
  else
    printf 'gday: warning: invalid GDAY_ALERTS_MAX_AGE=%q; using 26h\n' "$default" >&2
    printf '%d' $(( 26 * 3600 ))
  fi
}

# alerts::_file_age_seconds <file> — age of the file's `@ generated` header
# (mtime fallback per §3 — "this can never be a hard failure"), in seconds.
alerts::_file_age_seconds() {
  local file=$1 hdr now gen_epoch=''
  now=$(date +%s 2>/dev/null) || return 1
  hdr=$(alerts::_header "$file" generated)
  [[ -n $hdr ]] && gen_epoch=$(date -d "$hdr" +%s 2>/dev/null || true)
  if [[ -z $gen_epoch ]]; then
    gen_epoch=$(stat -c %Y -- "$file" 2>/dev/null) || return 1
  fi
  printf '%d' $(( now - gen_epoch ))
}

# alerts::_generated_display <file> <age> — "YYYY-MM-DD HH:MM" for the
# staleness line, from the `@ generated` header if parseable, else derived
# from mtime via <age>.
alerts::_generated_display() {
  local file=$1 age=$2 hdr now
  hdr=$(alerts::_header "$file" generated)
  if [[ -n $hdr ]]; then
    date -d "$hdr" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0
  fi
  now=$(date +%s 2>/dev/null) || { printf 'unknown date'; return 0; }
  date -d "@$(( now - age ))" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'unknown date'
}

# status::alerts — render STATUS's alerts rows. All FAIL rows before all
# WARN rows; producers in filename order; records in file order within a
# producer (§4.2). Three-way fresh/stale/never-reported distinction (§4.3)
# is the part that matters: a producer that stopped running MUST NOT look
# like a producer with nothing to report.
status::alerts() {
  local dir
  dir=$(alerts::_dir)
  [[ -n $dir ]] || return 0
  status::_plugin_safe "$dir" || return 0

  local max_rows=${GDAY_ALERTS_MAX_ROWS:-8}
  [[ $max_rows =~ ^[0-9]+$ ]] || max_rows=8

  shopt -s nullglob
  local files=("$dir"/*.alerts)
  shopt -u nullglob

  local fail_out warn_out trunc_out
  fail_out=$(mktemp) || return 0
  warn_out=$(mktemp) || { rm -f "$fail_out"; return 0; }
  trunc_out=$(mktemp) || { rm -f "$fail_out" "$warn_out"; return 0; }

  local seen=' ' f
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    local base display
    base=$(basename -- "$f" .alerts)
    seen="${seen}${base} "

    if ! status::_plugin_safe "$f"; then
      # §4.1/§4.3: silent for an undeclared producer — gday has no
      # expectation to disappoint. A declared producer's tampered/mis-chmod'd
      # file MUST NOT look like a healthy one, so it gets a line — with the
      # reason on stderr, never in the banner (one more free-text surface on
      # a phishing target).
      if alerts::_is_expected "$base"; then
        render::status "$GDAY_WARN" "${base}: report file unusable"
        printf 'gday: warning: alerts file rejected (ownership/permissions): %s\n' "$f" >&2
      fi
      continue
    fi

    display=$(alerts::_header "$f" source)
    display=${display:-$base}

    local age
    age=$(alerts::_file_age_seconds "$f") || continue   # unreadable; skip quietly

    local max_age
    max_age=$(alerts::_max_age_for_file "$f")

    if (( age > max_age )); then
      local when
      when=$(alerts::_generated_display "$f" "$age")
      render::status "$GDAY_WARN" "${display}: no report since ${when}"
      continue   # §4.3: expired records are suppressed, not shown
    fi

    # Fresh file: collect this producer's valid records in file order,
    # capped at max_rows (§4.4 — a runaway producer must not be able to push
    # the banner to 200 lines).
    local recs=() n=0 dropped=0 last_docref=''
    local sev label msg docref
    while IFS=$'\t' read -r sev label msg docref || [[ -n $sev ]]; do
      [[ -z $sev || $sev == '#'* || $sev == '@'* ]] && continue
      case $sev in FAIL|WARN) ;; *) continue ;; esac        # closed set (§3)
      [[ -n $label && -n $msg ]] || continue                # malformed row: drop it only (§5)
      if (( n < max_rows )); then
        recs+=("${sev}"$'\t'"${label}"$'\t'"${msg}"$'\t'"${docref:-}")
        last_docref=${docref:-}
        (( n++ ))
      else
        (( dropped++ ))
      fi
    done < "$f"

    local r rsev rlabel rmsg rdocref
    for r in "${recs[@]}"; do
      IFS=$'\t' read -r rsev rlabel rmsg rdocref <<< "$r"
      if [[ $rsev == FAIL ]]; then
        printf '%s\t%s\t%s\n' "$rlabel" "$rmsg" "$rdocref" >> "$fail_out"
      else
        printf '%s\t%s\t%s\n' "$rlabel" "$rmsg" "$rdocref" >> "$warn_out"
      fi
    done

    if (( dropped > 0 )); then
      local pointer=${last_docref:-$display}
      printf '… and %d more → %s\n' "$dropped" "$pointer" >> "$trunc_out"
    fi
  done

  # Declared producers we never found a file for at all (§4.3).
  local want
  for want in ${GDAY_ALERTS_EXPECT:-}; do
    case $seen in *" $want "*) continue ;; esac
    render::status "$GDAY_WARN" "${want}: no report file"
  done

  # Render order: all FAIL, then all WARN, then truncation notices.
  local rlabel rmsg rdocref line
  if [[ -s $fail_out ]]; then
    while IFS=$'\t' read -r rlabel rmsg rdocref; do
      render::status "$GDAY_FAULT" "${rlabel}: ${rmsg}"
      [[ -n $rdocref ]] && render::cont "→ ${rdocref}"
    done < "$fail_out"
  fi
  if [[ -s $warn_out ]]; then
    while IFS=$'\t' read -r rlabel rmsg rdocref; do
      render::status "$GDAY_WARN" "${rlabel}: ${rmsg}"
      [[ -n $rdocref ]] && render::cont "→ ${rdocref}"
    done < "$warn_out"
  fi
  if [[ -s $trunc_out ]]; then
    while IFS= read -r line; do
      render::cont "$line"
    done < "$trunc_out"
  fi

  rm -f "$fail_out" "$warn_out" "$trunc_out"
}
