# ThinkPad T16 Gen 4 — Ubuntu suspend / resume mitigations

Durable writeup of suspend/wake behavior on this laptop, modeled on
`thinkpad-p16-gen3-ubuntu-suspend.md`. The short version: the platform
itself suspends and resumes cleanly — the only observed suspend failure is
the google-drive-ocamlfuse freezer wedge (the P16's failure mode 4), which
this machine reproduces in *two* flavors.

---

## Hardware / OS baseline

**Machine:** Lenovo ThinkPad T16 Gen 4 (`21QN005XUS`), BIOS `R2XET37W` (1.17).

| Component | PCI BDF | Driver | Role |
|-----------|---------|--------|------|
| AMD Krackan APU (Radeon 840M/860M) | `c4:00.0` | `amdgpu` | Only GPU; drives everything |
| MediaTek MT7925 Wi-Fi 7 | `c2:00.0` | `mt7925e` | `wlp194s0` |
| Realtek RTL8168ep | `c3:00.0` | `r8169` | `enp195s0f0` |

**OS at time of writing (2026-07-12):** Ubuntu 26.04 LTS, kernel
`7.0.0-27-generic`, GDM/Wayland.

**Suspend mode:** `s2idle` only (`cat /sys/power/mem_sleep` → `[s2idle]`).

**What does NOT apply here:** every P16 hardware mitigation. No NVIDIA
(no S0ix modprobe options), no i915 (no PSR/DC/power-well kernel params),
no igc (no PTM sleep hook). Across the Jun 25 – Jul 12 boots the journal
shows dozens of s2idle cycles with **zero** display or GPU resume
failures — this platform's suspend is healthy when the freezer succeeds.

---

## Failure mode 1: gdfuse FUSE request blocks the freezer

Same disease as P16 failure mode 4, observed here in two flavors:

**statfs flavor** (boot of Jun 25–29: 8 freeze failures across 49
suspends):
```
kernel: Freezing user space processes failed after 20.0 seconds
  (1 tasks refusing to freeze, wq_busy=0):
kernel: task:pool-59  state:D  ...  fuse_statfs
```

**getattr/read flavor** (2026-07-12, the boot that ended in a forced
power-off):
```
kernel: task:pool-24  state:D  ...
kernel:  fuse_do_getattr -> fuse_update_attributes -> fuse_file_read_iter
systemd-sleep: Failed to freeze unit 'user.slice': Connection timed out
```

Mechanism: `google-drive-ocamlfuse` (stock 0.9.0 deb here) answers FUSE
requests with blocking, retrying network I/O. If the network disappears
while a request is in flight, the calling task waits in uninterruptible
D-state in the kernel FUSE layer; D-state tasks cannot be frozen, so
suspend aborts after the 20 s freezer timeout, retries, and fails forever
until hard power-off.

The 2026-07-12 incident shows it is a **race with unplugging**: yanking
ethernet (Wi-Fi disabled) at 11:10:44 with a Drive read in flight, then
suspending at 11:10:58, wedged the machine — while the identical
unplug-then-suspend sequence the previous evening (23:11) sailed through
because the mount happened to be idle. Any Drive I/O in flight at
freeze time is enough; the frequent `statfs` flavor doesn't even need
that (GNOME's disk-usage poll, `df`, and GTK file choosers call it
constantly).

Note the P16's patched-`statfs` binary would **not** have prevented the
getattr/read flavor — only the `statfs` one. That is why the mitigation
here sits at the suspend layer instead of patching FUSE ops one at a time.

**Probable identity of the in-flight reader:** LocalSearch (GNOME's file
indexer). Ubuntu 26.04 ships `index-recursive-directories ['$HOME']` —
whole-home indexing — and `localsearch info` confirmed files on the
gdfuse mount were "eligible to be indexed"; the miner's journal spam
("GFileInfo created without standard::type") is the signature of crawling
a FUSE mount that serves incomplete GIO metadata. Every observed property
of the stuck task matches (parented by the user manager, GLib `pool-N`
worker thread, content `pread64`), though the process itself couldn't be
identified post-hoc. Mitigated at the source since 2026-07-12: `mnt` is in
LocalSearch's `ignored-directories` (set by `provision`'s journal-hygiene
section; basename glob — absolute paths are not matched), so the indexer
no longer touches the Drive mount at all. The sleep-hook guard below
still covers every other reader.

---

## Mitigation: `gdfuse-suspend-guard` sleep hook

`/usr/lib/systemd/system-sleep/gdfuse-suspend-guard` — maintained in
dev_tools at `suspend/gdfuse-suspend-guard`, installed by `provision` on
all non-WSL machines (it is hardware-independent), and installed manually
on this machine 2026-07-12.

Behavior:
- **pre-sleep:** find every `fuse.google-drive-ocamlfuse` mount in
  `/proc/self/mountinfo`, map it to `/sys/fs/fuse/connections/<minor>/`,
  and poll its `waiting` count (requests sent to the daemon but not yet
  answered). If requests are still unanswered after a short drain window
  (`DRAIN_SECS` in the script), write `1` to the connection's `abort` file: all waiting
  tasks wake immediately with an I/O error and become freezable, so the
  suspend proceeds.
- **post-resume:** lazily unmount the aborted (now dead) mountpoint and
  restart the owning user's `google-drive-ocamlfuse.service`, so the mount
  is back immediately rather than after the unit's `RestartSec=60`.

Trade-off: an aborted request surfaces as one `EIO` to whatever was
touching the mount (an in-flight upload could be lost) — strictly better
than the alternative, which is a hard power-off with the same data loss.
A healthy in-flight transfer is given the drain window to complete first,
so in practice the abort only fires when the daemon is actually wedged.

The deeper fix remains upstream: bounded retries/timeouts in gdfuse's
network layer for *all* operations (the general form of the P16's statfs
patch, upstream issue #896). The guard is worth keeping even then — any
network filesystem can have a request in flight at freeze time.

Verify after a suspend that had Drive I/O wedged:
```bash
journalctl -t gdfuse-suspend-guard
# "aborted FUSE connection NN for /home/pdietl/mnt/GoogleDrive (N unanswered requests ...)"
# "remounted /home/pdietl/mnt/GoogleDrive (restarted google-drive-ocamlfuse.service for pdietl)"
```

---

## Known residuals / open

- **amdgpu `ring gfx_0.0.0 timeout`** — a few per multi-day boot, e.g.:
  ```
  amdgpu 0000:c4:00.0: ring gfx_0.0.0 timeout, signaled seq=..., emitted seq=...
  amdgpu 0000:c4:00.0: Ring gfx_0.0.0 reset succeeded
  amdgpu 0000:c4:00.0: [drm] device wedged, but recovered through reset
  ```
  **Not** suspend-related (they occur hours away from any resume) and every
  occurrence self-recovers via ring reset. App-triggered GPU hangs on
  bleeding-edge Krackan/RDNA3.5 silicon — upstream's problem, don't chase.
- **Lid close without suspend** — on 2026-07-12 the lid was closed at
  02:08 but the machine stayed awake on battery until GNOME's idle path
  finally suspended it at 11:10. Something (an inhibitor?) swallowed the
  lid event; post-hoc journal forensics can't recover which. If it
  recurs, run `systemd-inhibit --list` while the session is up and check
  `HandleLidSwitch` handling before closing the lid.

---

## Diagnostic playbook

```bash
# Boot list — short consecutive boots == forced reboots
journalctl --list-boots | tail -20

# Freeze failures and who refused to freeze (previous boot)
journalctl -b -1 -k | grep -A12 'refusing to freeze' | grep -E 'task:|fuse'

# All suspend/wake cycles this boot
journalctl -b 0 -k | grep -E 'PM: suspend (entry|exit)'

# Guard activity
journalctl -t gdfuse-suspend-guard

# Live check: unanswered FUSE requests on the Drive mount right now
conn=$(awk '$0 ~ /fuse\.google-drive-ocamlfuse/ {split($3,a,":"); print a[2]; exit}' /proc/self/mountinfo)
cat /sys/fs/fuse/connections/$conn/waiting

# amdgpu GPU hangs (expect "recovered through reset"; not suspend-related)
journalctl -b 0 -k | grep -E 'ring gfx.*timeout|device wedged'
```

---

## Investigation chronology (for context)

- **Jun 25–29 2026** — 8 freeze-failure suspends across 49 cycles, all
  `fuse_statfs` (unnoticed at the time; found retroactively).
- **2026-07-12** — quick-unplugged USB hub / HDMI / power / ethernet
  (Wi-Fi disabled) at 11:10:44 with a Drive read in flight; the
  on-battery idle suspend fired 14 s later and every freeze attempt
  failed on `fuse_do_getattr`/`fuse_file_read_iter`. Hard power-off at
  11:13. Root-caused the same day; wrote `gdfuse-suspend-guard`, added
  hardware-gated suspend mitigations to `provision`, and created this doc.
- **2026-07-12 (later)** — while routing journal spam to files
  (`journal-hygiene/`), found LocalSearch recursively indexes all of
  `$HOME` on 26.04 and had the Drive mount in scope — the probable
  in-flight reader above. Excluded `mnt` from its `ignored-directories`.
