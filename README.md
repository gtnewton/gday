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
   System       Dell Inc. XPS 8950 (rev 1.0.5)
   CPU          12th Gen Intel(R) Core(TM) i7-12700K — 8C / 16T
   Memory       31.3 GiB
   GPU          Intel Corporation AlderLake-S GT1 [UHD Graphics 770]
                NVIDIA Corporation GA104 [GeForce RTX 3070]
   Storage      nvme0n1: Samsung SSD 980 PRO 1TB  (931.5G)

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

 📦  EXPLICITLY INSTALLED ──────────────────────────────────────────────────────
   Count        12 packages
   Installed    build-essential, curl, docker-ce, firefox, git, htop …

────────────────────────────────────────────────────────────────────────────────
g'day · generated 2026-06-28 08:30
```

## How it works

Three systemd timer tiers keep the banner fresh without per-login cost:

| Tier | Cadence | What it does |
|---|---|---|
| Static | boot + daily | Banner art, hardware, full package list |
| Updates | hourly | Pending update count, reboot-required flag |
| Refresh | every 5 min | Reads caches + live disk/uptime → writes `/etc/motd` |

The banner is displayed by the system's pam_motd — no shell hooks, no
`profile.d` scripts, works identically over SSH and at the console.

## Requirements

- Linux with systemd and pam_motd
- bash ≥ 4, standard coreutils (grep, awk, sed, df, …)
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
neutralised during install.

## Configuration

Edit `/etc/gday/gday.conf` — it is shell-sourced `KEY=value`. All keys are
optional; invalid values warn and fall back to defaults.

```bash
# Show only these sections (default: all)
GDAY_SECTIONS='banner hardware disk os status'

# Limit disk display to specific mounts
GDAY_DISK_INCLUDE='/ /home /data'

# Or exclude specific mounts
GDAY_DISK_EXCLUDE='/boot/efi'

# Usage bar width in cells (default: 22)
GDAY_BAR_WIDTH=30

# Suppress emoji for terminals that render them poorly
GDAY_EMOJI=0

# Package names shown inline in the MOTD (default: 12)
GDAY_PKG_INLINE_N=8
```

Cadences (static, updates, refresh intervals) live in the systemd `.timer`
units. Change them by editing the units or creating systemd drop-ins
(`/etc/systemd/system/gday-*.timer.d/override.conf`). Re-running `install.sh`
after setting `GDAY_STATIC_ONCALENDAR`, `GDAY_UPDATES_ONCALENDAR`, or
`GDAY_REFRESH_INTERVAL` in `gday.conf` will also apply them as drop-ins.

## CLI

```
gday                 preview the banner (does not write /etc/motd)
gday --section os    emit one section for debugging
gday --refresh       full rebuild + write /etc/motd now
gday --static        rebuild hardware/packages caches now
gday --updates       rebuild update count cache now
```

## Status plugins

Drop an executable script into `/etc/gday/status.d/` and it runs every
refresh cycle, with its stdout appended to the STATUS section. Numbered
filenames control order (`10-backup`, `20-snapraid`). A non-zero exit or
empty output is silently skipped — a misbehaving plugin cannot break the banner.

Example plugins (inert until activated) are installed to `/etc/gday/status.d/`:

- `10-restic.sh.example` — last restic backup age
- `20-snapraid.sh.example` — last SnapRAID sync age
- `30-docker.sh.example` — running container count

To activate: copy to the same directory without `.example`, set the execute
bit, and configure the variables at the top of the file.

## Graceful degradation

g'day is designed to always produce a useful banner:

- Missing tools (`dmidecode`, `lspci`, `smartctl`) → those rows are omitted
- Not running as root → privileged fields omitted; an advisory line appears
- figlet/toilet absent → hostname in a plain bordered box
- Headless system (no DE) → Desktop line omitted
- Any probe failure → that row omitted; all other sections unaffected

## Layout

Output is fixed at 80 columns. The refresh timer has no attached terminal, so
per-login width adaptation is impossible by design — the fixed width is an
honest constraint, not a deficiency.

## License

MIT
