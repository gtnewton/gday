#!/usr/bin/env bash
# network.sh — NETWORK section (CLAUDE.md §11). Assemble tier, live: link
# state and IP change without a reboot, and every probe here is a cheap file
# read, so unlike hardware/packages this is never cached (§4.2 of
# planning/gday-development-guide.md).

[[ -n ${GDAY_NETWORK_SH:-} ]] && return 0
GDAY_NETWORK_SH=1

# network::_iface — resolve the interface to report on, in order:
#   1. GDAY_NET_IFACE config override, if set.
#   2. The `dev` of the default route with the lowest metric (ties keep the
#      route table's own order) from `ip -4 route show default`.
#   3. Otherwise "" — the caller omits the whole section rather than guess.
#
# Deliberately NOT `ls /sys/class/net | awk '! /wl|lo/'` (00-hcmc's
# approach): that concatenates every interface name into one variable on any
# machine with docker0/virbr0/a bridge.
network::_iface() {
  local iface=${GDAY_NET_IFACE:-}
  if [[ -n $iface ]]; then
    printf '%s' "$iface"
    return 0
  fi

  local out
  out=$(gday::probe ip-route ip -4 route show default)
  [[ -n $out ]] || return 0

  awk '
    {
      dev = ""; metric = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "dev")    dev = $(i + 1)
        if ($i == "metric") metric = $(i + 1) + 0
      }
      if (dev != "") printf "%d\t%s\n", metric, dev
    }
  ' <<< "$out" | sort -t $'\t' -k1,1n | head -n1 | cut -f2
}

# network::_operstate <iface> — "up"/"down"/etc. from sysfs, or "".
network::_operstate() {
  local iface=$1
  gday::read_proc "sys-net-${iface}-operstate" "/sys/class/net/${iface}/operstate"
}

# network::_speed_duplex <iface> — "<mbit> Mb/s (<duplex>)", or "" when the
# link reports -1 or the file can't be read — which is what wireless and
# most virtual interfaces return (correctly omitted, not an error).
network::_speed_duplex() {
  local iface=$1 speed duplex
  speed=$(gday::read_proc "sys-net-${iface}-speed" "/sys/class/net/${iface}/speed")
  [[ $speed =~ ^-?[0-9]+$ ]] || return 0
  (( speed < 0 )) && return 0
  duplex=$(gday::read_proc "sys-net-${iface}-duplex" "/sys/class/net/${iface}/duplex")
  if [[ -n $duplex ]]; then
    printf '%s Mb/s (%s)' "$speed" "$duplex"
  else
    printf '%s Mb/s' "$speed"
  fi
}

# network::_ipv4 <iface> — first `inet` address from `ip -4 addr show dev
# <iface>`, prefix length stripped.
network::_ipv4() {
  local iface=$1 out line addr
  out=$(gday::probe "ip-addr-${iface}" ip -4 addr show dev "$iface")
  [[ -n $out ]] || return 0
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}   # ltrim
    case $line in
      inet\ *)
        addr=${line#inet }
        addr=${addr%% *}
        addr=${addr%/*}
        [[ -n $addr ]] && { printf '%s' "$addr"; return 0; }
        ;;
    esac
  done <<< "$out"
}

# network::_mac <iface> — hardware address from sysfs, or "".
network::_mac() {
  local iface=$1
  gday::read_proc "sys-net-${iface}-address" "/sys/class/net/${iface}/address"
}

# gday::network_section — assemble NETWORK. Omitted entirely (no header) when
# no interface can be resolved — a section with only a header and nothing
# under it would be worse than no section (§5: do not guess).
gday::network_section() {
  local iface
  iface=$(network::_iface)
  [[ -n $iface ]] || return 0

  render::header '🌐' 'NETWORK'

  local state val sd ip mac
  state=$(network::_operstate "$iface")
  val=$iface
  [[ -n $state ]] && val="${val} (${state})"
  render::row 'Interface' "$val"

  sd=$(network::_speed_duplex "$iface")
  [[ -n $sd ]] && render::row 'Speed/Duplex' "$sd"

  ip=$(network::_ipv4 "$iface")
  [[ -n $ip ]] && render::row 'IPv4' "$ip"

  mac=$(network::_mac "$iface")
  [[ -n $mac ]] && render::row 'MAC' "$mac"
}
