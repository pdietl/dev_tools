# ThinkPad P16 Gen 3 — investigation chronology

How the conclusions in `thinkpad-p16-gen3-ubuntu-suspend.md` were reached,
session by session. **Entries are snapshots, and later entries refute
earlier ones** — the "no eDP MUX" call, kdump's "ready to kdump", and
ramoops as the crash store were all believed true when written and are all
wrong. Nothing here is guaranteed current. The main doc holds present
state; read this file only when you need the provenance of a conclusion,
never as a source of facts to act on.

- **Mar–Apr 2026 (Ubuntu 24.04 era)** — first hit the "screen on, no GUI"
  symptom on this hardware. Original diagnosis via a separate Claude
  chat: the user-visible hang was the NVIDIA legacy-suspend deadlock;
  the IGC PTM spam was a separate cosmetic issue. Fixed with
  `nvidia-s0ix.conf` (problem 2) and the `igc-ptm-workaround` sleep hook
  (problem 1). Both files persisted in the 24.04 install at
  `~/m/etc/modprobe.d/nvidia-s0ix.conf` and
  `~/m/usr/lib/systemd/system-sleep/igc-ptm-workaround`. Kernel was
  6.17.0-1020-oem.
- **May–Jun 2026 (26.04 fresh install)** — same hardware, neither
  workaround carried over. Symptom returned, but logs showed a *different*
  underlying cause: the i915 PHY-idle chain (problem 3a), not the NVIDIA
  freeze. Restored the 24.04-era fixes (nvidia-s0ix.conf,
  igc-ptm-workaround) AND added `i915.enable_psr=0` to grub. Resume
  reliability jumped from "every long suspend hangs" to ~88% clean.
- **Late May / early June 2026** — added `i915.enable_dc=0` to target the
  deeper DC9 path, plus a separate `nvidia-resume-speed.conf` with
  `PreserveVideoMemoryAllocations=0` to shave the 7–10 s baseline. Worst
  outlier dropped from indefinite hang to a 6:27 self-recovered black
  screen.
- **2026-06-20** — new failure mode surfaced: `PHY A failed to request
  refclk` — distinct from any prior PHY-idle message and not addressed by
  the existing mitigations. One occurrence was fatal (forced reboot after
  ~30 s of dark screen). Added `i915.disable_power_well=0`; effectiveness
  pending observation across more multi-day boots.
- **2026-06-24** — the suspend storm returned (97 failed suspends / ~30 min) but
  the logs showed a *new* cause: 2 `pool-*` threads stuck in `fuse_statfs` on the
  `google-drive-ocamlfuse` mount (S0ix=1 was live, so not mode 2). Root-caused to
  the driver's blocking `statfs`→metadata-refresh path (upstream #896); patched
  `statfs` to be non-blocking, built + installed to `/usr/local/bin`, removed the
  deb. See failure mode 4 and its mitigation in the main doc. (Same session:
  redirected tailscaled+Slack journal spam, fixed geoclue/cups-browsed apparmor
  denials, disabled the nvidia-powerd SEGV crash-loop, masked orphaned PCP
  services.)
- **2026-07-18** — the T16's NVMe (the main doc's install) moved into this
  chassis. Installed `nvidia-driver-595-open` + `prime-select nvidia`,
  then flipped BIOS Config → Display → Graphics Device from Hybrid to
  **Discrete** — discovering the eDP MUX the June investigation had
  concluded didn't exist (panel verified on the nvidia DRM card). Fallout:
  a DisplayLink dock head became ~5 s laggy (evdi + NVIDIA-primary CPU
  readback; see Known residuals) and was replaced with a direct HDMI
  connection at native 2560x1440@120. Discrete-mode suspend reliability
  under observation from this date.
- **2026-07-24** — first **reboot** (not suspend) hang: `sudo reboot` with the
  lid closed and two USB-C externals live wedged in the final GPU-teardown
  phase — dark screen, power on, hard power-off. Localized to the dGPU display
  path (all scanout on the nvidia card in Discrete mode); evdi cards cleared as
  phantom; soft hang, no kdump. Aggravated by an unattended-upgrades NVIDIA
  bump (595.71.05 → 595.84) applied earlier that session with no reboot,
  leaving a running-module/userspace split. Mitigation: `system/apt/52nvidia-
  unattended-hold` holds the stack from the automatic path. See the
  "Shutdown / reboot" section of the main doc.
- **2026-07-25** — second hang in two days on the same topology (docked, lid
  closed, two USB-C externals on the dGPU), this time **spontaneous while
  idle** rather than during a lifecycle transition: monitors frozen but lit,
  no suspend afterwards, forced power-off. Ruled out memory/swap/CPU/IO from
  the last `sar` sample, DisplayLink (evdi cards phantom), NVRM API mismatch,
  and thermal; the BERT record present at boot is stale and predates the
  event. Neither candidate trigger — an idle-blank modeset on the USB-C DP
  links, or the NVIDIA VA-API decode path enabled ~3 h earlier — is provable
  from the logs, because the machine stops writing them. Response was to
  instrument rather than guess: kdump panic triggers, iTCO watchdog, ramoops
  and a netconsole stream to pdietl-thinkstation. See "Idle hang" and "Crash
  capture" in the main doc.
- **2026-07-26** — preparing to prove kdump revealed it had never been able to
  work here: `/var/crash` sits on the encrypted ZFS root and the capture
  initrd has no zfs userspace and no cryptsetup, so it could not reach the
  target it reported being ready to write. Removed swap entirely (122 GiB RAM,
  no hibernation) and converted its 8 GiB partition into a plain ext4 dump
  target, with `KDUMP_CMDLINE` booting the capture kernel there rather than at
  rpool — no pool import, no key, no filesystem module. rpool was untouched
  and cannot be shrunk regardless. See "Dump target" in the main doc.
  A deliberate sysrq panic that evening then showed the capture kernel is
  broken independently of its target: it kexec'd, wrote nothing, printed
  nothing and never rebooted. kdump disabled as a result — see "kdump is
  disabled" in the main doc for why leaving it on is actively harmful. The
  watchdog also failed to recover the machine inside 15 minutes at a 600 s
  setting, consistent with the TCO's two-stage timer doubling it; now 120 s.
  The forced power-off invalidated the firmware's memory training, so the
  next POST did a full retrain (several minutes, keyboard LED activity); both
  DIMMs re-detected at full size and speed with no EDAC or BERT entries.
- **2026-07-26 (later)** — panics kept leaving `/sys/fs/pstore` empty even
  with kdump out of the way, and the ramoops region came up valid at the
  same address every boot. Bisected the chain with three cheap experiments
  instead of more crash tests: zone headers survived a clean reboot
  (`ramoops.dyndbg=+p` made the probe verdicts visible); a shutdown-reason
  dump (`max_reason=4` for one reboot) was written, survived POST and was
  archived — proving write path, persistence and readout end to end; then a
  stopwatch on the next sysrq panic showed the machine self-reboot at
  exactly 60 s (`kernel.panic` works; the watchdog was never what reset it)
  while the probe reported every zone `sig = 0x00000000`. Verdict: the
  firmware zeroes DRAM after dirty resets and ramoops can never hold a
  crash record here. Also caught `systemd-pstore` archiving-and-emptying
  the mount within seconds of boot, which had made earlier checks look like
  failures. Replaced ramoops with `efi_pstore` (UEFI NVRAM survives any
  reset), capped `kmsg_bytes` to fit the small variable store. Verified the
  same morning: one more sysrq panic self-rebooted in 60 s and the archive
  held the full Panic record, with the variable store cleaned afterwards.
  Two side findings while eliminating suspects: this kernel builds
  only the dmesg pstore front-end (no console/pmsg/ftrace), and the panic
  notifier chain here is six benign entries — nothing that can hang before
  the dump.
- **2026-08-08** — panel static plus an unusable-laggy desktop after a
  13½ hour suspend and a redock onto HDMI. Traced to the dGPU refusing
  scanout NVKMS allocations, with mutter's front-buffer failures and
  Chrome's BO failures both downstream of it; a matching 2026-07-29
  occurrence turned out to be an *undock*, which is what established the
  trigger as output reconfiguration rather than suspend. Two hypotheses
  formed and killed on the way: that the dGPU had runtime-suspended
  (`Using 41-bit DMA addresses` appearing exactly once in six boots looked
  like an RTD3 resume — refuted by `runtime_suspended_time: 0`, and that
  line remains unexplained, being absent from both the nvidia sources and
  the binary blobs), and that the `-EINVAL` returned to callers ruled out
  exhaustion — refuted by reading the driver, which returns `-EINVAL` for
  every cause including out-of-memory. Left instrumented rather than
  fixed: the underlying reason for the refusal is still unknown, with
  display-bandwidth (IMP) arbitration the leading candidate.
- **2026-08-22** — the machine rebooted itself mid-use. Not a hang: the
  archived record was `Kernel panic - not syncing: hung_task: blocked
  tasks`, a thread blocked 327 s in `fuse_lookup` behind a mutex held by
  `localsearch-3`, which was itself waiting on the gdfuse daemon. First
  firing of the crash-capture stack on an unplanned fault, and the panic
  was the configured response to the stall rather than a fault of its own —
  the machine was idle and healthy on every other axis. Traced to the
  indexer exclusion naming `mnt`, which was correct while the mount lived
  at `~/mnt/GoogleDrive` and had matched nothing since the auto-mount unit
  standardised on `%h/GoogleDrive`. A same-week panic (2026-08-17, `sync`
  blocked in `wb_wait_for_completion`, no FUSE frames) is the same
  mechanism on a different stall and was left unattributed. Two hypotheses
  formed and killed: that the exclusion mechanism itself was broken —
  refuted by the indexer sources, where filters are matched on the basename
  and absolute paths are rejected outright, so the `$HOME/GoogleDrive` form
  that looked like the fix would have been accepted by gsettings and done
  nothing; and that the indexer was still crawling the mount afterwards —
  refuted by stopping the service and watching the Drive traffic continue,
  which attributed it to an open file-manager window and a PDF viewer. Both
  wrong readings came from a predicate narrower than the question (one
  subdirectory grepped for, a startup marker reused across a changed output
  mode), which is also why the gdfuse operation log was added: without a
  record of what the daemon was asked for, attribution was guesswork.
- **2026-09-21** — first severe-form occurrence of the scanout refusal: a
  6 h s2idle resume on lid open left the console text on the panel with a
  live, tracking mouse cursor and no desktop, and it did not clear. Resolved
  the standing "why is it refused" question, and demoted the
  display-bandwidth (IMP) candidate that had led it — the episode had a
  single head attached at a mode that had been driving it minutes earlier.
  Two wrong readings on the way, both quantified and both plausible. First,
  free video memory correlated beautifully: the only three hours in 46 h of
  `sysmon` telemetry with refusals were the only three with free VRAM under
  750 MiB, which reads as exhaustion until you notice a framebuffer is 35 MiB
  and 781 MiB was free. Second, a purpose-written GBM probe reported the
  largest obtainable contiguous allocation as a stable 31 MiB across five
  runs — an artifact of the probe's own bisection, whose upper bound was
  8192 px of width at the 1024-line test height, i.e. exactly 32 MiB. Testing
  above that bound allocated 36 MiB fine. The measurement that held up was a
  count rather than a size: how many panel-sized (3840x2400) scanout buffers
  a fresh client can obtain, which was 0–2 while the desktop was down and 64
  after. Staged freeing then separated the variables — releasing 239 MiB
  moved capacity not at all, a further 468 MiB took it from 2 to 19 — so it
  is which blocks are released, not how many bytes. The cause surfaced only
  after recovery: `gnome-shell` (same pid, never restarted) dropped from
  4482 MiB to 587 MiB across the reactivation, and had still been holding all
  of it while the session sat inactive, which is what makes the severe form
  self-sustaining. Also noted, because it undercounts every previous
  estimate: this episode logged 451 `gbm_surface_lock_front_buffer` failures
  and zero `Failed to allocate NVKMS memory` lines, while the same day's mild
  episode logged 3849 of the latter. The demoted IMP candidate, kept here in
  case it is ever worth re-testing: the modeset driver carries an "Is Mode
  Possible" display-bandwidth subsystem whose failure strings include
  `Failed to allocate %u KBPS Iso and %u KBPS Dram` and `Unexpectedly failed
  to program post-modeset bandwidth!`, neither of which has been observed on
  this machine.
- **2026-09-23** — rebooted into kernel 7.0.0-34 with no NVIDIA module:
  panel on `simpledrm`, a software cursor, and cursor ghosting. It was first
  suspected to be the mutter backport installed the same hour, then wrongly
  pinned on the unattended-upgrades hold. The kernel had come in the evening
  before through `provision`'s `apt-get install` step, which moved
  `linux-generic-hwe-24.04` after `apt-get upgrade` had held the NVIDIA module
  metapackage back; unattended-upgrades cannot see `-updates`, the only pocket
  that kernel was in. The hold is not innocent in general, though: on
  2026-09-04 unattended-upgrades installed kernel 7.0.0-31 from `-security`
  without its module, and a manual upgrade supplied it twelve hours later,
  before any reboot. Loading the module into the running kernel and starting a
  new session recovered without a reboot.
