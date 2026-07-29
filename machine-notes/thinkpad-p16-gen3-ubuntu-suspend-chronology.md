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
