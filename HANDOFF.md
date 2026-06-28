# g'day — build handoff

Status as of 2026-06-28. Read `CLAUDE.md` first — it is the spec and overrides
anything here. This file only records **where the build stands** and **what to do
next**. When a task here is done, update or delete its entry; don't let it
desync from reality (the single-document principle in §2.8 applies to this file
too — keep it short or fold it into git history).

## What is done (build-order §21 steps 1–5)

Implemented, and **verified rendering on real hardware (Fedora 43) and against
the committed fixtures**:

- `lib/detect.sh` — distro, PM, DE/session, privilege.
- `lib/render.sh` — headers, rules, alignment helper, bars, wrap, width
  discipline. Also hosts `gday::probe` (the single probe chokepoint).
- All six sections: banner, hardware, disk, os, status, packages.
- `gday` CLI: no-arg assemble, `--refresh`, `--static`, `--updates`,
  `--section`, `--version`.
- Tiered caches written atomically at 0644 (`gday::_write_cache`), section
  isolation enforced at one chokepoint (`gday::_emit … || true`).

### Two bugs fixed during the 1–5 sign-off (context for reviewers)

- `disk.sh`: `df -P --output=…` is rejected by GNU coreutils (`-P` and
  `--output` are mutually exclusive) → DISK USAGE was empty on every GNU
  system. Now `df --output=…`.
- `packages.sh`: dnf `--qf '%{name}'` had no newline → all names collapsed onto
  one line (`Count` read "1 package", inline list had no separators). Now
  `--qf '%{name}\n'`.

## What is NOT started (do these next, in order)

1. **systemd units + timers (§6).** `gday-static.{service,timer}` (OnBootSec +
   daily OnCalendar), `gday-updates` (hourly), `gday-refresh`
   (OnUnitActiveSec=5min). Cadences MUST be overridable from `gday.conf`.
   Updates tier MUST NOT sync package DBs (no `apt-get update`, `pacman -Sy`,
   `dnf makecache`).
2. **`gday.conf` (§13).** Does not exist yet; many `GDAY_*` vars currently have
   only compiled defaults. Shell-sourced `KEY=value`. Precedence: defaults <
   conf < CLI. Invalid value → warn (journal/stderr) + fall back, MUST NOT
   abort. Keys at minimum: enabled sections, disk include/exclude globs, bar
   width, package inline N, cadences, emoji/accent toggle. Wire these into the
   libs that read the corresponding `GDAY_*` vars.
3. **`install.sh` / `uninstall.sh` (§20).** Idempotent/convergent. Explicit
   ownership + perms (root-owned; caches 0644; executables/plugins 0755; config
   0644). **Debian/Ubuntu: neutralise `/etc/update-motd.d/`** — drop the execute
   bit (MUST NOT delete), record the change for clean rollback; uninstall
   restores it. Lay down files per the §8 installed layout.
4. **`status.d` runner + example plugins (§12).** Runner invoked by
   `gday-refresh`, plugin stdout appended to STATUS via the §9 alignment helper.
   Numbered filenames set order. Non-zero/empty ⇒ silently skipped. Ship inert
   `*.sh.example` for restic / SnapRAID / Docker.
5. **README + packaging (§21 step 9).**

## Test harness — already wired, use it

`gday::probe` (in `lib/render.sh`) reads `$GDAY_FIXTURE_DIR/<name>` when that var
is set, instead of running the real command. Most libs honour it. So you can
replay a whole distro without root or that distro:

```bash
# Ubuntu/apt fixture set, full assemble:
GDAY_FIXTURE_DIR=test/fixtures ./gday

# Single section:
GDAY_FIXTURE_DIR=test/fixtures ./gday --section hardware

# Packages need the static tier to write pkgs.txt; give it a temp cache dir:
tmp=$(mktemp -d)
GDAY_FIXTURE_DIR=test/fixtures GDAY_VAR="$tmp" ./gday --static
GDAY_FIXTURE_DIR=test/fixtures GDAY_VAR="$tmp" ./gday --section packages
```

Fixture sets present: `test/fixtures` (apt/Ubuntu), `test/fixtures-degraded`.
`test/capture.sh` snapshots a real box's probe output into a new fixture dir
(read-only; run once as user, once with sudo).

### Gap worth closing
There is **no automated runner** that loops the fixture sets, runs each section,
and asserts on output — `capture.sh` only snapshots. §21 calls for a smoke test
per package manager + a degradation test. Building that runner (a small
`test/run.sh` driving `GDAY_FIXTURE_DIR`) would make those real. Add dnf/pacman/
zypper fixture sets to exercise each `packages::query` and `updates` branch;
right now only apt fixtures exist (live Fedora covers dnf).

## Notes / watch-outs

- **No git repo here yet.** Consider `git init` before the next batch of work so
  changes are reviewable.
- **figlet/toilet is not installed on the dev box**, so the live banner always
  takes the bordered-box fallback. The figlet art path *is* exercised by the
  fixtures (they carry a `figlet` fixture). Install figlet once to eyeball the
  real art path before sign-off.
- **Run as root to verify privileged hardware fields** (dmidecode serials,
  per-DIMM, smartctl). Unprivileged + degraded paths are confirmed; the
  root-only subset has only been exercised via fixtures so far.
- Coreutils (grep/sed/awk/df/…) are assumed present per §4; only *probe tools*
  need `command -v` gating per §5. Don't over-gate coreutils.
