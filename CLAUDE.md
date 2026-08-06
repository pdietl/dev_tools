# CLAUDE.md — dev_tools

Pete Dietl's personal dev environment: dotfiles, a machine-provisioning script,
embedded-dev udev rules, and machine-specific fix notes. Deployed to
**pdietl-laptop** (ThinkPad P16 Gen 3, Pete's daily driver),
**pdietl-home-ubun** (X870E desktop), plus WSL boxes;
the ThinkPad T16 Gen 4 chassis is currently diskless (see machine section).
**Check `hostname`/`dmidecode` before trusting a machine section below** —
sessions run on any of these boxes.
Remote `git@github.com:pdietl/dev_tools.git`, branch `master`.

## What this repo is / how it deploys

- **`provision`** — the installer (Bash, run with `sudo`; uses `$SUDO_USER`),
  the only top-level script. **Copies** the files here into place via
  `install`/`installUser` (**not** symlinks/stow), installs apt + vendor-`.deb`
  packages, udev rules, etc. Ported to Ubuntu 26.04 (2026-06). Re-runnable.
  `in_wsl()`-aware.
- **`dotfiles/`** — everything `provision` copies into the invoking user's
  `$HOME`: `vimrc`, `nvim/` (LazyVim), `tmux.conf`, `starship.toml`, `gdbinit`,
  `nix.conf`, `gitignore_global`, `cscope_maps.vim`, `dedup_paths.sh`
  (PATH-dedup helper), and `google-drive-ocamlfuse.service` (auto-mount user
  unit, see below). The repo's own `.editorconfig` stays at the top level.
- **`bin/`** — user scripts copied to `~/bin` (on `$PATH`): `netinfo`,
  `do_cscope`, `do_update`, `ntfy`, `wsl_usb_attach`/`detach`, `reset`,
  `sysmon.sh` (1 Hz system monitor, screen + file logging).
- **`system/`** — everything `provision` installs outside `$HOME`:
  - **`system/udev_rules/`** — SWD/JTAG programmer rules (ST-Link, CMSIS-DAP,
    picoprobe, WCH-Link, xgecu) plus two rules hiding volumes from GNOME's
    dock/Files: ZFS pool members, and NTFS on a fixed internal disk (a
    dual-boot Windows install); see `system/udev_rules/README.md`.
  - **`system/apt/`** — apt drop-ins: NVIDIA unattended-upgrades hold, and the
    `DPkg::Post-Invoke` hook that re-derives the Chrome VA-API desktop entry.
  - **`system/chrome-vaapi/`** — `regenerate-chrome-vaapi-override`, installed
    to `/usr/local/sbin`. Sole owner of the VA-API launch flag and of the
    assertions guarding the desktop-entry copy; run by `provision` and by the
    apt hook above. See "Chrome HEVC hardware decode".
  - **`system/gdfuse/`** — `gdfuse-prewarm`, installed to `/usr/local/bin` and
    run detached by the mount unit's `ExecStartPost`. Stats the mountpoint once
    the mount exists so the first process to list `$HOME` isn't the one paying
    the cold getattr against Drive. Nothing on the starship side can avoid
    that cost — it has no per-path exclusion, and its `scan_timeout` is checked
    between directory entries, so it cannot abort a getattr already in flight.
  - **`system/suspend/`** — suspend/resume mitigations: `gdfuse-suspend-guard`
    (every non-WSL machine) plus per-model sets gated on
    `dmidecode -s system-version` (`p16-gen3/`). Rationale lives in the
    machine-fix notes.
  - **`system/hidpi-boot/`** — HiDPI boot-display fixes installed per-model
    (P16 Gen 3's 3840x2400 panel): 32 px GRUB font drop-in + Plymouth
    `DeviceScale=2` so the GRUB menu and disk-decryption prompt are readable.
  - **`system/journal-hygiene/`** — redirects for the chattiest desktop
    loggers (tailscaled, Slack, LocalSearch) into their own size-capped log
    files (`/var/log/tailscaled.log`, `~/.local/state/{slack,localsearch}/`),
    plus an hourly logrotate timer override so the size caps actually bind,
    and a journald drop-in (20G persistent cap, 256M files, per-service flood
    backstop of 1000 msgs/10s).
    Also excludes `mnt` dirs from LocalSearch indexing (basename glob —
    absolute paths aren't matched) so the indexer stays off network-FUSE
    mounts.
- **`machine-notes/`** — machine-fix notes, one markdown file per machine:
  `thinkpad-p16-gen3-ubuntu-suspend.md`, `thinkpad-t16-gen4-ubuntu-suspend.md`.
  Follow that model for new machines. Notes hold **current state only**; the
  investigation narrative — including approaches later refuted — lives in a
  sibling `*-chronology.md`, which is provenance, not required reading.

## Conventions

- **Commits:** short imperative subjects ("Add …", "Port …", "Fix …"), author
  Pete Dietl <petedietl@gmail.com>, existing history uses no trailer.
  Commit/push **only when asked**.
- **Live-system changes** (things in `/etc`, systemd units, etc. — *outside* this
  repo): keep them **reversible** and **self-documenting** — every dropped-in file
  carries a header comment saying why it exists and how to revert — and index them
  in a machine-notes markdown here.
- `.claude/` is gitignored; this `CLAUDE.md` is tracked.

## Machine — pdietl-laptop (daily driver)

ThinkPad **P16 Gen 3** (`21RQCTO1WW`) chassis running the Ubuntu **26.04**
install originally provisioned on the T16 (NVMe moved 2026-07-18 when the P16
returned from keyboard replacement; hostname renamed `pdietl-t16` →
`pdietl-laptop`, tailnet re-registered under the new name, same IP). ZFS root.
**This is not the pre-2026-07 `pdietl-laptop` install** — that lived on a
different SSD, and most of its hand-applied live state does not exist here
(see "Deltas" below).

Hardware: Intel **Arrow Lake-S** iGPU (`i915`) + NVIDIA **RTX PRO 1000
Blackwell** dGPU; a BIOS eDP MUX (Config → Display → Graphics Device)
selects which one drives the panel — **currently Discrete**, so the dGPU
owns the panel and all external outputs;
Intel **BE200** Wi-Fi 7 (`iwlwifi`); Intel **I226-LM** ethernet (`igc`);
suspend is **s2idle** only. Bleeding-edge silicon — many driver-level journal
warnings are upstream bugs already mitigated; don't chase them blindly.

### Suspend/resume → `machine-notes/thinkpad-p16-gen3-ubuntu-suspend.md`
Canonical doc: four suspend failure modes + mitigations (NVIDIA S0ix, i915
PSR/DC/power-well kernel params, the igc PTM sleep-hook, and the
Google-Drive-FUSE `statfs` fix). **Read it before touching suspend.**
The repo `system/suspend/p16-gen3/` set was applied to this install 2026-07-18
(i915 grub params active after the next reboot). The universal
`gdfuse-suspend-guard` and repo `system/journal-hygiene/` carried over from the
T16 era (applied 2026-07-12).

### Crash capture (applied 2026-07-25)
Two hard hangs in two days (2026-07-24 reboot teardown, 2026-07-25 idle),
both docked with the lid closed and two USB-C externals on the dGPU, both
leaving **no log at all** — a wedged machine cannot flush its own journal.
Four capture mechanisms are now live, none of them in `provision` (they are
hand-applied live-system changes, each file self-documenting its revert):
panic triggers (`/etc/sysctl.d/60-crash-capture.conf`), the iTCO hardware
watchdog, panic dmesg into UEFI NVRAM via `efi_pstore`, and a netconsole
stream to **pdietl-thinkstation** (`10.0.100.3`) capped at 20 GB. Crash
records surface in `/var/lib/systemd/pstore/` (systemd archives and empties
`/sys/fs/pstore` seconds after boot). **ramoops was tried first and can
never work on this machine** — the firmware zeroes DRAM during POST after
any dirty reset, exactly the resets a crash produces — so don't resurrect
it.

kdump had been reporting `ready to kdump` while unable to save anything: its
capture initrd cannot import or unlock the encrypted ZFS root. **The machine
is now swapless** (122 GiB RAM, no hibernation) and `nvme0n1p3` — formerly
8 GiB of encrypted swap — is a plain ext4 partition labelled `kdump`, kept
`noauto` at `/mnt/kdump`. rpool itself was not resized and cannot be: ZFS
has no shrink.

**kdump is nonetheless disabled** (`USE_KDUMP=0`): a deliberate sysrq panic
showed the capture kernel hangs regardless of target — no dump, no console
output, no reboot. That is destructive rather than merely useless: a loaded
crash kernel is entered before `kmsg_dump()`, so its hang also suppresses
the pstore record. Do not re-enable it without fixing the capture kernel
first. Evidence now rides on efi_pstore + netconsole; `kernel.panic=60` is
verified to self-reboot a panicked machine in exactly 60 s.

Details, constraints and the verification steps still owed are in
`machine-notes/thinkpad-p16-gen3-ubuntu-suspend.md` under "Crash capture". **Read that
before changing the watchdog timeout, `hung_task_timeout_secs`, or the dump
partition's filesystem** — each has a non-obvious constraint behind it.

### Boot-time HiDPI text (applied 2026-07-18)
GRUB and Plymouth (including the disk-decryption prompt) render on the
panel's native 3840x2400 (~260 DPI) and were unreadably small. Fixed by
repo `system/hidpi-boot/` via `provision` (DMI-gated): 32 px `grub-mkfont` DejaVu
Mono + `GRUB_FONT` drop-in, and Plymouth `DeviceScale=2` baked into the
initramfs. Both installed files self-document their revert steps.

### Chrome HEVC hardware decode
Chrome has no software HEVC decoder, so H.265 does not play at all unless
VA-API decode works. `provision`'s "Chrome hardware video decode" section
installs `nvidia-vaapi-driver` + `vainfo`, then
`system/chrome-vaapi/regenerate-chrome-vaapi-override` into `/usr/local/sbin`
and `system/apt/53chrome-vaapi-override` as an apt drop-in that runs it after
every dpkg transaction. That generator writes
`/usr/local/share/applications/google-chrome.desktop` (wins over
`/usr/share` in `XDG_DATA_DIRS`) adding
`--enable-features=VaapiOnNvidiaGPUs` — Chrome ships that feature
disabled, which switches off VA-API on NVIDIA entirely. The override is a
whole-file copy of a package-managed file, so it is re-derived whenever Chrome
itself changes rather than only when `provision` runs: a key a new Chrome
release adds is otherwise absent from the entry that actually wins, and the
resulting breakage need not look anything like a VA-API problem. Ubuntu 26.04's
packaged driver (0.0.14) already defaults to the direct/CUDA backend, the
one that survives Chrome's GPU sandbox, so no upstream source build is
needed. tf4's `operator_station/setup.sh` builds v0.0.16 from source for
the same fix; that step is redundant on 26.04 and is deliberately not
ported. Also needs a Wayland session and `nvidia_drm.modeset=1`. Gated on
an NVIDIA render node being present, so it is inert on the T16 and under
WSL. The generator hard-fails — failing the apt transaction — if Chrome's
desktop file stops matching the `Exec=` pattern it rewrites, or if the copy
would differ from the source by anything other than that flag; `provision`
warns without aborting if `vainfo` reports no usable HEVC.

Verify against the NVIDIA render node (`renderD129` here — the one whose
`/sys/class/drm/*/device/vendor` is `0x10de`):
`LIBVA_DRIVER_NAME=nvidia vainfo --display drm --device /dev/dri/renderD129`
should say `[direct backend]` and list `VAProfileHEVC*`. Note the flag only
reaches Chrome via the desktop file — `google-chrome` typed at a shell
does not get it.

### Deltas vs the previous pdietl-laptop install (as of 2026-07-18)
- **NVIDIA**: `nvidia-driver-595-open` + `prime-select nvidia` installed
  2026-07-18, BIOS switched Hybrid → Discrete the same day (panel now on
  the dGPU — suspend implications in the suspend doc's topology note).
  If `nvidia-powerd` starts SEGV-crash-looping, `systemctl disable` it
  (it did on the previous install). Avoid DisplayLink/evdi heads while in
  Discrete mode (multi-second lag; see suspend doc).
- **gdfuse**: the non-blocking-`statfs` fix (our upstream PR #943) is
  **merged and released in v0.9.1**; `provision` builds that upstream tag
  to `/usr/local/bin` and installs + enables the auto-mount user unit
  (`dotfiles/google-drive-ocamlfuse.service` → `~/GoogleDrive`, inert until
  the one-time OAuth setup whose recipe provision prints after a run). The
  laptop hasn't rerun `provision` since this change, so it still runs the
  July pinned-fork build (same statfs code, stamp `972dab0…`); the next run
  rebuilds at v0.9.1. The auto-mount unit and `gdfuse-prewarm` are already in
  place there, so all three machines mount `~/GoogleDrive` from the same unit.
  The `gdfuse` opam switch exists for rebuilds; bump
  `GDFUSE_VERSION`/`GDFUSE_COMMIT` in `provision` to roll the pin.
- The old install's apparmor Varlink rules, PCP masks, and nvidia-powerd
  disable don't exist here and haven't been needed (no denial storm observed).

## Chassis — ThinkPad T16 Gen 4 (currently diskless)

`21QN005XUS`, AMD **Krackan** APU (`amdgpu`), MediaTek **MT7925** Wi-Fi 7
(`mt7925e`), Realtek ethernet (`r8169`); s2idle only. Its SSD (and install)
moved to the P16 2026-07-18. If it gets a disk again:
`machine-notes/thinkpad-t16-gen4-ubuntu-suspend.md` — platform suspend is
healthy; the one
real failure mode is the gdfuse FUSE freezer wedge (covered by the universal
guard `provision` installs). amdgpu `ring gfx_0.0.0 timeout` + self-recovery
lines are app GPU hangs, not suspend-related — don't chase.

## Machine — pdietl-home-ubun (home desktop)

Gigabyte **X870E AORUS ELITE WIFI7**, AMD **Granite Ridge** (Ryzen 9000)
iGPU + NVIDIA **RTX 5080** dGPU. First full `provision` run 2026-07-29:
KiCad built from source and installed, gdfuse **v0.9.1** built + auto-mount
unit enabled and `~/GoogleDrive` mounting (OAuth completed),
Chrome VA-API verified (direct backend, 6 HEVC profiles on the NVIDIA
render node), NVIDIA unattended-upgrades hold and journal hygiene applied.
DMI system-version is not a ThinkPad, so the model-gated suspend/HiDPI
sections are inert here. No machine-fix notes yet — add
`machine-notes/<file>.md` when the first real fix lands.
