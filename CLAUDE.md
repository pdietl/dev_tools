# CLAUDE.md — dev_tools

Pete Dietl's personal dev environment: dotfiles, a machine-provisioning script,
embedded-dev udev rules, and machine-specific fix notes. Deployed to
**pdietl-laptop** (ThinkPad P16 Gen 3, Pete's daily driver) plus WSL boxes;
the ThinkPad T16 Gen 4 chassis is currently diskless (see machine section).
Remote `git@github.com:pdietl/dev_tools.git`, branch `master`.

## What this repo is / how it deploys

- **`provision`** — the installer (Bash, run with `sudo`; uses `$SUDO_USER`).
  **Copies** the dotfiles here into the invoking user's `$HOME` via
  `install`/`installUser` (**not** symlinks/stow), installs apt + vendor-`.deb`
  packages, udev rules, etc. Ported to Ubuntu 26.04 (2026-06). Re-runnable.
  `in_wsl()`-aware.
- **Dotfiles** (copied by `provision`): `vimrc`, `nvim/` (LazyVim), `tmux.conf`,
  `starship.toml`, `gdbinit`, `nix.conf`, `gitignore_global`, `cscope_maps.vim`,
  `.editorconfig`, `dedup_paths.sh` (PATH-dedup helper).
- **`bin/`** — user scripts on `$PATH` (`netinfo`, `do_cscope`, `do_update`,
  `ntfy`, `wsl_usb_attach`/`detach`, `reset`).
- **`udev_rules/`** — SWD/JTAG programmer rules (ST-Link, CMSIS-DAP, picoprobe,
  WCH-Link, xgecu) plus a rule hiding ZFS pool members from GNOME's dock/Files;
  see `udev_rules/README.md`.
- **`suspend/`** — suspend/resume mitigation files `provision` installs:
  `gdfuse-suspend-guard` (every non-WSL machine) plus per-model sets gated on
  `dmidecode -s system-version` (`p16-gen3/`). Rationale lives in the
  machine-fix notes.
- **`journal-hygiene/`** — `provision`-installed redirects for the chattiest
  desktop loggers (tailscaled, Slack, LocalSearch) into their own size-capped
  log files (`/var/log/tailscaled.log`, `~/.local/state/{slack,localsearch}/`),
  plus an hourly logrotate timer override so the size caps actually bind, and
  a journald drop-in (20G persistent cap, 256M files, per-service flood
  backstop of 1000 msgs/10s).
  Also excludes `mnt` dirs from LocalSearch indexing (basename glob — absolute
  paths aren't matched) so the indexer stays off network-FUSE mounts.
- **`sysmon.sh`** — 1 Hz system monitor (screen + file logging).
- **Machine-fix notes** live as top-level markdown, one per machine:
  `thinkpad-p16-gen3-ubuntu-suspend.md`, `thinkpad-t16-gen4-ubuntu-suspend.md`.
  Follow that model for new machines.

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

Hardware: Intel **Arrow Lake-S** iGPU (`i915`; drives the eDP panel + DP
outputs) + NVIDIA **RTX PRO 1000 Blackwell** dGPU (external outputs only);
Intel **BE200** Wi-Fi 7 (`iwlwifi`); Intel **I226-LM** ethernet (`igc`);
suspend is **s2idle** only. Bleeding-edge silicon — many driver-level journal
warnings are upstream bugs already mitigated; don't chase them blindly.

### Suspend/resume → `thinkpad-p16-gen3-ubuntu-suspend.md`
Canonical doc: four suspend failure modes + mitigations (NVIDIA S0ix, i915
PSR/DC/power-well kernel params, the igc PTM sleep-hook, and the
Google-Drive-FUSE `statfs` fix). **Read it before touching suspend.**
The repo `suspend/p16-gen3/` set was applied to this install 2026-07-18
(i915 grub params active after the next reboot). The universal
`gdfuse-suspend-guard` and repo `journal-hygiene/` carried over from the
T16 era (applied 2026-07-12).

### Deltas vs the previous pdietl-laptop install (as of 2026-07-18)
- **No NVIDIA proprietary driver** — the dGPU is on `nouveau`, so the
  `nvidia-*.conf` modprobe files are inert and dGPU external outputs are
  unavailable. If `nvidia-driver-595` gets installed, expect to
  `systemctl disable nvidia-powerd` again (SEGV crash-loop on this combo).
- **gdfuse**: the patched non-blocking-`statfs` build (upstream
  astrada/google-drive-ocamlfuse **PR #943**, pinned fork commit) is at
  `/usr/local/bin`, installed by `provision`'s "google-drive-ocamlfuse
  (patched statfs build)" section (deb + PPA removed, user unit repointed;
  applied + verified 2026-07-18). The `gdfuse` opam switch exists for
  rebuilds; bump `GDFUSE_COMMIT` in `provision` to roll the pin.
- The old install's apparmor Varlink rules, PCP masks, and nvidia-powerd
  disable don't exist here and haven't been needed (no denial storm observed).

## Chassis — ThinkPad T16 Gen 4 (currently diskless)

`21QN005XUS`, AMD **Krackan** APU (`amdgpu`), MediaTek **MT7925** Wi-Fi 7
(`mt7925e`), Realtek ethernet (`r8169`); s2idle only. Its SSD (and install)
moved to the P16 2026-07-18. If it gets a disk again:
`thinkpad-t16-gen4-ubuntu-suspend.md` — platform suspend is healthy; the one
real failure mode is the gdfuse FUSE freezer wedge (covered by the universal
guard `provision` installs). amdgpu `ring gfx_0.0.0 timeout` + self-recovery
lines are app GPU hangs, not suspend-related — don't chase.
