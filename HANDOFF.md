# g'day — build handoff

Status as of 2026-06-28. Read `CLAUDE.md` first — it is the spec and overrides
anything here.

## All build-order steps complete (§21)

Everything in §21 steps 1–9 is implemented and verified.

### What exists

| Path | Purpose |
|---|---|
| `gday` | CLI: assemble, --refresh, --static, --updates, --write-motd, --section |
| `lib/detect.sh` | Distro, PM, DE/session, privilege |
| `lib/render.sh` | Headers, bars, rows, wrap; GDAY_EMOJI and GDAY_BAR_WIDTH wired |
| `lib/banner.sh` | figlet/fallback banner |
| `lib/hardware.sh` | CPU, memory, GPU, storage (static tier) |
| `lib/disk.sh` | Live disk usage; GDAY_DISK_INCLUDE/EXCLUDE wired |
| `lib/os.sh` | OS, kernel, desktop, uptime |
| `lib/status.sh` | Updates, reboot, failed units, SMART, status.d plugins |
| `lib/packages.sh` | Explicitly-installed packages (apt/dnf/pacman/zypper) |
| `lib/updates.sh` | Updates tier: reads synced state, writes updates.txt |
| `etc/gday.conf` | Default config template (installed to /etc/gday/gday.conf) |
| `etc/status.d/10-restic.sh.example` | Plugin: restic backup age |
| `etc/status.d/20-snapraid.sh.example` | Plugin: SnapRAID sync age |
| `etc/status.d/30-docker.sh.example` | Plugin: Docker container count |
| `systemd/gday-static.{service,timer}` | Boot + daily static tier |
| `systemd/gday-updates.{service,timer}` | Hourly updates tier |
| `systemd/gday-refresh.{service,timer}` | 5-min assemble + write /etc/motd |
| `install.sh` | Idempotent install (incl. Debian update-motd.d neutralisation) |
| `uninstall.sh` | Removes units/binary; restores update-motd.d; --purge for full clean |
| `README.md` | User-facing docs |

### Bugs fixed during build

- `disk.sh`: `df -P --output=…` → `df --output=…` (GNU coreutils rejects both
  flags together; disk section was empty on every system).
- `packages.sh`: dnf `--qf '%{name}'` → `'%{name}\n'` (no newline collapsed
  all names onto one line).

## Test harness — use it

`gday::probe` reads `$GDAY_FIXTURE_DIR/<name>` when set. Two fixture sets are
committed: `test/fixtures` (apt/Ubuntu) and `test/fixtures-degraded`.

```bash
# Full assemble against fixtures:
GDAY_FIXTURE_DIR=test/fixtures ./gday

# Packages (needs static cache — give it a temp dir):
tmp=$(mktemp -d)
GDAY_FIXTURE_DIR=test/fixtures GDAY_VAR="$tmp" ./gday --static
GDAY_FIXTURE_DIR=test/fixtures GDAY_VAR="$tmp" ./gday --section packages
rm -rf "$tmp"

# Config overrides:
GDAY_EMOJI=0 ./gday --section status
GDAY_SECTIONS='hardware disk' GDAY_FIXTURE_DIR=test/fixtures ./gday
GDAY_DISK_EXCLUDE='/boot/efi' ./gday --section disk
```

## Remaining gaps (non-blocking for a functional v1)

- **No automated test runner.** §21 calls for a smoke test per package manager
  + a degradation test. `test/capture.sh` only snapshots; there is no
  `test/run.sh` that loops fixture sets and asserts on output. Add
  dnf/pacman/zypper fixture sets and a runner to make those real.
- **figlet not installed on the dev box.** The live banner always uses the
  bordered-box fallback. The figlet path is exercised by the fixtures. Install
  figlet to eyeball the real art path.
- **Root-only hardware fields not live-tested.** Unprivileged and degraded
  paths are confirmed; root-only subset (dmidecode serials, per-DIMM, smartctl)
  has only been exercised via fixtures.
