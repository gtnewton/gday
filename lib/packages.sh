#!/usr/bin/env bash
# packages.sh — EXPLICITLY INSTALLED section (CLAUDE.md §11). Static tier
# writes the full explicit-package list to pkgs.txt; assemble shows just the
# count and a pointer to the file — not the names themselves, which on a
# real machine (hundreds of packages) blew well past a useful line count for
# a login banner. PM-only for v1 (no snap/flatpak/etc).

[[ -n ${GDAY_PACKAGES_SH:-} ]] && return 0
GDAY_PACKAGES_SH=1

# packages::_apt_baseline — names in the dependency closure of the seed
# metapackages, which apt-mark showmanual would otherwise drown the list with.
packages::_apt_baseline() {
  local seed='ubuntu-minimal ubuntu-standard ubuntu-desktop-minimal ubuntu-desktop'
  # apt-cache depends --recurse reads local cache only; never syncs.
  # shellcheck disable=SC2086
  gday::probe apt-baseline apt-cache depends --recurse --installed \
      --no-recommends --no-suggests --no-conflicts --no-breaks \
      --no-replaces --no-enhances $seed \
    | awk '/^[[:alnum:]]/{print $1}'
}

# packages::query — one explicit-package name per line for the detected PM.
packages::query() {
  case ${GDAY_PM:-} in
    apt)
      local manual baseline
      manual=$(gday::probe apt-showmanual apt-mark showmanual)
      baseline=$(packages::_apt_baseline)
      # Subtract the baseline closure (required, or the list is 200+).
      comm -23 <(sort -u <<< "$manual") <(sort -u <<< "$baseline")
      ;;
    dnf)
      gday::probe dnf-userinstalled dnf repoquery --userinstalled --qf '%{name}\n' \
        | grep -v '^@' || true
      ;;
    pacman)
      comm -23 \
        <(gday::probe pacman-qqe pacman -Qqe | sort -u) \
        <(gday::probe pacman-base pacman -Qqg base base-devel | awk '{print $2}' | sort -u)
      ;;
    zypper)
      gday::probe zypper-installed zypper se -i -t package \
        | awk -F'|' '$1 ~ /i\+/ {gsub(/ /,"",$2); print $2}'
      ;;
    *) return 0 ;;
  esac
}

# gday::packages_build — write the sorted, de-duplicated full list to pkgs.txt.
gday::packages_build() {
  mkdir -p "$GDAY_VAR"
  local tmp
  tmp=$(mktemp "${GDAY_VAR}/.pkgs.XXXXXX") || return 1
  packages::query 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" "$GDAY_VAR/pkgs.txt"
}

# packages::_format_count <n> — thousands-separated integer ("1,000").
packages::_format_count() {
  printf '%d' "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

# gday::packages_section — assemble EXPLICITLY INSTALLED from pkgs.txt: a
# count and a pointer to the full list, not the names themselves (§9 length
# budget — hundreds of package names wrapped across several lines is exactly
# the "long enough to scroll" case that budget exists to catch).
gday::packages_section() {
  render::header '📦' 'EXPLICITLY INSTALLED'
  [[ -r $GDAY_VAR/pkgs.txt ]] || return 0
  local total total_fmt
  total=$(grep -c '[^[:space:]]' "$GDAY_VAR/pkgs.txt" || printf 0)
  total_fmt=$(packages::_format_count "$total")
  render::row 'Count' "${total_fmt} package$([[ $total -ne 1 ]] && printf s) manually installed"
  (( total > 0 )) && render::cont "→ cat ${GDAY_VAR}/pkgs.txt"
}
