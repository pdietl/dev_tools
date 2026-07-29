# ThinkPad P16 Gen 3 — Ubuntu suspend / resume mitigations

Durable writeup of the suspend/wake debugging for this laptop, so a future
fresh install (or future me) doesn't have to rederive any of it. Most of
what's here is platform-level and outlives Ubuntu point releases — the same
fixes were needed on 24.04 and again on 26.04.

---

## Hardware / OS baseline

**Machine:** Lenovo ThinkPad P16 Gen 3 (`21RQCTO1WW`), BIOS `N4FET49W`.

| Component | PCI BDF | Driver | Role |
|-----------|---------|--------|------|
| Intel Arrow Lake-S iGPU | `00:02.0` | `i915` | Drives the eDP-1 panel (BIOS Hybrid mode) + 4× DP outputs |
| NVIDIA RTX PRO 1000 Blackwell | `01:00.0` | `nvidia` | External HDMI/DP; in BIOS Discrete mode also the eDP panel |
| Intel I226-LM Ethernet | `86:00.0` | `igc` | `enp134s0` |

**OS at time of writing (2026-06-20):** Ubuntu 26.04 LTS (Resolute Raccoon),
kernel `7.0.0-22-generic`, NVIDIA driver 595 (`nvidia-driver-595`), GDM/Wayland.

**Suspend mode:** `s2idle` ("Modern Standby" / S0ix). Confirmed:
```
$ cat /sys/power/mem_sleep
[s2idle]
```
This hardware does *not* expose deep `mem` (S3) suspend, so every mitigation
below assumes s2idle.

**Key topology fact (revised 2026-07-18):** which GPU drives the internal
panel is selected by a BIOS **eDP MUX** — Config → Display → Graphics
Device:

- **Hybrid Graphics** (factory default; every pre-2026-07 measurement in
  this doc was taken here): panel on the Intel iGPU. No PRIME mode can
  take the panel off the i915 KMS path in this mode — PRIME only moves
  *rendering*, never panel scanout.
- **Discrete Graphics**: the MUX hands the panel to the NVIDIA dGPU
  (verified live: `eDP-1` appears as a connector of the nvidia DRM card
  and i915 retains no connected outputs; i915 still loads but scans out
  nothing).

The June conclusion that "this SKU doesn't appear to expose a MUX" was
wrong — the option exists under Config → Display and works. Consequences:
in Discrete mode the i915 C10 PHY restore path (failure mode 3) cannot
touch the panel, and panel suspend/resume instead rides the NVIDIA
driver's S0ix path (failure mode 2's mitigations).

---

## Four distinct failure modes

Two are cosmetic; one is the catastrophic "screen is on but no GUI ever
appears, must hard-reboot" symptom; the fourth (added 2026-06-24) is a hung
FUSE mount that blocks the process freezer and aborts suspend entirely —
unrelated to graphics.

### 1. igc `IGC_PTM_STAT register` timeout spam on resume — cosmetic

```
kernel: igc 0000:86:00.0 enp134s0: Timeout reading IGC_PTM_STAT register
```

The igc driver's `igc_ptp_reset()` unconditionally polls the PCIe PTM
(Precision Time Measurement) status register on resume. The PCI core
disables PTM before the driver's suspend hook runs (kernel commit
`c01163dbd1b8`), so by the time `igc_ptp_reset()` fires there's no active
PTM dialog and the poll times out. **Network works fine** — purely noise.
No `pci=noptm` / no `setpci` trick fixes it (PTM is already off on the NIC;
the driver polls regardless). No igc module parameter exists.

### 2. NVIDIA legacy-suspend-path deadlock — severe on 24.04, latent on 26.04

Symptom: kernel log fills with
```
Freezing user space processes failed after 20.001 seconds
  (1 tasks refusing to freeze, wq_busy=0):
```
followed by the suspend being abandoned mid-way and the system returning
to a wedged userspace.

Cause: without explicit configuration the NVIDIA driver picks its legacy
S3-style suspend path. That path doesn't coordinate with active
`nvidia_drm` clients (gnome-shell as a Wayland compositor holds live GPU
contexts that won't release on freeze). The kernel times out trying to
freeze them.

### 3. i915 C10 PHY/PLL fails on resume — *the* GUI hang

*BIOS Hybrid mode only: in Discrete mode the panel is not on i915 and
this failure mode cannot occur (see the topology note above).*

In Hybrid mode the eDP panel is wired to the iGPU. On suspend the iGPU enters a deep
display power state (DC9 in particular); on resume the C10 PHY/PLL
restore path is fragile on Arrow Lake-HX and presents in two distinct
flavors on this machine:

**3a. PHY-idle / DDI / flip_done timeout chain** (predominant before mitigations):
```
i915 0000:00:02.0: [drm] *ERROR* Failed to bring PHY A to idle.
i915 0000:00:02.0: [drm] *ERROR* PHY A Read 0c70 failed after 3 retries.
i915 0000:00:02.0: [drm] *ERROR* Timeout waiting for DDI BUF A to get active
i915 0000:00:02.0: [drm] *ERROR* Timed out waiting for DP idle patterns
i915 0000:00:02.0: [drm] *ERROR* [CRTC:150:pipe A] flip_done timed out
i915 0000:00:02.0: [drm] *ERROR* c10pll_hw_state: clock: 810000 ...  found 44965
```
Backlight stays on (panel hardware is still powered) but every KMS commit
times out, so mutter cannot draw a single frame. User-visible: screen is
on, GUI never appears, no login screen reachable, must hard-reboot.

**3b. PHY refclk request failure** (deeper, less frequent, harder to suppress):
```
i915 0000:00:02.0: [drm] PHY A failed to request refclk
```
An earlier step than (3a) — the PHY cannot even obtain its reference clock
from the iGPU's clock subsystem. Observed both on suspend *entry* (PHY
broken before sleep) and on resume. When fatal, triggers a kernel WARNING
in `intel_disable_transcoder+0x356` originating from `vt_ioctl` →
`do_unblank_screen` (e.g. systemd-logind asking fbcon to unblank on lid-open).

### 4. Hung Google Drive FUSE `statfs` blocks the freezer — *the actual cause of the 2026-06-24 storm*

Distinct from 1–3 — **not** display or NVIDIA. Symptom in `journalctl -b`:
```
kernel: Freezing user space processes failed after 20.00 seconds
  (2 tasks refusing to freeze, wq_busy=0):
kernel: task:pool-NN  state:D  ...  fuse_statfs -> request_wait_answer
systemd-sleep: Failed to put system to sleep. System resumed again: Device or resource busy
```
The tell is **2 tasks** (vs mode 2's *1 task*) and the `fuse_statfs` stack. On
2026-06-24 this fired ~97 times over ~30 min (194 freeze-fail lines) and
amplified ~250 pipewire/v4l2 re-probe errors. `EnableS0ixPowerManagement=1`
(mode 2's fix) was confirmed live, so this was a *separate* cause.

`~/mnt/GoogleDrive` is a `google-drive-ocamlfuse` mount. Its `statfs` handler
routed through `get_metadata`, which does a **blocking, retrying network
round-trip** (Drive `about` quota + changes feed) whenever its 60 s metadata
cache is stale. `statfs(2)` is called implicitly by GNOME's disk-usage poll,
`df`, GTK file choosers, some PAM stacks — so when Drive/the network stalls the
caller blocks in uninterruptible **D** state inside
`fuse_statfs`/`request_wait_answer`. D-state tasks cannot be frozen → the
freezer times out → suspend aborts and retries forever. (Upstream
google-drive-ocamlfuse issue #896.)

---

## Mitigations applied (current working set)

All reversible. Each file has a header comment explaining itself so a
future reader of the system finds the rationale in-place.

The installable pieces are maintained in this repo under
`system/suspend/p16-gen3/` and applied by `provision` when
`dmidecode -s system-version` reports `ThinkPad P16 Gen 3`. Two deltas
versus the hand-installed files described below: the repo's
`igc-ptm-workaround` enumerates igc-bound devices at runtime instead of
hardcoding the BDF, and on machines whose `/etc/default/grub` doesn't
already carry the i915 params, provision installs them as a
`/etc/default/grub.d/i915-suspend.cfg` drop-in instead of editing the main
file. The failure-mode-4 gdfuse build remains a manual step, but
`system/suspend/gdfuse-suspend-guard` (installed by provision on every non-WSL
machine) now backstops it — see that mode's section below.

### `/etc/modprobe.d/nvidia-s0ix.conf` (new file)

```
# Enable S0ix-aware suspend path in the NVIDIA driver so s2idle (modern
# standby) can cleanly quiesce the dGPU. Without this the driver takes a
# legacy code path that races with active nvidia_drm clients (e.g.
# gnome-shell) and causes 20s "Freezing user space processes failed" stalls.
options nvidia NVreg_EnableS0ixPowerManagement=1
```

Fixes problem (2). `NVreg_EnableS0ixPowerManagement=1` was added in NVIDIA
driver 525+. Effectively tells NVIDIA "this platform uses Modern Standby
(s2idle); use the suspend protocol that coordinates with active KMS
clients."

### `/etc/modprobe.d/nvidia-resume-speed.conf` (new file)

```
# Disable NVIDIA driver's VRAM-preservation-on-suspend. Saving the dGPU's
# VRAM contents to disk on suspend (and restoring on resume) adds several
# seconds to both ends. Cost of disabling: GPU-accelerated app windows
# may render as garbage for one frame on resume before redrawing.
# Overrides nvidia-graphics-drivers-kms.conf which sets =1; this file
# sorts later so it wins.
options nvidia NVreg_PreserveVideoMemoryAllocations=0
```

Performance tweak — drops several seconds off both suspend and resume by
skipping the VRAM round-trip to `/var`. Kept in its **own file** (not
edited into the auto-generated `nvidia-graphics-drivers-kms.conf`) so
future `nvidia-driver-*` package updates don't overwrite it; alphabetical
ordering puts it after `nvidia-graphics-drivers-kms.conf` so the override
wins.

### `/usr/lib/systemd/system-sleep/igc-ptm-workaround` (new file, `0755 root:root`)

```bash
#!/bin/bash
set -u

# Workaround for igc driver polling IGC_PTM_STAT on resume when PTM
# is already disabled on the device. Unbind before suspend, rebind after.
# Remove this once upstream fixes the unconditional poll in igc_ptp_reset().

declare -r PCI_DEV='0000:86:00.0'
declare -r DRIVER_PATH='/sys/bus/pci/drivers/igc'
declare -r LOG_TAG='igc-ptm-workaround'

log() {
    logger -t "$LOG_TAG" "$1"
}

case "$1/$2" in
    pre/*)
        if [[ -e "$DRIVER_PATH/$PCI_DEV" ]]; then
            if echo "$PCI_DEV" > "$DRIVER_PATH/unbind" 2>/dev/null; then
                log "unbound $PCI_DEV before $2"
            else
                log "WARN: unbind failed for $PCI_DEV"
            fi
        fi
        ;;

    post/*)
        if [[ ! -e "$DRIVER_PATH/$PCI_DEV" ]]; then
            if echo "$PCI_DEV" > "$DRIVER_PATH/bind" 2>/dev/null; then
                log "rebound $PCI_DEV after $2"
            else
                log "ERROR: rebind failed for $PCI_DEV — network may be down"
            fi
        fi
        ;;
esac
```

systemd-sleep auto-runs every script in `/usr/lib/systemd/system-sleep/`
with `{pre|post} {suspend|hibernate|...}` args; no enable step needed.
This one unbinds the igc PCI device before kernel suspend prep (so
`igc_ptp_reset()` never runs on resume) and rebinds after. ~200 ms network
blip on resume; NetworkManager re-establishes automatically. Fixes
problem (1).

**The PCI BDF `0000:86:00.0` is specific to this machine.** On any other
host check with `lspci | grep -i ethernet` and update the script.

### `/etc/default/grub` — kernel cmdline (modified, then `sudo update-grub`)

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_psr=0 i915.enable_dc=0 i915.disable_power_well=0"
```

Three i915 knobs targeting problem (3), in the order they were added:

| Param | Disables | Why |
|-------|----------|-----|
| `i915.enable_psr=0` | Panel Self Refresh | The simplest C10 PHY entry/exit handshake; this gets exercised even between repaints during normal use, not just on resume. |
| `i915.enable_dc=0` | All Display C-states (DC5/DC6/DC9) | DC9 in particular is where the PHY enters the deep state it can't always restore from after long idle. |
| `i915.disable_power_well=0` | Power-well disable (forces them always-on) | Refclk gating lives in the power-well layer; this addresses failure-mode (3b). |

Power cost: probably 1–2 W extra at idle, total. Insignificant relative
to a hard reboot.

In BIOS Discrete mode these params protect nothing (i915 scans out no
display) but cost nothing either — keep them so a return to Hybrid mode
stays mitigated without remembering this step.

### `google-drive-ocamlfuse` — non-blocking `statfs` (fixes mode 4)

**Status 2026-07-29: the fix landed upstream** — PR #943 merged and released
as **v0.9.1**. `provision` now builds `/usr/local/bin/google-drive-ocamlfuse`
from the upstream v0.9.1 tag (no fork involved), removes the PPA deb (the PPA
ships 0.9.0, which predates the fix), and installs + enables the user unit
`~/.config/systemd/user/google-drive-ocamlfuse.service`
(repo: `dotfiles/google-drive-ocamlfuse.service`, mounts `~/GoogleDrive`,
inert until the one-time OAuth setup provision describes at the end of a run).
The description below is the original debugging/patch writeup.

Patch (3 files — `src/drive.ml`, `src/driveMetadataRefresh.ml`, `.mli`): `statfs`
now reads the **in-memory cached** metadata through a new non-blocking
`get_cached_metadata` (no network, no metadata lock; "unlimited" default until
the cache is first populated). It can therefore never block, so it can never
wedge the freezer. Trade-off: `df` may show slightly stale quota — strictly
better than hanging. Verified: 30 `statfs` calls add **zero** metadata-refresh
log lines (`-verbose`).

Build (the OCaml toolchain was absent): `apt install opam libfuse3-dev
libsqlite3-dev libgmp-dev libcurl4-gnutls-dev` (gnutls, not openssl — opam's
depext for ocurl checks for that exact package), `opam switch create gdfuse
ocaml-system` (system OCaml 5.4.0), `opam install --deps-only .`, `dune build
--profile release bin/gdfuse.exe`, `sudo install -m755
_build/default/bin/gdfuse.exe /usr/local/bin/google-drive-ocamlfuse`. The binary
dynamically links system libs (fuse3/sqlite3/gmp/curl) so it runs without the
opam switch; the `gdfuse` switch is needed only to **rebuild** (after a `git
pull`, or to regenerate the patch). The patch is committed on branch
`nonblocking-statfs` of the `pdietl` fork and submitted upstream as
astrada/google-drive-ocamlfuse PR #943 (fixes issue #896) — merged, released
in v0.9.1.

Revert: `sudo apt install google-drive-ocamlfuse` and point `ExecStart` back at
`/usr/bin/google-drive-ocamlfuse` — but note the PPA's 0.9.0 deb reintroduces
the blocking `statfs`; only do this once the PPA ships ≥ 0.9.1.

Defense-in-depth: the patch only covers `statfs`; any *other* gdfuse
operation caught in flight when the network dies wedges the freezer the
same way (seen on the T16 via `fuse_do_getattr`/`fuse_file_read_iter` —
see `thinkpad-t16-gen4-ubuntu-suspend.md`). The
`/usr/lib/systemd/system-sleep/gdfuse-suspend-guard` hook (repo:
`system/suspend/gdfuse-suspend-guard`) aborts a gdfuse FUSE connection that still
has unanswered requests at sleep time, op-agnostically, and remounts after
resume.

### Already present in baseline (do NOT touch)

`/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` is auto-generated by
`nvidia-driver-595`:
```
options nvidia_drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1   # overridden by nvidia-resume-speed.conf
options nvidia NVreg_TemporaryFilePath=/var
```
`modeset=1` is required for `nvidia_drm` to integrate with Wayland.
`PreserveVideoMemoryAllocations=1` here is intentionally overridden by
the new `nvidia-resume-speed.conf` (alphabetical late-wins).

---

## Applying these from scratch

Preferred: run `sudo ./provision` from a dev_tools checkout — its
"Suspend mitigations" section applies steps 1–4 below automatically on
this hardware (and the gdfuse sleep guard everywhere). The manual
sequence is kept for reference:

```bash
# 1. NVIDIA modprobe overrides
sudo tee /etc/modprobe.d/nvidia-s0ix.conf > /dev/null <<'EOF'
# Enable S0ix-aware suspend path in the NVIDIA driver so s2idle (modern
# standby) can cleanly quiesce the dGPU. Without this the driver takes a
# legacy code path that races with active nvidia_drm clients (e.g.
# gnome-shell) and causes 20s "Freezing user space processes failed" stalls.
options nvidia NVreg_EnableS0ixPowerManagement=1
EOF

sudo tee /etc/modprobe.d/nvidia-resume-speed.conf > /dev/null <<'EOF'
# Disable NVIDIA driver's VRAM-preservation-on-suspend. Saving the dGPU's
# VRAM contents to disk on suspend (and restoring on resume) adds several
# seconds to both ends. Cost of disabling: GPU-accelerated app windows
# may render as garbage for one frame on resume before redrawing.
# Overrides nvidia-graphics-drivers-kms.conf which sets =1; this file
# sorts later so it wins.
options nvidia NVreg_PreserveVideoMemoryAllocations=0
EOF

# 2. igc sleep hook (paste contents from above into the file, or scp from
#    a working machine; verify the PCI BDF matches `lspci | grep -i ethernet`)
sudoedit /usr/lib/systemd/system-sleep/igc-ptm-workaround
sudo chmod 0755 /usr/lib/systemd/system-sleep/igc-ptm-workaround
sudo chown root:root /usr/lib/systemd/system-sleep/igc-ptm-workaround

# 3. Kernel cmdline (back up first)
sudo cp /etc/default/grub /etc/default/grub.bak
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_psr=0 i915.enable_dc=0 i915.disable_power_well=0"|' /etc/default/grub

# 4. Bake in + reboot
sudo update-initramfs -u
sudo update-grub
sudo reboot
```

Verify after reboot:
```bash
cat /proc/cmdline                                          # all three i915.* present
sudo cat /proc/driver/nvidia/params | grep -E 'EnableS0ix|PreserveVideo'
# EnableS0ixPowerManagement: 1
# PreserveVideoMemoryAllocations: 0
sudo cat /sys/kernel/debug/dri/*/i915_edp_psr_status | head -3
# PSR mode: disabled
journalctl -t igc-ptm-workaround                           # appears after first suspend
```

Note: `/sys/module/nvidia/parameters/EnableS0ixPowerManagement` does NOT
exist — NVIDIA `NVreg_*` options are not exposed via sysfs. Use
`/proc/driver/nvidia/params` for verification.

---

## Diagnostic playbook

When a new failed resume or new hang happens, run these in order:

```bash
# Boot list — short consecutive boots == forced reboots
journalctl --list-boots | tail -20

# Confirm all mitigations are still live on the current boot
cat /proc/cmdline
sudo cat /proc/driver/nvidia/params | grep -E 'EnableS0ix|PreserveVideoMemory'
ls /usr/lib/systemd/system-sleep/igc-ptm-workaround

# All suspend/wake cycles this boot
journalctl -b 0 -k | grep -E "PM: suspend (entry|exit)"

# i915 errors across this boot — both failure modes
journalctl -b 0 -k | grep -E "i915.*ERROR|PHY|flip_done|c10pll|DDI BUF|refclk"
journalctl -b 0 -k | grep -c "Failed to bring PHY A to idle"     # mode 3a
journalctl -b 0 -k | grep -c "PHY A failed to request refclk"    # mode 3b

# igc workaround firing per cycle
journalctl -b 0 -t igc-ptm-workaround | tail

# Resume duration = PM exit -> first user-session activity.
# Replace 6906 with your real gnome-shell PID:
#     pgrep -u "$USER" -x gnome-shell | head -1
journalctl -b 0 | awk '
  /PM: suspend exit/ { exit_t=$1" "$2" "$3; done=0; next }
  exit_t && /gnome-shell\[6906\]: DING:/ && !done {
    print exit_t " -> " $1" "$2" "$3; done=1; exit_t=""
  }'

# Previous boot (the one that ended in the hard reboot)
journalctl -b -1 -k | tail -100
```

Useful PCI / hardware state checks:
```bash
sudo lspci -s 86:00.0 -vvv | grep -A5 PTM       # NIC PTM caps + state
lspci -PP -s 86:00.0                             # parent root port (for PTM symmetry check)
cat /sys/power/mem_sleep                         # active suspend mode (should be [s2idle])
lspci -d ::0300 -nn; lspci -d ::0302 -nn         # the two GPUs
ls -la /sys/class/drm/card*/device/driver        # which card is which driver
for c in /sys/class/drm/card*-*; do
  echo "$(basename $c): $(cat $c/status 2>/dev/null)"
done                                              # connector status (eDP-1 should be 'connected')
```

---

## Measured effectiveness

All numbers below were measured in BIOS **Hybrid** mode on the original
2026-06 install; Discrete-mode reliability has no comparable dataset yet.

| | Before any mitigations | After PSR=0 + DC=0 + S0ix=1 + igc + PreserveVRAM=0 |
|---|---|---|
| Forced reboots due to dead GUI on resume | most long suspends | ~1 per 3 days |
| PHY-idle failure rate (mode 3a) | ~every long resume | 5 / 40 resumes (~12 %) |
| Worst observed unrecovered hang | indefinite (forced reboot) | 6:27 (self-recovered) |
| Typical resume time (PM-exit → desktop usable) | n/a (often never) | 7–10 s baseline, 15–18 s outliers |
| User-perceived "lid open → login screen" | n/a | ~5–10 s typical, occasionally 20+ s |

`i915.disable_power_well=0` was added later for failure-mode (3b)
specifically; its effectiveness across long-term use is still being
measured (it's the latest change as of this writing).

---

## Known residuals / open

- **`PHY A failed to request refclk` still occurs occasionally** even with
  all three i915 kernel params. Frequency much lower than the original
  PHY-idle path but not zero. The most recent fatal recurrence
  (2026-06-20) was the trigger for adding `disable_power_well=0`.
- **Long-suspend correlation** for residual failures is strong: every
  fatal mode-3a resume I measured followed a ≥35 minute suspend, none of
  the many short (seconds → few minutes) resumes ever failed. If the
  residual becomes unacceptable, the next escalation would be forcing the
  machine off s2idle entirely — but this Arrow Lake-HX SKU doesn't appear
  to support classic S3 in BIOS.
- **Newer kernels** would be the cleanest path to upstream fixes for the
  C10 PHY restore code. As of 2026-06-20 `apt list --upgradable` shows
  nothing newer than `7.0.0-22` in the 26.04 HWE archive.
- **The dGPU *can* rescue the panel — via the BIOS MUX (found
  2026-07-18).** BIOS Discrete mode moves eDP scanout to the NVIDIA card,
  sidestepping every residual i915 PHY failure above. What replaces it is
  unmeasured: panel resume then depends on the NVIDIA S0ix path
  (`nvidia-s0ix.conf` + `PreserveVideoMemoryAllocations=0` become
  load-bearing for the *panel*, not just externals). Watch the first
  weeks of long suspends in Discrete mode before declaring it the better
  trade.
- **Discrete mode + DisplayLink don't mix.** With the panel on the
  nvidia card, mutter picks it as primary/render GPU, and any DisplayLink
  (evdi) head degrades to an unaccelerated per-frame CPU readback —
  multi-second lag (mutter bug, Launchpad #1970291). Resolved by moving
  that monitor to a native output (laptop HDMI); avoid evdi heads while
  in Discrete mode.

---

## Shutdown / reboot: dGPU-teardown hang

A distinct lifecycle event from the four suspend modes above — this is a
**reboot**, not a suspend — but the same family: a power transition that
wedges in the GPU path and needs a hard power-off. Kept here because this is
the machine's canonical GPU-instability writeup.

**Symptom (first seen 2026-07-24):** `sudo reboot` with the lid **closed**
and two external monitors live on USB-C. Screen went dark (expected), then
the machine sat powered — keyboard backlight and power LED on — and never
reset. A forced power-off was the only way out.

**Where it hangs.** The journal for that boot ends cleanly ~8 s into the
reboot — userspace fully torn down (NetworkManager, logind, slices, all user
mounts) — and then goes dark as journald itself stops. The machine stayed
powered ~2.5 min more before the forced off. So the hang is in the **final
systemd-shutdown → kernel device `.shutdown()` → `reboot(2)` phase**, which
by construction is past where anything reaches disk. A clean reboot's journal
ends the same way; the tell is that the machine never reset and left no
record. This means the cause cannot be read out of the logs directly.

**Soft hang or panic: the evidence cannot tell.** `crashkernel=` was on the
cmdline (kdump armed), pstore is empty and no dump was written — but none of
that discriminates: the capture kernel was later proven to kexec and wedge
without writing or printing anything (see "kdump is disabled"), a DRAM
pstore record would not have survived the forced power-off, and
`kernel.panic` was 0, so a panicked machine would have sat powered and dark
exactly as observed. A driver stuck in uninterruptible teardown — a GPU
`.shutdown()` blocking with the framebuffer already gone (hence the dark
screen) — remains the simplest fit for a stop in this phase.

**Localized to the dGPU display path.** In Discrete mode every scanout engine
is the nvidia card: `card6` owns `eDP-1` (panel) plus the two USB-C externals
as native DP-alt (`DP-5`/`DP-6`). Lid closed = panel off, externals live, all
on the one dGPU; the teardown had to drop active dGPU scanout and the USB-C DP
links together.

**Ruled out.**
- *evdi / DisplayLink* — plymouth's reboot splash was seen cycling the four
  evdi cards, but those are **phantom**: evdi pre-creates four `DVI-I` cards
  whose connectors read `disconnected`, and no DisplayLink USB device is or
  was present. plymouth was probing dead cards, not scanning out on them. (A
  different problem from the *suspend*-time evdi lag under Known residuals.)
- *ZFS-root unmount / dracut pivot* — late userspace teardown and
  `dracut-shutdown.service` ExecStop both completed in the journal; nothing
  points here. (A missing `/run/initramfs/shutdown` binary mid-uptime is
  normal — dracut only restores it during the shutdown transition.)
- *FUSE / network* — the GoogleDrive mount unmounted cleanly; network torn
  down normally.

**Not provable from logs:** the exact failing callback — nvidia dGPU
`.shutdown()` vs the Thunderbolt/USB4 controller carrying the DP-alt links —
both live in the same unlogged final phase.

**Aggravating factor — a live driver upgrade earlier the same session.**
`unattended-upgrades` had bumped the whole NVIDIA stack 595.71.05 → 595.84
that morning *without a reboot*, so the running kernel module stayed
595.71.05 while userspace jumped to 595.84 ("NVRM: API mismatch" spam all
session; gnome-control-center was killed on it). A GPU stack half-swapped
under a live session is in a poor state to reset cleanly at reboot, and this
bleeding-edge Blackwell + open kernel module is fragile there to begin with.

### Mitigation: hold the NVIDIA stack out of unattended-upgrades

Repo `system/apt/52nvidia-unattended-hold`, installed by `provision` (non-WSL) to
`/etc/apt/apt.conf.d/52nvidia-unattended-hold`. It blacklists the NVIDIA
stack from the **automatic** path only, so the driver is never live-swapped
in the background; it now moves solely during a deliberate `apt upgrade` the
user follows with a reboot. Interactive apt is unaffected, and the file is
inert on a machine with no NVIDIA packages.

The blacklist entry is **`.*nvidia`**, not `nvidia`: unattended-upgrades
anchors each entry at the start (`re.match`; it builds an apt pin `/^entry/`),
so a bare `nvidia` matches only names that *begin* with nvidia and silently
misses `libnvidia-*`, `xserver-xorg-video-nvidia-*`, and
`linux-modules-nvidia-*` — the GL/compute and kernel-module halves that are
the split itself. Verified against u-u's own matching: `.*nvidia` holds 21/21
installed stack packages, `nvidia` only 8. The header comment in the file
carries this warning; do not "simplify" the pattern.

Trade-off: background *security* updates to the NVIDIA stack are deferred to
that manual upgrade. Accepted — a wedged reboot is worse.

### Reducing exposure without the fix

- Rebooting with the lid **open**, or with the USB-C monitors unplugged,
  leaves the dGPU fewer active scanout/DP links to tear down.
- The deeper lever is the same Hybrid-vs-Discrete trade the suspend notes
  weigh: Discrete puts every scanout on the fragile nvidia path (panel
  included); Hybrid keeps the panel on i915. No data yet on whether Hybrid
  reboots more reliably here.

---

## Idle hang: docked, lid closed, dGPU externals live

A third lifecycle event in the same family as the reboot hang above —
neither a suspend nor a reboot, but a power transition inside the dGPU
display path.

**Symptom (first seen 2026-07-25):** machine idle, lid closed, two 4K USB-C
DP-alt externals live. The monitors stayed lit showing a frozen image;
unplugging everything and opening the lid gave a black panel. It never
suspended afterwards and needed a forced power-off.

**Where it stops.** The journal ends mid-second and nothing follows — not
the 10-minute `sysstat-collect`, not `cron`, not `logrotate`. Everything
stopped being persisted at once, ~40 min before the forced power-off. No
kernel message precedes it: no Xid, no i915 error, no PCIe AER, no NVMe
timeout, no hung-task warning. The tell that this is system-wide rather
than a compositor freeze is the silence of the periodic timers, not any
error.

**Not resource exhaustion.** The `sar` sample from 2.5 min earlier has the
machine idle and healthy — ~27 % of 122 GiB used, zero swap-out, load 0.13,
no blocked tasks, 98 % idle CPU. The stop was sudden, not a degradation.

**Panic or soft hang: indistinguishable in hindsight.** pstore was empty
and no vmcore was written, but neither absence carries weight: kdump was
later proven structurally unable to save (see below), a DRAM pstore record
would not have survived the forced power-off, and `kernel.panic` was still
0 at the time, so a panicked machine would also have sat wedged with lit
screens. The capture stack below exists to remove exactly this ambiguity.

**Frozen-but-lit is a hung modeset.** A CRTC keeps scanning out its last
framebuffer when nothing updates it, so monitors holding a still image is
what an atomic commit that never completes looks like. The final line
written is a Wayland client's swapchain going `VK_ERROR_OUT_OF_DATE_KHR` —
an output reconfiguration beginning on an otherwise idle desktop, 16 min
after the last window interaction.

**Two candidate triggers, neither provable from the logs.**
- *A display power transition on the USB-C DP links.* Same topology as the
  reboot hang: Discrete mode, so `card6` owns `eDP-1` plus `DP-5`/`DP-6`;
  lid closed, panel off, externals live. GNOME's idle blank disables those
  same CRTCs and `idle-delay` is 900 s, which places a blank within a
  minute or so of the stop. GNOME does not log blanking, so the timing is
  consistent rather than confirmed.
- *NVIDIA VA-API decode.* `nvidia-vaapi-driver` and the Chrome desktop
  override adding `--enable-features=VaapiOnNvidiaGPUs` went in ~3 h
  earlier, and the browser session running at the time was the first with
  NVDEC decode active. This cannot be the whole story — the reboot hang
  predates it — but it is a live second path into the same stack.

**Why nothing more can be said:** a wedged machine cannot write its own
journal, so neither the failing callback nor even whether the kernel
hard-locked or merely blocked on I/O survives the reset. Closing that gap
is what the next section is for.

---

## Crash capture

Both hangs above left nothing behind, structurally: a machine that has
stopped making progress cannot flush its journal, and a forced power-off
then erases whatever was held in RAM. Four mechanisms are installed so the
next one is recorded. All reversible; each installed file states its own
revert steps.

Flushing the journal harder is deliberately *not* among them. Entries reach
the mmap'd journal file immediately and land on disk at ZFS txg commit, so
the exposure from deferred `fsync` is seconds — and when the write path is
what wedged, syncing more often cannot complete either.

| | Mechanism | Files | Fires on |
|---|---|---|---|
| 1 | Panic triggers, turning a silent wedge into a panic — and so into a pstore record and a self-reboot | `/etc/sysctl.d/60-crash-capture.conf` | tasks stuck in D state, or a CPU spinning with IRQs off |
| 2 | iTCO hardware watchdog | `/etc/default/grub.d/watchdog.cfg`, `/etc/systemd/system.conf.d/10-watchdog.conf` | PID 1 stops petting — a wedge nothing else detects |
| 3 | panic dmesg tail into UEFI NVRAM (`efi_pstore`) | `/etc/default/grub.d/pstore.cfg` | panic/oops; archived to `/var/lib/systemd/pstore/` on the next boot |
| 4 | netconsole stream off the machine | `/etc/modules-load.d/netconsole.conf`, `/etc/NetworkManager/dispatcher.d/50-netconsole` | every printk, in real time |

**Read crash records from `/var/lib/systemd/pstore/`, not `/sys/fs/pstore`.**
`systemd-pstore.service` archives and deletes everything in the mount within
seconds of boot (which also keeps the EFI variable store from filling). An
empty `/sys/fs/pstore` after a crash means nothing until the archive has
been checked. EFI dmesg records arrive as ~1 KiB parts that systemd groups
into per-timestamp directories, each with a reassembled `dmesg.txt`.

**The panic chain is verified end to end (2026-07-26):** a deliberate sysrq
panic self-rebooted in exactly 60 s with no watchdog involvement, and the
next boot's archive held the full `Panic#1` record — banner, sysrq
backtrace and tail. (The sysrq trigger works despite `kernel.sysrq=176`
lacking the `SYSRQ_ENABLE_DUMP` bit, because writes to
`/proc/sysrq-trigger` bypass the mask.)

### kdump is disabled — a broken capture kernel is worse than none

**Do not re-enable kdump without first fixing the capture kernel.** A
deliberate `echo c > /proc/sysrq-trigger` kexec'd into it, and it then wrote
nothing, printed nothing to the console, and never rebooted; the machine had
to be recovered with a forced power-off after 15 minutes.

That failure is not neutral, it is destructive. A loaded crash kernel is
entered *before* `kmsg_dump()` in the panic path, so when it hangs, no
pstore record of the panic gets written on any backend — and the machine
then needs a power-button hold. An enabled-but-broken kdump therefore
intercepts the panic and suppresses the evidence that would otherwise have
survived. With `USE_KDUMP=0` the panic instead runs the full dump path and
falls through to `kernel.panic=60`. **Verified 2026-07-26: a sysrq panic
self-reboots in exactly 60 s, unattended.**

What is known: the kexec itself works (the screen blanked ~10 s in, which is
the capture kernel taking over the display) and the dump target below is
sound. What is unknown is anything about why the capture kernel stops,
because it produced no output on any channel. Each diagnostic attempt costs
a panic and a forced power-off, so this is not worth chasing while
`efi_pstore` and netconsole cover the same ground.

### Dump target: dedicated ext4 partition

kdump reported `ready to kdump` for a long time while being **structurally
unable to save anything**. `/var/crash` lived on the encrypted ZFS root, and
the capture initrd — which is initramfs-tools, not the dracut initrd the
machine actually boots from — carries `zfs.ko` but no `zpool`/`zfs`
userspace, no zfs-import units and no `cryptsetup`. It could never import or
unlock rpool, so it could never reach `/var/crash`. Nothing in its output
said so.

Fixed by giving it a target that needs no pool and no key. `nvme0n1p3` was an
8 GiB `/dev/urandom`-keyed plain dm-crypt swap device sitting at 0 B used
between bpool and rpool; with 122 GiB of RAM and no hibernation it was doing
nothing. It is now the dump partition, and the machine runs swapless.

    nvme0n1p1   1 GiB   vfat  /boot/efi
    nvme0n1p2   2 GiB   zfs   bpool
    nvme0n1p3   8 GiB   ext4  kdump      <- was encrypted swap
    nvme0n1p4   1.8 TiB zfs   rpool

**rpool was never touched, and could not have been.** ZFS has no shrink at
any level: labels L2/L3 live at the end of the vdev and the label records its
`asize`, so truncating that partition destroys the pool. Booting a live USB
does not change this — the only way to shrink rpool is backup, destroy,
recreate, restore.

Why ext4 specifically, and not a "better" filesystem: it is the only
journalled filesystem compiled into the kernel (`CONFIG_EXT4_FS=y`). XFS,
btrfs, f2fs, jfs and nilfs2 are all modules and **none are present in the
capture initrd**; adding one puts a module in the exact path that must not
fail. vfat is built in but caps files at 4 GiB with no journal. Decisively:
**the capture initrd contains no fsck of any kind**, so the dump filesystem
must always mount without repair.

That last point drives the mount policy, which matters more than the
filesystem choice: the partition is **`noauto` and stays unmounted in normal
operation**, so the capture kernel meets a clean filesystem every time and
never depends on journal replay. Mount `/mnt/kdump` by hand to read dumps.

Made with `mkfs.ext4 -m 0 -T largefile` — no root reserve, and ~8 K inodes
instead of ~524 K, since this volume holds a handful of huge files. Worth
~600 MB of the 8 GiB. The journal is kept deliberately: it protects a
partially written dump if the watchdog resets the machine mid-write.

`KDUMP_COREDIR` stays `/var/crash` and resolves differently in each context —
on rpool for the running system's lock/stamp files, and on the dump partition
for the capture kernel, which mounts it as its root. Dumps therefore appear
at `/mnt/kdump/var/crash/<stamp>/`.

**A vmcore on an unencrypted partition is a disclosure surface.** `-d 31`
excludes user pages, but kernel memory is where the ZFS encryption key lives
while the pool is unlocked. Anyone with physical access to the SSD can read a
dump that the encrypted root would otherwise have protected. Treat dumps as
short-lived: pull what you need, then wipe.

Constraints worth knowing before changing any of it:

- **The watchdog timeout is a lower bound on recovery, not the actual one.**
  The Intel TCO timer is two-stage: the configured value elapses once to
  raise the condition and again before the platform asserts reset, so the
  real worst case is roughly double. A 600 s setting was observed not to
  reset a wedged machine within 15 minutes, which is what that doubling
  looks like. Now set to 120 s. The ceiling for a single stage is 614 s.
- **`iTCO_wdt` must be loaded from the initramfs, not `modules-load.d`.**
  The kernel package blacklists it in a kernel-versioned
  `/lib/modprobe.d/blacklist_linux_*.conf` (replaced on every kernel update,
  so never edit it), and `systemd-modules-load` honours that denylist and
  silently skips the module. Independently, systemd opens `/dev/watchdog`
  during early startup — before `systemd-modules-load` runs — and if it is
  absent it logs `Failed to open any watchdog device before the initial
  transaction completed` and never retries for that boot. `rd.driver.pre=`
  solves both: it is handled in the initramfs by a plain `modprobe` with no
  `--use-blacklist`, early enough that PID 1 finds the device. A blacklist
  only suppresses alias-driven autoloading; an explicit request by module
  name still works, which is why loading it by hand appears to work and
  proves nothing about the next boot.
- **`hung_task_timeout_secs` is raised to 300 s from its 120 s default.**
  FUSE and network mounts can legitimately hold a task in D state for a
  couple of minutes, and panicking on that trades a recoverable stall for a
  reboot. A real deadlock never clears.
- **ramoops cannot work on this machine; do not bring it back.** The
  firmware zeroes all of DRAM during POST after a *dirty* reset — panic
  `emergency_restart()`, watchdog, power-button — and preserves it only
  across a clean reboot. Established by experiment: a reserved region came
  back byte-identical (headers, then a whole shutdown record) across clean
  reboots, and uniformly zero-filled after a panic reset, while stopwatch
  timing proved the panic path itself ran to completion. Uniform zeros are
  the DDR5 ECC-init scrub, and clean-reboot-only survival means reserved
  DRAM dies on exactly the resets a crash produces. No kernel setting can
  change this; it happens before the kernel gets control.
- **The panic write path itself is sound and proven** — kmsg dump, deflate,
  pstore write and next-boot readout all verified end to end. Only the
  storage medium was wrong.
- **`pstore.kmsg_bytes` is capped at 16 K** because the EFI variable store
  is small (244 K total, ~65 K free on this firmware) and each dump part
  costs a ~1 KiB variable. 16 K of dmesg tail still holds the panic banner
  and backtrace. systemd-pstore deletes the variables after archiving, so
  the store self-cleans between crashes.
- **netconsole only streams on the receiver's own segment.** It addresses
  the receiver by MAC, so it cannot ride Tailscale or any routed path. The
  dispatcher enables the target only while this machine holds a `10.0.x.x`
  address, and disables it otherwise. This is sufficient because the hangs
  happen docked, and docked is that segment.

The receiver lives on **pdietl-thinkstation** (`10.0.100.3`,
`d8:43:ae:eb:ca:61`): `netconsole-receiver.service` writes timestamped
lines to `/var/log/netconsole/pdietl-laptop.log`, capped at 20 rotations of
1 GiB by `/etc/logrotate.d/netconsole` and checked hourly by
`netconsole-logrotate.timer`. Its `/var/log/netconsole` is created by
`/etc/tmpfiles.d/netconsole.conf`, not by `LogsDirectory=`, because systemd
opens `StandardOutput=append:` before it creates a unit's `LogsDirectory`.

The prepended timestamp is **arrival time on the receiver**, not emission
time; netconsole's extended format carries the kernel's own sequence number
and monotonic clock inside each message. They are different clocks — do not
correlate them as one.

### Verification still owed

Configured but unproven, and an unproven capture path is worse than none:
it makes the next hang look instrumented when it is not.

- **netconsole has only been proven as far as the NIC** (target enabled,
  `transmit_errors` zero) and the receiver only over a userspace datagram.
  The L2 hop can only be tested while docked: check that the dispatcher
  logged a target, then confirm lines arrive on the receiver.

One behaviour to watch on the first long suspend: `iTCO_wdt` carries
`suspend_noirq`/`resume_noirq` hooks that stop the counter across sleep, so
an armed watchdog should not reset a suspended machine — but confirm it
once rather than assume it.

---

## Investigation chronology (for context)

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
- **2026-07-18** — the T16's NVMe (this doc's install) moved into this
  chassis. Installed `nvidia-driver-595-open` + `prime-select nvidia`,
  then flipped BIOS Config → Display → Graphics Device from Hybrid to
  **Discrete** — discovering the eDP MUX the June investigation had
  concluded didn't exist (panel verified on the nvidia DRM card). Fallout:
  a DisplayLink dock head became ~5 s laggy (evdi + NVIDIA-primary CPU
  readback; see Known residuals) and was replaced with a direct HDMI
  connection at native 2560x1440@120. Discrete-mode suspend reliability
  under observation from this date.
- **2026-06-24** — the suspend storm returned (97 failed suspends / ~30 min) but
  the logs showed a *new* cause: 2 `pool-*` threads stuck in `fuse_statfs` on the
  `google-drive-ocamlfuse` mount (S0ix=1 was live, so not mode 2). Root-caused to
  the driver's blocking `statfs`→metadata-refresh path (upstream #896); patched
  `statfs` to be non-blocking, built + installed to `/usr/local/bin`, removed the
  deb. See failure mode 4 and its mitigation above. (Same session: redirected
  tailscaled+Slack journal spam, fixed geoclue/cups-browsed apparmor denials,
  disabled the nvidia-powerd SEGV crash-loop, masked orphaned PCP services.)
- **2026-07-24** — first **reboot** (not suspend) hang: `sudo reboot` with the
  lid closed and two USB-C externals live wedged in the final GPU-teardown
  phase — dark screen, power on, hard power-off. Localized to the dGPU display
  path (all scanout on the nvidia card in Discrete mode); evdi cards cleared as
  phantom; soft hang, no kdump. Aggravated by an unattended-upgrades NVIDIA
  bump (595.71.05 → 595.84) applied earlier that session with no reboot,
  leaving a running-module/userspace split. Mitigation: `system/apt/52nvidia-
  unattended-hold` holds the stack from the automatic path. See the
  "Shutdown / reboot" section above.
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
  capture" above; three verification steps are still owed there.
- **2026-07-26** — preparing to prove kdump revealed it had never been able to
  work here: `/var/crash` sits on the encrypted ZFS root and the capture
  initrd has no zfs userspace and no cryptsetup, so it could not reach the
  target it reported being ready to write. Removed swap entirely (122 GiB RAM,
  no hibernation) and converted its 8 GiB partition into a plain ext4 dump
  target, with `KDUMP_CMDLINE` booting the capture kernel there rather than at
  rpool — no pool import, no key, no filesystem module. rpool was untouched
  and cannot be shrunk regardless. See "Dump target" above.
  A deliberate sysrq panic that evening then showed the capture kernel is
  broken independently of its target: it kexec'd, wrote nothing, printed
  nothing and never rebooted. kdump disabled as a result — see "kdump is
  disabled" above for why leaving it on is actively harmful. The watchdog
  also failed to recover the machine inside 15 minutes at a 600 s setting,
  consistent with the TCO's two-stage timer doubling it; now 120 s. The
  forced power-off invalidated the firmware's memory training, so the next
  POST did a full retrain (several minutes, keyboard LED activity); both
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
