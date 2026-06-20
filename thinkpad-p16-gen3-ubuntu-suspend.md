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
| Intel Arrow Lake-S iGPU | `00:02.0` | `i915` | Drives the internal eDP-1 panel + 4× DP outputs |
| NVIDIA RTX PRO 1000 Blackwell | `01:00.0` | `nvidia` | Drives only external HDMI/DP — disconnected when docked-less |
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

**Key topology fact:** the internal laptop panel is **hard-wired to the
Intel iGPU**, not to the NVIDIA dGPU. The dGPU has only external outputs.
So no PRIME mode and no "always use the dGPU" workaround can bypass the
i915 KMS path for the laptop screen — a BIOS MUX would be needed and this
SKU doesn't appear to expose one.

---

## Three distinct failure modes

Two are cosmetic; one is the catastrophic "screen is on but no GUI ever
appears, must hard-reboot" symptom.

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

The eDP panel is wired to the iGPU. On suspend the iGPU enters a deep
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

---

## Mitigations applied (current working set)

All reversible. Each file has a header comment explaining itself so a
future reader of the system finds the rationale in-place.

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

On a clean 26.04 install on this hardware:

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
- **The dGPU cannot rescue the panel** — see "Hardware / OS baseline"
  above. The only way to bypass i915 KMS for the laptop screen is a
  BIOS-level eDP MUX, which this SKU doesn't expose. PRIME modes (hybrid
  / on-demand / performance) don't help because the panel scanout still
  goes through i915 regardless of which GPU does rendering.

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
