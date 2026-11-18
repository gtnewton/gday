# g'day

A portable, dependency-light login banner for Linux. A timer regenerates a
static `/etc/motd`; pam_motd displays it at every login (SSH and console) with
no per-login work and no shell-specific hooks.

```
                            _              _       _
                        ___| | ___   _ ___| | __ _| |__
                       / __| |/ / | | / __| |/ _` | '_ \
                       \__ \   <| |_| \__ \ | (_| | |_) |
                       |___/_|\_\\__, |___/_|\__,_|_.__/
                                 |___/

               skylab · Ubuntu 24.04.1 LTS · GNOME 46.2 · wayland

 💻  HARDWARE ──────────────────────────────────────────────────────────────────
   System       Acme Systems Workstation Pro (rev 1.0)
   CPU          AMD Ryzen 7 5800X — 8C / 16T
   Memory       31.3 GiB
                2x 16 GB DDR5 @ 4800 MT/s
   GPU          Intel Corporation UHD Graphics 630
                AMD/ATI Radeon RX 6700 XT
   Storage      nvme0n1: Generic NVMe SSD 1TB (931.5G) · S/N S5GXNX0R123456

 🌐  NETWORK ───────────────────────────────────────────────────────────────────
   Interface    eth0 (up)
   Speed/Duplex 1000 Mb/s (full)
   IPv4         192.168.1.50
   MAC          02:11:22:33:44:55

 💽  DISK USAGE ────────────────────────────────────────────────────────────────
   /            ▕██████████░░░░░░░░░░░░▏  46%  393G / 915G
   /data        ▕███████████░░░░░░░░░░░▏  54%  935G / 1.8T

 🐧  OPERATING SYSTEM ──────────────────────────────────────────────────────────
   OS           Ubuntu 24.04.1 LTS · x86_64
   Kernel       6.8.0-40-generic
   Uptime       10d 01:15

 📊  STATUS ────────────────────────────────────────────────────────────────────
   ✅  System up to date
   ✅  No failed units
   ✅  SMART healthy (2 disks)
   ⚠️  netbootbuild: job not scheduled on this box
                → GUAVA-RUNBOOK.md#netbootbuild

 📦  EXPLICITLY INSTALLED ──────────────────────────────────────────────────────
   Count        355 packages manually installed
                → cat /var/lib/gday/pkgs.txt

────────────────────────────────────────────────────────────────────────────────
g'day · generated 2026-06-28 08:30
```

## How it works

Three systemd timer tiers keep the banner fresh without per-login cost:

| Tier | Cadence | What it does |
|---|---|---|
| Static | boot + daily | Banner art, hardware, full package list |
| Updates | hourly | Pending update count, reboot-required flag |
| Refresh | every 5 min | Reads caches + live network/disk/uptime → writes `/etc/motd` |

The banner is displayed by the system's pam_motd — no shell hooks, no
`profile.d` scripts, works identically over SSH and at the console.

## Requirements

- Linux with systemd and pam_motd
- bash ≥ 4, standard coreutils (grep, awk, sed, df, …), `iproute2` (`ip`)
- Optional: `figlet` or `toilet` for banner art; `dmidecode`, `smartctl`,
  `lspci` for hardware detail (root-only)

No Python, no jq, no package manager dependencies at runtime.

## Install

```bash
sudo ./install.sh
```

Re-running is safe (idempotent). On Debian/Ubuntu, install.sh neutralises the
stock `/etc/update-motd.d/` scripts (drops the execute bit; does not delete
them) so they don't duplicate or override the g'day banner.

## Uninstall

```bash
sudo ./uninstall.sh           # removes binary/units; preserves config + caches
sudo ./uninstall.sh --purge   # also removes /etc/gday and /var/lib/gday
```

Uninstall restores the execute bit on any `update-motd.d` scripts that were
neutralised during install, and restores whatever `/etc/motd` contained before
install.sh first overwrote it (if anything) instead of leaving it blank.

## Configuration

Edit `/etc/gday/gday.conf` — it is shell-sourced `KEY=value`. All keys are
optional; invalid values warn and fall back to defaults.

```bash
# Show only these sections (default: all)
GDAY_SECTIONS='banner hardware network disk os status'

# Replace the figlet/toilet/box banner art with a fixed file's content
# verbatim (e.g. a department logo). Static-tier cached — after editing the
# file, run `gday --refresh` (or `--static`) to pick it up.
GDAY_BANNER_FILE=/etc/gday/banner.txt

# Suppress the computed "<host> · <PRETTY_NAME> · ..." subtitle line
GDAY_BANNER_SUBTITLE=0

# Network interface to report on (default: the default route's device)
GDAY_NET_IFACE=eth0

# Limit disk display to specific mounts
GDAY_DISK_INCLUDE='/ /home /data'

# Or exclude specific mounts
GDAY_DISK_EXCLUDE='/boot/efi'

# Usage bar width in cells (default: 22)
GDAY_BAR_WIDTH=30

# Suppress emoji for terminals that render them poorly
GDAY_EMOJI=0

# Where external health-check producers drop *.alerts files (default shown)
GDAY_ALERTS_DIR=/var/lib/gday/alerts.d

# Age after which a producer's file is stale (default: 26h)
GDAY_ALERTS_MAX_AGE=26h

# Rows shown per producer before "… and N more" (default: 8)
GDAY_ALERTS_MAX_ROWS=8

# Producers that MUST report — missing/stale/rejected each get their own
# warning line instead of silently vanishing (default: none)
GDAY_ALERTS_EXPECT='guava-morning-check'
```

Cadences (static, updates, refresh intervals) live in the systemd `.timer`
units. Change them by editing the units or creating systemd drop-ins
(`/etc/systemd/system/gday-*.timer.d/override.conf`). Re-running `install.sh`
after setting `GDAY_STATIC_ONCALENDAR`, `GDAY_UPDATES_ONCALENDAR`, or
`GDAY_REFRESH_INTERVAL` in `gday.conf` will also apply them as drop-ins — and
removing the setting again and re-running `install.sh` removes the drop-in,
reverting to the shipped default.

## CLI

```
gday                 preview the banner (does not write /etc/motd)
gday --section os    emit one section for debugging (banner|hardware|network|disk|os|status|packages)
gday --refresh       full rebuild + write /etc/motd now
gday --static        rebuild hardware/packages caches now
gday --updates       rebuild update count cache now
gday --write-motd    assemble from existing caches + write /etc/motd (used by gday-refresh.service)
gday --version       print version
gday --help          this help
```

## Status plugins

Drop an executable script into `/etc/gday/status.d/` and it runs every
refresh cycle, with its stdout appended to the STATUS section. Numbered
filenames control order (`10-backup`, `20-snapraid`). A non-zero exit or
empty output is silently skipped — a misbehaving plugin cannot break the banner.

Example plugins (inert until activated) are installed to `/etc/gday/status.d/`:

- `10-restic.sh.example` — last restic backup age
- `20-snapraid.sh.example` — last SnapRAID sync age
- `30-docker.sh.example` — running/stopped container counts, with a name +
  image + status line per container (capped, with a pointer to `docker ps -a`
  once there are more than fit inline)

To activate: copy to the same directory without `.example`, set the execute
bit, and configure the variables at the top of the file.

A plugin (and `status.d` itself) must be owned by root or the invoking user
and not group/other-writable, or it's silently skipped — plugins run with
this process's privileges, so the same discipline `sudoers.d` applies to its
drop-ins applies here.

## Alerts

External health-check scripts (that gday does not run itself — no network
access, no scheduling) can report actionable problems into STATUS by writing
a `*.alerts` file to `/var/lib/gday/alerts.d/`:

```
# gday-alerts v1
@ source=guava-morning-check
@ generated=2026-09-17T13:14:09-07:00
@ expires=26h
FAIL	unattended-upgrades	u-u has never run on this box	GUAVA-RUNBOOK.md#unattended-upgrades
WARN	netbootbuild	job not scheduled on this box	GUAVA-RUNBOOK.md#netbootbuild
```

One producer per file (fields are tab-separated); no `PASS` rows — the
producer filters, gday only renders. A stale file (older than
`GDAY_ALERTS_MAX_AGE`) shows a "no report since" line instead of its
(possibly outdated) records. Naming a producer in `GDAY_ALERTS_EXPECT` makes
its absence, staleness, or rejection each produce a warning line, instead of
a stopped producer silently looking like a healthy one.

Files get the same ownership/mode discipline as `status.d` plugins — owned
by root or the invoking user, never group/other-writable, or they're
rejected (silently, unless declared in `GDAY_ALERTS_EXPECT`).

## Graceful degradation

g'day is designed to always produce a useful banner:

- Missing tools (`dmidecode`, `lspci`, `smartctl`) → those rows are omitted
- Not running as root → privileged fields omitted; an advisory line appears
- figlet/toilet absent → hostname in a plain bordered box
- Headless system (no DE) → Desktop line omitted
- No default route → the NETWORK section is omitted entirely
- Any probe failure → that row omitted; all other sections unaffected

## Layout

Output is fixed at 80 columns. The refresh timer has no attached terminal, so
per-login width adaptation is impossible by design — the fixed width is an
honest constraint, not a deficiency.

## License

MIT
