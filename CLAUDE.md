# CLAUDE.md — dev_tools

Pete Dietl's personal dev environment: dotfiles, a machine-provisioning script,
embedded-dev udev rules, and machine-specific fix notes. Deployed primarily to
**pdietl-laptop** (also WSL boxes). Remote `git@github.com:pdietl/dev_tools.git`,
branch `master`.

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
  WCH-Link, xgecu); see `udev_rules/README.md`.
- **`sysmon.sh`** — 1 Hz system monitor (screen + file logging).
- **Machine-fix notes** live as top-level markdown; model:
  `thinkpad-p16-gen3-ubuntu-suspend.md`. Append new machine fixes there.

## Conventions

- **Commits:** short imperative subjects ("Add …", "Port …", "Fix …"), author
  Pete Dietl <petedietl@gmail.com>, existing history uses no trailer.
  Commit/push **only when asked**.
- **Live-system changes** (things in `/etc`, systemd units, etc. — *outside* this
  repo): keep them **reversible** and **self-documenting** — every dropped-in file
  carries a header comment saying why it exists and how to revert — and index them
  in a machine-notes markdown here.
- `.claude/` is gitignored; this `CLAUDE.md` is tracked.

## Primary machine — pdietl-laptop

ThinkPad **P16 Gen 3** (`21RQCTO1WW`), Ubuntu **26.04**, kernel **7.0.0-22**.
Intel **Arrow Lake-S** iGPU (`i915`; drives the eDP panel + DP outputs) + NVIDIA
**RTX PRO 1000 Blackwell** dGPU (`nvidia` 595; external outputs only); Intel
**BE200** Wi-Fi 7 (`iwlwifi`/`iwlmld`); suspend is **s2idle** only. It's
bleeding-edge silicon, so many driver-level journal warnings are upstream bugs
already mitigated — don't chase them blindly.

### Suspend/resume → `thinkpad-p16-gen3-ubuntu-suspend.md`
Canonical doc: four suspend failure modes + mitigations (NVIDIA S0ix, i915
PSR/DC/power-well kernel params, the igc PTM sleep-hook, and the 2026-06-24
Google-Drive-FUSE `statfs` fix). **Read it before touching suspend.**

### Live system state applied 2026-06-24 (journal hygiene + fixes)
Not tracked in this repo (they live in `/etc` + the user systemd session) — indexed
here. All reversible; each file self-documents.

- **Suspend storm fixed at the source.** `Freezing user space processes failed
  (2 tasks … fuse_statfs)` was `google-drive-ocamlfuse`'s blocking `statfs`
  (upstream #896) on `~/mnt/GoogleDrive`, **not** an NVIDIA/i915 mode. Patched it
  non-blocking in `~/Repos/google-drive-ocamlfuse` (working tree, **uncommitted**),
  built release via opam switch **`gdfuse`** (system OCaml 5.4.0), installed to
  **`/usr/local/bin/google-drive-ocamlfuse`**, removed the deb, repointed
  `~/.config/systemd/user/google-drive-ocamlfuse.service`. The `gdfuse` switch is
  needed only to **rebuild** (after a `git pull`); the binary itself runs without
  it. Full detail = suspend doc, failure mode 4.
- **Journal spam → files** (out of `journalctl`):
  - tailscaled → `/var/log/tailscaled.log`
    (`/etc/systemd/system/tailscaled.service.d/suppress-journal-spam.conf` +
    `/etc/logrotate.d/tailscaled`).
  - Slack → `~/.local/state/slack/slack.log` (`~/.local/bin/slack-logged` wrapper
    + `~/.local/share/applications/slack.desktop` override + `/etc/logrotate.d/slack`;
    effective on next Slack launch).
- **apparmor:** geoclue + cups-browsed denied the systemd-resolved Varlink socket
  (~1110 denials/boot) → rules in
  `/etc/apparmor.d/local/{usr.libexec.geoclue,usr.sbin.cups-browsed}`.
- **`nvidia-powerd`** SEGV crash-loop → `systemctl disable`d (Dynamic Boost,
  unsupported on this Blackwell + Arrow-Lake combo).
- **PCP** `pmcd`/`pmproxy`/`pmie`/`pmlogger` (orphaned `rc`-state SysV) → masked.
- **Wi-Fi 7 `iwlmld` MLO** WARNs left as-is (Wi-Fi 7 kept; kernel/firmware residual).
- Residual i915 DP/PHY modeset errors are upstream, already mitigated (suspend doc).
