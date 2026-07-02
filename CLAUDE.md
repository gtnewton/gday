# g'day — login MOTD generator

A portable, dependency-light login banner for Linux. A timer regenerates a
static `/etc/motd`; pam_motd displays it at every login (SSH and console) with
no per-login work and no shell-specific hooks.

Branding name is **g'day** (smart apostrophe ’). Everything in the filesystem —
binary, paths, systemd units, config — uses **`gday`**, because systemd unit
names and sane command names cannot contain a multibyte apostrophe.

---

## 1. Design philosophy

**Primary goal: reliability.** g'day MUST keep producing a useful MOTD despite
missing tools, permission restrictions, unsupported distributions, or
individual probe failures. When a trade-off arises, prefer **correctness,
portability, and graceful degradation over completeness or visual polish.** A
half-populated banner is a success; an error in place of the banner is a
failure.

## 2. Locked design decisions

Settled. Do not relitigate during the build.

1. **Delivery = regenerate `/etc/motd` on a timer**, displayed by universal
   pam_motd. No `update-motd.d` script, no `profile.d` shim. This avoids the
   profile.d/`scp` corruption footgun and works identically on Debian, Fedora,
   Arch, openSUSE.
2. **Tiered caches** (§6) so the timer does not re-probe `dmidecode` or the
   package manager on every fire.
3. **Caches are pre-rendered UTF-8 text**, one file per section — not JSON/TSV.
   See §7 for the rationale; it is a deliberate anti-dependency choice.
4. **Host-specific extras are plugins** in `/etc/gday/status.d/`, never core.
5. **Graceful degradation without root** is a first-class requirement (§5).
6. **figlet is a refresh-time optional dependency only**, never required at
   login.
7. **Fixed render width of 80 columns.** The timer has no attached tty, so
   per-login width adaptation is impossible by construction (§9). This is a
   constraint, not a deficiency.
8. **Single document.** Specification and implementation guidance stay in this
   one file. There is one maintainer and one build agent; splitting invites
   desync.

## 3. Consequences of the timer model (read these)

- **Disk usage, uptime, and load are as-of-last-refresh**, not the login
  instant. The footer carries a generation timestamp so the staleness is
  visible and honest.
- **No personalized, per-viewer data in `/etc/motd`.** It is one global file
  regenerated on a timer with no way to know who's about to log in next, so
  g'day MUST NOT claim to show *your* last login the way sshd's
  `PrintLastLog` correctly does per-session at the actual moment of login —
  that would mean showing one stale, five-minutes-old snapshot to whoever
  happens to log in, potentially describing the wrong person's session
  entirely. This does **not** prohibit an honestly-global fact about the
  *system* (e.g. "most recent login on this machine, and who" —
  `os::last_login` in `lib/os.sh`, always naming the account so it can't
  read as "yours"); it
  only prohibits pretending a static, shared file is personalized to the
  reader. See §11 (OS section) for the exact rule this row follows.
- **Debian/Ubuntu install MUST neutralise `update-motd.d`.** pam_motd there
  prefers `/run/motd.dynamic` built from `/etc/update-motd.d/`, which would
  override or duplicate our `/etc/motd`. The installer disables the stock
  dynamic scripts (drop the execute bit; MUST NOT delete) and records the
  change for clean rollback. This is the only surviving per-distro install
  wrinkle.

## 4. Conventions

- Canadian spelling in prose, comments, and docs; not in code identifiers or
  anything an API dictates.
- Dates `YYYY-MM-DD` (ISO 8601), times 24-hour, in output and docs.
- Shell: **bash**, `#!/usr/bin/env bash`, `set -euo pipefail`. Target is
  systemd distros with GNOME/KDE/headless, where bash is always present.
- UTF-8 output; Unicode and emoji are expected.
- Normative keywords **MUST / MUST NOT / SHOULD / SHOULD NOT / MAY** follow
  RFC 2119.

## 5. Error-handling contract (normative)

This is the core reliability guarantee. Implement it deliberately, not as an
emergent property of scattered guards.

- A single probe failure **MUST NOT** abort assembly.
- Each section **MUST** be isolated from every other section. A missing
  command, failed subprocess, permission denial, malformed output, or plugin
  fault **MUST** affect only its own section's output.
- Assembly **MUST** continue and emit the sections that did succeed.
- **This isolation applies to the static/updates tier *builds*, not just the
  assemble/read path.** A failure in one static-tier step (e.g.
  `gday::packages_build`) MUST NOT prevent the *other* caches
  (banner/hardware/etc.) from being (re)written — every step in
  `gday::build_static`/`gday::build_updates` MUST go through `gday::_emit` (or
  equivalent), exactly like `gday::assemble` already does for its sections.
  Concretely worse than a one-off render glitch: a silently-aborted build
  leaves the *cache* stale indefinitely (nothing else refreshes it until the
  next tier fire, if ever), and both `install.sh` and the systemd services
  tolerate a non-zero exit here without surfacing it — this was a real,
  observed bug (fixed 2026-07-02), not a hypothetical.
- Within a section, a failed row **SHOULD** be omitted rather than shown empty
  or with an error string.
- g'day **MUST** exit non-zero only when the *requested operation itself*
  fails — e.g. inability to write `/etc/motd`. Probe failures are not operation
  failures.
- Every external command **MUST** be gated with `command -v` and have its
  failure tolerated.

## 6. Tiered cache + timer model

| Tier | Unit | Cadence | Produces | Root |
|---|---|---|---|---|
| Static | `gday-static.service` | boot + daily | banner, hardware, serials, SMART, full package list + `pkgs.txt` | yes (degrades) |
| Updates | `gday-updates.service` | hourly | pending-update count, reboot-required flag | yes (degrades) |
| Assemble | `gday-refresh.service` | every 5 min | reads caches + live disk/uptime/load/failed-units + runs `status.d` → writes `/etc/motd` | yes |

- Cadences live in the `.timer` units and MUST be overridable via
  `gday.conf`. Static uses `OnBootSec=` plus a daily `OnCalendar=`; refresh uses
  `OnUnitActiveSec=5min`.
- The update tier **MUST NOT** synchronise package databases
  (`apt-get update`, `pacman -Sy`, `dnf makecache`). It reads already-synced
  state only; on Arch a stray `-Sy` invites partial-upgrade breakage.

## 7. Cache format

Caches are **pre-rendered UTF-8 text, one file per section**, in
`/var/lib/gday/`. They are consumed only by g'day, regenerated wholesale by
their tier, and concatenated at assemble time.

Rationale (this is a rejected-alternative note): structured caches (JSON/TSV)
would demand a serialiser plus a renderer per section and JSON parsing in bash —
i.e. a `jq` dependency or hand-rolled fragility — directly against the
minimal-dependency rule, for data with exactly one consumer. Pre-rendered text
is the correct, dependency-free choice. Files MUST be `0644`, root-owned.

## 8. Installed layout

```
/usr/local/bin/gday               # main CLI
/usr/local/lib/gday/              # library, sourced by gday
  detect.sh hardware.sh banner.sh packages.sh disk.sh os.sh status.sh
  updates.sh render.sh
/etc/gday/gday.conf               # config
/etc/gday/status.d/               # user plugins (executable, run as root)
/var/lib/gday/                    # caches: banner.txt hardware.txt packages.txt
                                  #         pkgs.txt updates.txt smart.txt
                                  # install state: install-rollback.txt,
                                  #         motd.orig (both consumed/removed
                                  #         by uninstall.sh — see §20)
/etc/systemd/system/gday-*.{service,timer}
/etc/motd                         # assembled output (overwritten each refresh)
```

## 9. Output formatting (pinned)

Presentation is fixed so the implementation cannot drift.

- **Target width: 80 columns.** Content MUST fit; rules span the full width.
  No per-terminal adaptation (timer has no tty).
- **Section order (fixed):** banner → HARDWARE → DISK USAGE → OPERATING
  SYSTEM → STATUS → EXPLICITLY INSTALLED → footer.
- **Section headers:** one space, emoji, two spaces, upper-case label, one
  space, then a box-drawing rule (`─`) to column 80.
- **Body rows:** three-space indent; label in a fixed-width left column
  (SHOULD be 12 chars), value follows. `render.sh` MUST expose one alignment
  helper that core sections and plugins share.
- **Bars:** filled `█`, empty `░`, caps `▕ ▏`. Width from `gday.conf`
  (default 22 cells).
- **Status glyphs:** ✅ ok, ⚠️ attention, ❌ fault.
- **Footer:** `g'day · generated YYYY-MM-DD HH:MM` (smart apostrophe is fine in
  text).
- Long values (e.g. package list) MUST wrap within the indent, not overflow.

## 10. Detection layer (`lib/detect.sh`)

Resolve once, export, reuse.

- **Distro / arch:** parse `/etc/os-release` (`ID`, `ID_LIKE`, `PRETTY_NAME`,
  `VERSION_ID`; absent `VERSION_ID` ⇒ rolling). `uname -m` for arch.
- **Package manager:** map from `ID`/`ID_LIKE`; fall back to `command -v`
  probing `apt-get dnf pacman zypper`.
- **Privilege:** root vs not; gates the privileged probes.
- **Desktop + session:**
  - Installed DE + version: `gnome-shell --version`, `plasmashell --version`.
  - Seat0 session type: locate the seat0 graphical session via `loginctl`,
    then `loginctl show-session <id> -p Type` → `wayland` / `x11`. *(Exact —
    portability-critical.)*
  - No DE binary and no active display-manager ⇒ **headless**: omit the
    Desktop line.
  - Output wording MUST make clear this is the *installed* DE and the *local*
    seat's session, not the SSH session.

## 11. Per-section spec

Commands are given exactly **only where portability or correctness depends on
it**; elsewhere the behaviour is specified and the implementation MAY choose
the invocation.

### Banner (static)
Render at static-refresh into `banner.txt` from `hostname -s`. Use
`figlet -f standard` if figlet or toilet is present; otherwise a plain bordered
hostname fallback. Subtitle: `<host> · <PRETTY_NAME> · <DE+version · session>`
(drop DE clause if headless).

### Hardware (`lib/hardware.sh`, static) — privileged fields degrade
Exact keys are load-bearing for cross-distro consistency:

| Row | Source (exact) | Notes |
|---|---|---|
| System | `dmidecode -t system` | Manufacturer, Product Name, Version (→ "rev"), Serial Number |
| Mainboard | `dmidecode -t baseboard` | Manufacturer, Product Name, Version (rev for component lookup) |
| CPU | `lscpu` | Model name; cores/threads as `4C / 8T` |
| Memory | `/proc/meminfo` total; `dmidecode -t memory` per-DIMM | total always available; DIMM detail root-only |
| GPU | `lspci` VGA/3D/Display class | MAY be multiple |
| Storage | `lsblk -d -e7 -o NAME,MODEL,SERIAL,SIZE,TYPE`, keep `TYPE=disk` | serials via sysfs; SMART via `smartctl -H` per device (root) |

No root ⇒ omit serials, per-DIMM detail, SMART; print the unprivileged subset
plus one advisory line that running the static tier as root enables serial
numbers and SMART.

### Disk usage (`lib/disk.sh`, assemble — live)
Report one row per real mount; **exclude** pseudo filesystems (tmpfs, devtmpfs,
squashfs, overlay, loop-backed) and de-duplicate by source device. Render the
bar per §9. Include/exclude globs and bar width come from config. *(Behaviour
specified; the `df` invocation is the implementation's choice.)*

### OS (`lib/os.sh`)
Distro `PRETTY_NAME` + rolling/version, arch; kernel `uname -r`; Desktop line
from §10; uptime from `/proc/uptime` as `Nd HH:MM`; boot time derived from it.
*(Date/time formatting is the implementation's choice, subject to §4.)*

Last login: most recent login on the machine, system-wide — from `last`,
never personalized to the viewer (§3). Always names the account
(`<user> from <host> · <date> <time>`, or `<user> · <date> <time>` for a
local/console login with no host) so it cannot read as "your" login.

### Status (`lib/status.sh`, assemble)
Core glyph-flagged lines:
- **Updates** — count from `updates.txt`. Per-PM (exact — correctness):
  - apt: simulate upgrade and count `^Inst`, or `/usr/lib/update-notifier/apt-check`.
  - dnf: `dnf -q check-update` (exit 100 = updates); count lines.
  - pacman: `checkupdates` (pacman-contrib; temp db — safe). Absent ⇒ skip,
    never `-Sy`.
  - zypper: `zypper -q list-updates` count.
- **Reboot required** — Debian `/run/reboot-required`; Fedora
  `dnf needs-restarting -r` (exit 1); generic fallback: running kernel ≠ newest
  installed.
- **Services** — `systemctl --failed --no-legend | wc -l`.
- **Disks** — summarise SMART results cached by the static tier.

### Packages (`lib/packages.sh`, static)
Full list → `pkgs.txt`; inline shows count + first N alphabetical (N from
config) + pointer to the file. PM-only — snap/flatpak/pipx/cargo/npm are out of
scope for v1. Queries are exact (correctness):

| PM | Explicit query | Baseline strip |
|---|---|---|
| apt | `apt-mark showmanual` | **required** — subtract dep-closure of seed metapackages (`ubuntu-minimal`, `ubuntu-standard`, `ubuntu-desktop-minimal`/`-desktop`) or the list is 200+ |
| dnf | `dnf repoquery --userinstalled --qf '%{name}'` | already excludes deps; MAY drop `@core` |
| pacman | `pacman -Qqe` | subtract `pacman -Qqg base base-devel` |
| zypper | `zypper se -i -t package`, keep `i+` rows | `i+` already = user-installed |

## 12. Plugin contract (`/etc/gday/status.d/`)

Run by `gday-refresh` (inherit root), output appended to STATUS.

- Executable; numbered filename sets order (`10-backup`, `20-snapraid`).
- Print `label  value` line(s) to stdout, aligned via the §9 helper.
- Exit non-zero or print nothing ⇒ silently skipped (per §5).
- MUST be fast: runs every refresh. A slow `docker ps` taxes every 5 min.
- Ship inert `*.sh.example` plugins for restic/SnapRAID/Docker.
- A plugin file (and the `status.d` directory itself) MUST be owned by root or
  the invoking user, and MUST NOT be group/other-writable, or it is silently
  skipped — plugins execute with this process's privileges (root, under the
  shipped systemd service), so this is the same discipline sudoers.d applies
  to its drop-ins (§17).

## 13. Configuration (`/etc/gday/gday.conf`)

Shell-sourced `KEY=value`. **Precedence: compiled defaults < `gday.conf` < CLI
options.** An invalid value MUST warn (journal/stderr) and fall back to the
default; it MUST NOT abort (consistent with §1). Keys at minimum: enabled
sections, disk include/exclude globs, bar width, package inline cap N,
cadences, emoji/accent toggle.

## 14. Logging

- systemd services log to the **journal**; the CLI logs to **stderr**.
- **Silent on success.** Normal operation produces no chatter.
- Degraded probes MAY emit a single journal line at info level; failures that
  drop a section SHOULD be logged. No logfile, no verbosity ladder.

## 15. Graceful degradation (concrete rules)

- Missing probe tool ⇒ omit its row.
- Not root in static/updates tier ⇒ privileged fields omitted + one advisory
  line; the rest renders.
- Headless ⇒ omit Desktop line.
- figlet/toilet absent ⇒ fallback banner.
- A failing `status.d` plugin never breaks assembly.

## 16. Shell coding standards

SHOULD be shellcheck-clean. MUST: quote all expansions; use `local`; use
functions with single responsibilities; `readarray`/`mapfile` for line lists;
avoid parsing `ls`; avoid needless subshells. MUST NOT use `eval`.

## 17. Security requirements

- Caches and `/etc/motd`: `0644`, root-owned. No world-writable files.
- Temp files via `mktemp` (no predictable names); clean up on exit.
- Treat all external output (`dmidecode`, `os-release`, `lsblk`, plugin stdout)
  as **data, never code** — no command substitution of probe output into an
  executed context, no unquoted expansions of it.
- This applies to terminal injection too, not just shell injection: `/etc/motd`
  is displayed by whatever terminal the user's login lands in, so any value
  derived from external probes or plugin output MUST have raw control bytes
  (ANSI/terminal escape sequences) stripped before it reaches a render helper
  — see `render::sanitize` in `lib/render.sh`. A crafted USB device's `lsblk`
  MODEL string is a realistic no-root attack vector here.
- Validate externally supplied paths from config before use.

## 18. Performance (principles, not SLAs)

- The assemble tier SHOULD be cheap — it runs every 5 min; expensive work
  belongs in the static tier.
- No network access in any tier.
- No repeated expensive probes within a run; resolve once, reuse.
- (No fixed millisecond targets — unmeasurable on unknown hardware.)

Rejected-alternative note: detecting whether a running Docker container has
an image update available was considered for the Docker status plugin and
declined — not deferred, declined. The only way to know if a *newer* image
exists upstream is a registry query (`docker manifest inspect` or equivalent),
which is exactly the network access this rule forbids. A no-network variant
is possible — compare a container's actual image ID against what its tag
currently resolves to locally, the same trick `status::reboot`'s generic
fallback already uses for kernels — but that only catches "already pulled,
not yet applied," not a genuinely new upstream release, and was judged not
useful enough on its own to add. If this is proposed again: the network
version conflicts with this rule; the no-network version is buildable but was
a deliberate no.

## 19. CLI surface

- `gday` — print assembled output to stdout (test/preview; does not write
  `/etc/motd`).
- `gday --refresh` — full rebuild now (static tier + updates tier), write
  `/etc/motd`.
- `gday --static` — rebuild static tier now.
- `gday --updates` — rebuild updates tier (pending-update count, reboot flag)
  now.
- `gday --write-motd` — assemble from existing caches + live probes and write
  `/etc/motd`, without rebuilding either cache tier. Used by
  `gday-refresh.service`.
- `gday --section <banner|hardware|disk|os|status|packages>` — emit one
  section to stdout. Primary debug and test affordance.
- `gday --version`.
- `gday -h` / `gday --help`.

## 20. Installer / uninstaller

- **Idempotent:** re-running install MUST converge to the current config, not
  duplicate or leave stale state. This includes negative convergence: a
  cadence override (`GDAY_*_ONCALENDAR`/`INTERVAL`) removed from `gday.conf`
  MUST cause install.sh to remove the corresponding `.timer.d/cadence.conf`
  drop-in, not just skip creating a new one — otherwise a reverted config
  value silently has no effect.
- **Rollback state recorded** (the Debian `update-motd.d` change; the
  pre-existing `/etc/motd`, if any, backed up to `$GDAY_VAR/motd.orig` before
  first being overwritten) so uninstall restores the prior state — re-enable
  the stock scripts, restore original `/etc/motd` content (or blank it if
  there was none), remove units and reload systemd.
- **Rollback records MUST be consumed, not left behind.** Once uninstall.sh
  has restored a script's exec bit from `install-rollback.txt`, it MUST clear
  that record — otherwise a later reinstall's "already handled" idempotency
  check is fooled by the stale entry and skips re-neutralising a script that
  is, in fact, executable again, silently defeating §3 on Debian/Ubuntu.
- Installed files MUST have explicit ownership and permissions (root-owned;
  caches `0644`; plugins/executables `0755`; config `0644`) — this includes
  directories, not just files: MUST NOT rely on umask for any directory that
  ends up holding root-executed content (`/etc/gday`, `status.d`, timer
  drop-in dirs).
- No upgrade-migration machinery in v1 (nothing to migrate).

## 21. Build order

Front-load rendering so layout problems surface immediately.

1. `lib/detect.sh` — distro, PM, DE/session, privilege.
2. `lib/render.sh` — rendering framework (headers, rules, alignment helper,
   bars, width discipline) against stub data.
3. **One complete section end-to-end** (HARDWARE) — probe → cache → assemble →
   `/etc/motd`. Verify the look now.
4. Integrate and confirm rendering across the pipeline.
5. Remaining sections (os, disk, packages, status).
6. systemd units + timers.
7. `install.sh` / `uninstall.sh`, incl. Debian neutralisation + rollback.
8. `status.d` runner + example plugins.
9. `gday.conf`, README, packaging.

Each `lib/*.sh` MUST be runnable standalone (via `gday --section` or direct
sourcing) for smoke tests. Require a smoke test per supported package manager
and a degradation test with optional commands forced absent.

## 22. Open minor questions (decide in-build, non-blocking)

- ANSI colour in addition to emoji, or emoji only? (Config-gated either way.)
- Logged-in user count (as-of-refresh) as a core STATUS line, or a plugin?
- Merge snap/flatpak/pipx/cargo when detected, or strictly PM-only for v1?
