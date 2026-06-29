#!/usr/bin/env bash
# disk.sh — DISK USAGE section (CLAUDE.md §11). Assemble tier, live. One row per
# real mount; pseudo filesystems excluded and sources de-duplicated. Bar per §9.

[[ -n ${GDAY_DISK_SH:-} ]] && return 0
GDAY_DISK_SH=1

# Pseudo filesystem types never shown.
readonly GDAY_DISK_PSEUDO_FS='tmpfs devtmpfs squashfs overlay aufs ramfs proc sysfs cgroup cgroup2 devpts mqueue debugfs tracefs fusectl configfs efivarfs autofs binfmt_misc nsfs zram'

# disk::_is_pseudo <fstype> — true if the fstype is a pseudo filesystem.
disk::_is_pseudo() {
  local fs=$1 p
  for p in $GDAY_DISK_PSEUDO_FS; do [[ $fs == "$p" ]] && return 0; done
  return 1
}

# disk::_mount_allowed <target> — false if excluded or not in include list (§13).
disk::_mount_allowed() {
  local target=$1 pat
  if [[ -n ${GDAY_DISK_INCLUDE:-} ]]; then
    for pat in $GDAY_DISK_INCLUDE; do
      # shellcheck disable=SC2254
      [[ $target == $pat ]] && return 0
    done
    return 1
  fi
  if [[ -n ${GDAY_DISK_EXCLUDE:-} ]]; then
    for pat in $GDAY_DISK_EXCLUDE; do
      # shellcheck disable=SC2254
      [[ $target == $pat ]] && return 1
    done
  fi
  return 0
}

# gday::disk_section — assemble DISK USAGE.
# Consumes GNU `df --output`; fields: source fstype size(KiB) used(KiB) pcent target.
gday::disk_section() {
  render::header '💽' 'DISK USAGE'
  local out
  out=$(gday::probe df df --output=source,fstype,size,used,pcent,target)
  [[ -n $out ]] || return 0

  local line src fs size used pcent target seen=' ' bar pct human_used human_size
  local first=1
  while IFS= read -r line; do
    [[ $line == /* || $line == */* ]] || continue   # skip header / blanks
    # shellcheck disable=SC2086
    set -- $line
    [[ $# -ge 6 ]] || continue
    src=$1; fs=$2; size=$3; used=$4; pcent=$5; target=$6
    disk::_is_pseudo "$fs" && continue
    [[ $src == /dev/loop* ]] && continue
    [[ $src == /* ]] || continue                     # real block device only
    case $seen in *" $src "*) continue ;; esac       # de-dupe by source device
    seen="$seen$src "

    disk::_mount_allowed "$target" || continue
    pct=${pcent%\%}
    [[ $pct =~ ^[0-9]+$ ]] || pct=0
    bar=$(render::bar "$pct")
    human_used=$(render::hkib "$used")
    human_size=$(render::hkib "$size")
    render::row "$target" "$(printf '%s %3d%%  %s / %s' "$bar" "$pct" "$human_used" "$human_size")"
    first=0
  done <<< "$out"
  [[ $first -eq 0 ]] || return 0
}
