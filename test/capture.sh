#!/usr/bin/env bash
# capture.sh — run on a real Linux box (ideally: once as you, once with sudo).
# Snapshots the raw output of every command g'day parses, into a fixture dir,
# and runs the live sections. Hand the resulting tarball back for parser fixes.
#
#   ./test/capture.sh            # unprivileged snapshot
#   sudo ./test/capture.sh       # privileged snapshot (serials, DIMMs, SMART)
#
# It only READS. No package-db sync, no writes outside the output dir.
set -uo pipefail

here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stamp=$(date +%Y%m%d-%H%M%S)
tag=user; [[ ${EUID:-$(id -u)} -eq 0 ]] && tag=root
out="${here}/test/capture-${tag}-${stamp}"
mkdir -p "$out"

# cap <fixture-name> <command...> — capture stdout (and stderr) verbatim.
cap() {
  local name=$1; shift
  command -v "$1" >/dev/null 2>&1 || { echo "  skip ($1 absent): $name"; return 0; }
  "$@" > "${out}/${name}" 2>/dev/null || true
  echo "  cap: $name"
}
copy() { [[ -r $1 ]] && cp -f "$1" "${out}/${2}" && echo "  copy: $2"; }

echo "== capturing real probe output to ${out} =="
copy /etc/os-release os-release
copy /proc/uptime uptime
copy /proc/meminfo meminfo
cap hostname hostname -s
cap uname uname -r

cap lscpu lscpu
cap lspci lspci
cap lsblk lsblk -d -e7 -n -o NAME,MODEL,SERIAL,SIZE,TYPE
cap dmidecode-system   dmidecode -t system
cap dmidecode-baseboard dmidecode -t baseboard
cap dmidecode-memory   dmidecode -t memory

cap df df --output=source,fstype,size,used,pcent,target
cap systemctl-failed systemctl --failed --no-legend

cap gnome-shell gnome-shell --version
cap plasmashell plasmashell --version
cap loginctl-seat0 loginctl show-seat seat0 -p ActiveSession
cap loginctl-sessions loginctl list-sessions --no-legend

# package manager — capture whichever applies
cap apt-showmanual apt-mark showmanual
cap apt-check apt-get -s -o Debug::NoLocking=true upgrade
cap dnf-userinstalled dnf repoquery --userinstalled --qf '%{name}\n'
cap dnf-check-update dnf -q check-update
cap pacman-qqe pacman -Qqe
cap pacman-base pacman -Qqg base base-devel
cap checkupdates checkupdates
cap zypper-installed zypper se -i -t package
cap zypper-updates zypper -q list-updates

# SMART per disk (root only, slow-ish but bounded)
if [[ $tag == root ]] && command -v smartctl >/dev/null 2>&1; then
  while read -r d; do
    [[ -n $d ]] || continue
    smartctl -H "/dev/$d" > "${out}/smartctl-${d}" 2>/dev/null || true
    echo "  cap: smartctl-${d}"
  done < <(lsblk -d -e7 -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
fi

echo
echo "== live g'day sections (using your real machine, no caches) =="
for s in hardware disk os; do
  echo "----- gday --section $s -----"
  "${here}/gday" --section "$s" || echo "(section $s errored)"
  echo
done

tarball="${out}.tar.gz"
tar -czf "$tarball" -C "${here}/test" "$(basename "$out")" 2>/dev/null \
  && echo "== done. send back: ${tarball} =="
