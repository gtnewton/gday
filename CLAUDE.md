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
   login. Since 2026-11-18 it isn't needed for the default banner at all
   (built-in ANSI Shadow renderer, §11).
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
  change for clean rollback.
- **Ubuntu install SHOULD disable `motd-news.timer`, if present and
  active.** Independent of the `update-motd.d` script's execute bit, this
  timer periodically re-fires `motd-news.service` to fetch Canonical's
  promotional MOTD content over the network — redundant with g'day and,
  commonly (no/restricted outbound internet), left permanently failing,
  polluting g'day's own STATUS section with unrelated noise. Only touched
  if currently enabled/active (never assume); recorded for rollback the
  same way as `update-motd.d`, sharing the same rollback file.

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
| Assemble | `gday-refresh.service` | every 5 min | reads caches + live disk/uptime/load/failed-units + runs `status.d` → writes `/etc/motd` (brief or full, §9) + `report.txt` (full) | yes |

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
  detect.sh hardware.sh network.sh banner.sh packages.sh disk.sh os.sh
  status.sh alerts.sh updates.sh render.sh
/etc/gday/gday.conf               # config
/etc/gday/status.d/               # user plugins (executable, run as root)
/etc/gday/banner.txt              # optional: GDAY_BANNER_FILE override art
/var/lib/gday/                    # caches: banner.txt hardware.txt packages.txt
                                  #         pkgs.txt updates.txt smart.txt
                                  # report.txt: full report, refresh tier
                                  #         (what `gday --full` prints)
                                  # install state: install-rollback.txt,
                                  #         motd.orig (both consumed/removed
                                  #         by uninstall.sh — see §20)
/var/lib/gday/alerts.d/           # producer-written *.alerts drop-ins (§11)
/etc/systemd/system/gday-*.{service,timer}
/etc/motd                         # assembled output (overwritten each refresh)
```

## 9. Output formatting (pinned)

Presentation is fixed so the implementation cannot drift.

- **Target width: 80 columns.** Content MUST fit; rules span the full width.
  No per-terminal adaptation (timer has no tty).
- **Section order (fixed):** banner → HARDWARE → NETWORK → DISK USAGE →
  OPERATING SYSTEM → STATUS → EXPLICITLY INSTALLED → footer.
- **Total length budget (full report): ~60 lines.** No section is ever
  truncated to fit — this is a warning threshold, not enforcement.
  `gday::assemble` warns once to stderr (§14) when the full report exceeds
  it — **only when stderr is a terminal** (dev/interactive runs); the
  timer-driven services stay silent. Added when the section count grew past
  four; a login banner long enough to scroll is how motds
  end up `chmod -x`'d by their own users. Raised 45 → 60 on 2026-11-18: after
  NETWORK landed, the default 7-section layout on a real machine is ~55 lines,
  so 45 fired on every 5-min refresh (27 journal lines/day on figue (work)) —
  a warning that always fires is noise and breaks §14's silent-on-success.
- **Section headers:** one space, emoji, two spaces, upper-case label, one
  space, then a box-drawing rule (`─`) to column 80.
- **Body rows:** seven-space indent (`GDAY_INDENT` — deeper than the header
  label at column 5, so contents nest visibly under their title); label in a
  fixed-width left column (SHOULD be 12 chars), value follows at column 20.
  `render.sh` MUST expose one alignment helper that core sections and
  plugins share.
- **Bars:** filled `█`, empty `░`, caps `▕ ▏`. Width from `gday.conf`
  (default 22 cells).
- **Status glyphs:** ✅ ok, ⚠️ attention, ❌ fault.
- **Footer:** `g'day · generated YYYY-MM-DD HH:MM` (smart apostrophe is fine in
  text).
- Long values (e.g. package list) MUST wrap within the indent, not overflow.

### Brief vs full (2026-11-18)

Two views of one collected dataset. `/etc/motd` carries one of them, chosen
by `GDAY_MOTD_STYLE=brief|full` (default **brief**); the refresh tier always
also writes the full report to `$GDAY_VAR/report.txt`, which `gday --full`
prints. A login-time flag is impossible by construction (pam_motd cats a
static file), so the switch is config plus an on-demand command.

- **Full** is the §9 layout above, unchanged.
- **Brief** is a second renderer (`gday::_render_brief`), not a mode threaded
  through the sections: banner art + subtitle; identity rows (`IPv4`
  `<addr> (<iface>)`, `MAC`, `Uptime`, `Logged in` — same labels/helpers as
  the full sections, each omitted if its probe fails); a blank line; then
  only lines needing attention; `✅ All clear` if there are none; footer
  gains `· gday --full for details`. SHOULD stay ≤ ~20 lines.
- **Attention lines:** mounts at or over `GDAY_BRIEF_DISK_PCT` (default 85),
  then STATUS filtered by one rule (`gday::_brief_status_filter`): keep
  ⚠️/❌-led lines (and their `GDAY_EMOJI=0` ASCII forms), the **first** `→`
  pointer line under each, and any `…` overflow line; drop ✅ lines, plain
  rows, further pointers and value-column continuation detail (e.g. failed
  unit names). A producer orders its pointers so the first stands alone. The same rule applies to
  core rows, alerts and `status.d` output (§12).
- Sections are collected **once** per refresh (`gday::_collect`) and both
  views render from that, so plugins/systemctl/alerts run once and the two
  views cannot disagree.
- `gday --full` prints the saved report rather than re-probing: plugins and
  SMART ran as root at refresh, so a non-root live run would show a
  different, poorer report. No report yet ⇒ live full assemble. Everything
  in it was already world-readable in the full `/etc/motd`.

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
Render at static-refresh into `banner.txt` from `hostname -s`. Framed in
the old upyeros/`00-hcmc` style (Greg, 2026-11-18):

```
================================================================================
<art, centred>
=================== <host> · <PRETTY_NAME> · <DE+version> ======================
```

- Art: the hostname upper-cased in **ANSI Shadow**, the FIGfont the old
  banner used, drawn by a built-in renderer (`banner::_figrender`, awk,
  horizontal fitting) from the shipped `lib/fonts/ansi-shadow.flf` — no
  figlet needed. Byte-oriented so mawk and gawk agree; a test checks it
  against real `figlet` output when figlet is present. The font's author
  is unrecorded (TheDraw-era ANSI art via patorjk's collection); the file
  ships unmodified with its header.
- Order: `GDAY_BANNER_FILE` override → figlet/toilet in `GDAY_FIGLET_FONT`
  **only if that key is set** (explicit opt-in) → ANSI Shadow → figlet
  standard (a name too wide for ANSI Shadow, ≳10 chars) → bordered box.
  Everything but the override is centred by character width.
- Subtitle sits inside the bottom rule; the seat0 session type
  (wayland/x11) is no longer shown there — it stays in OS → Desktop. Drop
  the DE clause if headless. Too long ⇒ truncated with `…`.
  `GDAY_BANNER_SUBTITLE=0` ⇒ a plain `=` rule.

**Override hook**, two knobs, both `gday.conf` keys:
- `GDAY_BANNER_FILE=/etc/gday/banner.txt` — when set and readable, its
  content replaces the figlet/toilet/box art verbatim (unset ⇒ unchanged
  current behaviour). Not centred like figlet output — an operator supplying
  fixed art (e.g. a department logo) owns its own layout. Tabs MUST be
  expanded before `render::sanitize` runs (its control-byte strip range
  includes 0x09, so an un-expanded tab is silently deleted, shifting every
  later character) and lines MUST be truncated to `GDAY_WIDTH`, with the
  total line count capped (20), each clamp logged once to stderr if it fires.
- `GDAY_BANNER_SUBTITLE=0` — suppresses the computed subtitle line (default:
  on). Not optional alongside the first knob: without it, a fixed-logo
  profile cannot drop a subtitle that doesn't fit without patching
  `lib/banner.sh` — the exact fork the hook exists to prevent.

Static-tier cached like the rest of the banner: editing `GDAY_BANNER_FILE`'s
content takes effect at the next `gday --refresh`/`--static` or boot/daily
timer fire, not immediately.

### Hardware (`lib/hardware.sh`, static) — privileged fields degrade
Exact keys are load-bearing for cross-distro consistency:

| Row | Source (exact) | Notes |
|---|---|---|
| System | `dmidecode -t system` | Manufacturer, Product Name, Version (→ "rev"), Serial Number |
| Mainboard | `dmidecode -t baseboard` | Manufacturer, Product Name, Version (rev for component lookup) |
| BIOS | `dmidecode -t 0` | Vendor, Version, Release Date. Added for the server case, not lab parity |
| CPU | `lscpu` | Model name; cores/threads as `4C / 8T` |
| Memory | `/proc/meminfo` total; `dmidecode -t memory` per-DIMM | total always available; DIMM detail root-only, identical DIMMs collapsed to one `Nx <size> <type> @ <speed>` line rather than one line per slot |
| GPU | `lspci` VGA/3D/Display class | MAY be multiple |
| Storage | `lsblk -d -e7 -o NAME,MODEL,SERIAL,SIZE,TYPE`, keep `TYPE=disk` | serials via sysfs (root); rendered inline as `· S/N <serial>` on the same line as model/capacity, not a separate continuation line; SMART via `smartctl -H` per device (root) |

No root ⇒ omit serials, per-DIMM detail, SMART; print the unprivileged subset
plus one advisory line that running the static tier as root enables serial
numbers and SMART.

### Network (`lib/network.sh`, assemble — live)
Link state and IP change without a reboot, and every probe here is a cheap
file read, so unlike hardware/packages this is **never cached** — wired
through `gday::_emit` like disk/os/status, not `gday::_cached`.

Interface resolution, in order:
1. `GDAY_NET_IFACE` config override, if set.
2. The `dev` of the default route with the lowest metric, from
   `ip -4 route show default` (ties keep the route table's own order).
3. Otherwise **omit the entire section** — do not guess. (Deliberately not
   `ls /sys/class/net | awk '! /wl|lo/'`: that concatenates every interface
   name into one variable on any machine with `docker0`/`virbr0`/a bridge.)

| Row | Source (exact) |
|---|---|
| Interface | resolved name + `/sys/class/net/<if>/operstate` |
| Speed/Duplex | `/sys/class/net/<if>/speed` and `/duplex`. Omit on `-1` or a read error — what wireless and most virtual interfaces return |
| IPv4 | `ip -4 addr show dev <if>`, first `inet`, `/prefix` stripped |
| MAC | `/sys/class/net/<if>/address` |

IPv6 is out of scope for v1 (§22).

### Disk usage (`lib/disk.sh`, assemble — live)
Report one row per real mount; **exclude** pseudo filesystems (tmpfs, devtmpfs,
squashfs, overlay, loop-backed) and de-duplicate by source device. Render the
bar per §9. Include/exclude globs and bar width come from config. *(Behaviour
specified; the `df` invocation is the implementation's choice.)*

### OS (`lib/os.sh`)
Distro `PRETTY_NAME` + rolling/version, arch; kernel `uname -r`; Desktop line
from §10; uptime from `/proc/uptime` as `Nd HH:MM`; boot time derived from it.
*(Date/time formatting is the implementation's choice, subject to §4.)*

Logged in: distinct accounts with a logind session of class `user` as of
the refresh (`loginctl list-sessions` + `show-session -p Name -p Class`),
sorted, capped at 5 then `+N more`; `none` if logind answers with no
sessions; row omitted if logind is unavailable. System-wide (§3), not "who
is reading this" — the reader's own just-started session is usually not in
it yet. logind rather than `who`: utmp lists one graphical login twice
(seat0 + its tty) and is absent on distros that dropped it.

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
- **Services** — `systemctl --failed --no-legend | wc -l`. Full report lists
  every failed unit (no cap) then how to dig in: one unit ⇒
  `→ systemctl status <name>`, `→ journalctl -b -u <name>`; several ⇒
  `→ systemctl --failed` first (brief keeps only that line, having dropped
  the names), then the status/journalctl forms with a `<unit>` placeholder
  and a short gloss. `reset-failed` deliberately not suggested — it only
  hides an understood failure until reboot; harmless-failure handling is
  `FEATURE_REQUEST.md`'s job.
- **Disks** — summarise SMART results cached by the static tier.
- **Alerts** — see the dedicated subsection below, rendered between Disks and
  the `status.d` plugins.

#### Alerts (`lib/alerts.sh`, assemble)
A core facility for surfacing actionable problems detected by external
programs gday does not itself run (§18: no network access in any tier, and
the assemble tier must stay cheap — it fires every 5 min). A producer writes
a small text file; gday reads it and renders the non-PASS rows into STATUS
with a pointer to the fix. This is mechanism, not policy — any producer gets
the same affordance with no gday code change. gday MUST NOT run the producer
itself; that is a scheduler's job (e.g. a root `cron.d` entry), because the
data has its own natural period (nightly jobs checked more than once a day
cannot produce a different answer) and because gday owning the producer's
runtime/exit codes/failure modes would collapse the decoupling this design
exists to create.

**Format — `gday-alerts v1`.** One file per producer, `*.alerts`, UTF-8, LF
endings, in `GDAY_ALERTS_DIR` (default `/var/lib/gday/alerts.d`, `0755`
root-owned; files `0644` root-owned). Never JSON — parsing it in bash means a
`jq` dependency (§7's rationale, generalised) and JSON's all-or-nothing
parsing is incompatible with gday's per-row degradation contract (§5): one
producer's unescaped quote must not blank the whole section.

| Line form | Meaning |
|---|---|
| `# ...` | Comment (conventionally the version banner on line 1; not required) |
| `@ key=value` | Header. Unknown keys MUST be ignored, not an error |
| `SEV<TAB>label<TAB>message[<TAB>docref]` | One record |
| empty | Ignored |

Headers, all optional: `source` (default: filename minus `.alerts`; display
text only — see below), `generated` (ISO 8601; default: the file's mtime, so
this can never be a hard failure), `expires` (`NNh`/`NNm`; default
`GDAY_ALERTS_MAX_AGE`, 26h).

Record fields, tab-separated, no literal tabs/newlines within a field:
**severity** — `FAIL` or `WARN`, a closed set; anything else drops that row
only. There is deliberately no `PASS` — producers filter, gday does not.
**label** — short noun phrase (SHOULD be ≤ 20 chars). **message** — one line
(SHOULD be ≤ 50 chars; longer wraps via `render::wrap`). **docref** —
optional free text (path/anchor/runbook section) rendered on a continuation
line as `→ <docref>`; gday does not resolve or validate it, only sanitizes it
like any other probe output (§17).

Render order: all `FAIL` rows before all `WARN` rows; producers in filename
order; records in file order within a producer.

**Staleness and silence — the part that matters.** A producer that stopped
running MUST NOT look like a producer with nothing to report:

| State | Output |
|---|---|
| Fresh file, zero records | nothing (producer ran, all clear) |
| Fresh file, N records | the N rows |
| File older than `expires` | `⚠️ <source>: no report since <date>` — records **not** shown |
| Declared producer, no file at all | `⚠️ <source>: no report file` |
| Declared producer, file rejected (ownership/mode — see below) or unreadable | `⚠️ <source>: report file unusable` — records **not** shown |

"Declared" means named in `GDAY_ALERTS_EXPECT` (space-separated source
names; empty default ⇒ no expectations, no warnings) — matched against the
file's **basename**, since the `@ source=` header is display text only, not
identity, so a rejected file (whose content gday refuses to trust) can still
be recognised as a declared producer from its filename alone. **Undeclared**
producers' rejected files are skipped silently — gday has no expectation to
disappoint, and warning about every stray file in a drop-in directory would
be noise. The rejected-file line MUST NOT name the reason (mode/owner/
unreadable) — that detail goes to stderr at the assemble tier only; the
banner reader cannot act on it and it is one more free-text surface on a
phishing target (`/etc/motd` is exactly that).

Files get the same ownership/mode discipline as `status.d` plugins —
`status::_plugin_safe` (§12) is reused unchanged, not reimplemented: owned by
root or the invoking user, never group/other-writable.

`GDAY_ALERTS_MAX_ROWS` (default 8) caps rows shown **per producer**; beyond
it, `… and N more → <docref of the last shown row, or the source name>`. A
runaway producer MUST NOT be able to push the banner to 200 lines.

Config keys (`gday.conf`): `GDAY_ALERTS_DIR` (an externally supplied path,
§17 — MUST be validated absolute; a merely-nonexistent directory is a normal
silent state, not a config error), `GDAY_ALERTS_MAX_AGE`, `GDAY_ALERTS_MAX_ROWS`,
`GDAY_ALERTS_EXPECT`.

### Packages (`lib/packages.sh`, static)
Full list → `pkgs.txt`; the rendered row is a count (thousands-separated) and
a `→ cat <pkgs.txt path>` pointer — **not** the package names themselves.
Earlier versions inlined the first N alphabetically, but on any real machine
(hundreds of packages) that wrapped across several lines, which is exactly
the "long enough to scroll" case the §9 length budget exists to catch; a
count + pointer is one line regardless of list size. PM-only —
snap/flatpak/pipx/cargo/npm are out of scope for v1. Queries are exact
(correctness):

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
- **Brief/full:** only lines led by ⚠️ or ❌ (the `render::status` form) —
  plus the first `→` pointer line under each, and `…` lines — appear in the
  brief banner (§9); order pointers so the first makes sense on its own;
  plain rows are full-report-only. Report routine facts as rows and
  problems as glyph lines; no other brief-awareness is needed.
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
sections, banner override file + subtitle toggle, network interface override,
disk include/exclude globs, bar width, alerts
directory/max-age/max-rows/expect, cadences, emoji/accent toggle,
`GDAY_MOTD_STYLE` (brief|full), `GDAY_BRIEF_DISK_PCT`. (`GDAY_MOTD` is the
motd *path* — an environment override used by tests, not a style key.)

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
- No default route and no `GDAY_NET_IFACE` override ⇒ omit the whole NETWORK
  section, not a header with nothing under it.
- Absent or empty `alerts.d` ⇒ silent (most machines never run a producer).
- A failing `status.d` plugin never breaks assembly.

## 16. Shell coding standards

SHOULD be shellcheck-clean. MUST: quote all expansions; use `local`; use
functions with single responsibilities; `readarray`/`mapfile` for line lists;
avoid parsing `ls`; avoid needless subshells. MUST NOT use `eval`.

**A bare `TEST && ACTION` (or `(( expr ))`) as a function's last statement,
called as a plain command, MUST NOT be used when `TEST`/`expr` can
legitimately be false/zero** — found 2026-09-18 as a real, install-killing
bug (`install.sh`'s `_cadence_clear`). shellcheck does not catch this.
Concretely: `f() { [[ -e $1 ]] && rm -f "$1"; }` called as bare `f "$x"`
propagates the test's false exit status as `f`'s own exit status, which
`set -e` treats as a failure at the call site — even though the *identical*
pattern written inline (not inside a function) is exempt, and even though
`f "$x" || true` or `if f "$x"; then` at the call site would also be fine.
This fired on every default `gday.conf` (no cadence override is the normal
case), silently, before any cache file was ever written — no error visible
short of `bash -x`. Use `if TEST; then ACTION; fi` inside the function
instead; do not rely on how the function happens to be called elsewhere.

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

- `gday` — preview `/etc/motd` live: assemble in `GDAY_MOTD_STYLE` (default
  brief) to stdout; does not write `/etc/motd`. For a live full view:
  `GDAY_MOTD_STYLE=full gday` (absent a `gday.conf` setting, which wins).
- `gday --full` — print the full report saved at the last refresh
  (`report.txt`); live full assemble if none exists yet.
- `gday --brief` — assemble the brief view live, regardless of style.
- `gday --refresh` — full rebuild now (static tier + updates tier), write
  `/etc/motd`.
- `gday --static` — rebuild static tier now.
- `gday --updates` — rebuild updates tier (pending-update count, reboot flag)
  now.
- `gday --write-motd` — assemble from existing caches + live probes; write
  `/etc/motd` (per `GDAY_MOTD_STYLE`) and `report.txt` (full), without
  rebuilding either cache tier. Used by `gday-refresh.service`. Only a
  failed `/etc/motd` write is an operation failure; a failed `report.txt`
  write warns.
- `gday --section <banner|hardware|network|disk|os|status|packages>` — emit
  one section to stdout. Primary debug and test affordance.
- `gday --version`.
- `gday -h` / `gday --help`.

## 20. Installer / uninstaller

- **Idempotent:** re-running install MUST converge to the current config, not
  duplicate or leave stale state. This includes negative convergence: a
  cadence override (`GDAY_*_ONCALENDAR`/`INTERVAL`) removed from `gday.conf`
  MUST cause install.sh to remove the corresponding `.timer.d/cadence.conf`
  drop-in, not just skip creating a new one — otherwise a reverted config
  value silently has no effect.
- **Rollback state recorded** (the Debian `update-motd.d` change; Ubuntu's
  `motd-news.timer` disable; the pre-existing `/etc/motd`, if any, backed up
  to `$GDAY_VAR/motd.orig` before first being overwritten) so uninstall
  restores the prior state — re-enable the stock scripts and the timer,
  restore original `/etc/motd` content (or blank it if there was none),
  remove units and reload systemd.
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
- ~~Logged-in user count as a core STATUS line, or a plugin?~~ Decided
  2026-11-18: core, as a `Logged in` row (names, not a count) in OS and in
  brief's identity rows — see §11 OS.
- Merge snap/flatpak/pipx/cargo when detected, or strictly PM-only for v1?
- IPv6 for the Network section — out of scope for v1; revisit if a real
  machine needs it.

## Project state

This project maintains `STATE.md` at the root. Read it at the start of any
substantive session. Before finishing a session in which you changed code, made
a plan, or learned something that changes what comes next, update `STATE.md`:
revise `next`, `blocked_on`, and `updated`, and prepend a dated `##` entry
describing what changed and what is now outstanding. Keep entries newest-first.
Do not commit `STATE.md` unless asked.
