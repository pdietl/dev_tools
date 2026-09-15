# ThinkPad P16 Gen 3 — external displays over USB-C (DisplayPort MST)

Current state of what is known about driving external monitors from this
laptop's USB-C ports under Ubuntu 26.04 / GNOME Wayland / NVIDIA 595, in BIOS
Discrete mode (the dGPU owns every output, including the panel). The dGPU
scanout-allocation refusal on lid/hotplug events is a different problem and
lives in `thinkpad-p16-gen3-ubuntu-suspend.md`. How these conclusions were
reached, including the ones later refuted, is in
`thinkpad-p16-gen3-ubuntu-external-displays-chronology.md`.

---

## How the port behaves

The USB-C ports are Thunderbolt 5 (Intel JHL9580 "Barlow Ridge"). A monitor
that is not a Thunderbolt/USB4 device gets **DP Alt Mode**: native DisplayPort
on the SuperSpeed pairs, negotiated over USB PD. Which pin assignment the
monitor asks for decides the video budget:

| Monitor's USB-C data setting | DP lanes | USB data | 4-lane HBR3 payload |
|---|---|---|---|
| "USB 2.0" (BenQ) / "High Resolution" (Dell) | 4 | USB 2.0 only | 25.9 Gbps |
| "USB 3.2" / "High Data Speed" | 2 | USB 3.x | 13.0 Gbps |

**Tell-tale from the host, no OSD needed:** look at what enumerates behind the
port. A hub at 480 Mbps with no SuperSpeed companion means DP has all four
lanes. A 5 or 10 Gbps hub means DP has two. (`lsusb -t`; the Type-C port a
device sits behind is the `connector` link under its USB port in sysfs.)

The link rate is capped by the monitor, not the cable: a DP 1.4 sink trains at
HBR3 at most, and no cable adds UHBR. A better cable only matters if the
present one is USB 2.0-only (no SuperSpeed pairs, Alt Mode cannot come up at
all) or is dropping the link to HBR2.

## Home office: two BenQ RD280UG daisy-chained on one cable

Cabling per BenQ's quick-start: laptop → monitor 1's upstream USB-C, monitor 1's
USB-C out → monitor 2's upstream USB-C.

- **MST ships OFF, and off means mirror.** With MST off the USB-C out is a
  plain repeater: the GPU sees one sink and GNOME can only clone. Enable it on
  monitor 1 only: **Menu > Coding Booster > MST > ON**. Monitor 2 is the end of
  the chain and needs nothing.
- **Keep USB-C Configuration on USB 2.0** on both monitors (four DP lanes).
  The monitors' hubs (Realtek RTS5423) then enumerate at 480 Mbps through
  monitor 1, which is the expected tell above.
- After MST is on, the NVIDIA driver sees branch `0.1`, monitor 1 as sink
  `0.8` and monitor 2 as `0.1.1`; the connectors renumber (`DP-5` became
  `DP-7` for monitor 1 and `DP-8` for monitor 2). mutter's saved config keys
  on EDID serial, so the renumbering is harmless.

### Refresh-rate budget (driver 595.91.07, verified)

The driver does DSC over MST at a **fixed 10 bpp per stream** (16 bpp when one
stream has the link alone) and allocates MST time slots out of 63:

| Stream at 3840x2560 | Slots |
|---|---|
| 120 Hz | 33 |
| 100 Hz | 28 |
| 60 Hz | 17 |

| Direct + chained | Slots | Result |
|---|---|---|
| 120 + 100 | 61 | works |
| 100 + 100 | 56 | works |
| 120 + 60, 60 + 120 | 50 | works |
| 120 + 120 | 66 | rejected (`drmModeAtomicCommit: Invalid argument`) |

The chained monitor takes a 120 Hz stream fine, so the monitor-to-monitor hop
is not a limit. BenQ's own table promises 120 + 120; that needs 8 bpp DSC,
which this driver does not choose. Two links (a second cable to the other
port) is the only 120 + 120 path. The EDID offers 120, 100, 60 and 50 Hz at
native resolution; there is no supported way to add a timing on Wayland with
this driver, so "110 Hz" is not an option even though it would fit the budget.

**Configured:** 100 Hz on both, persistent (mutter's `monitors.xml`). Any
pair from the table can be set in Settings > Displays, but see the next
section before believing the result. A verified way to set a pair and keep it:

```sh
gdctl set -P \
    --logical-monitor --primary --x 2880 --y 0 --scale 1.3333333730697632 \
        --monitor DP-7 --mode 3840x2560@100.032 \
    --logical-monitor --x 0 --y 0 --scale 1.3333333730697632 \
        --monitor DP-8 --mode 3840x2560@100.032
kms-actual
```

## mutter reports the request, not the result

mutter validates a change with a test commit and then posts the real one.
The NVIDIA driver only checks MST bandwidth in the real commit, so the test
passes, the real commit is rejected, and mutter keeps the requested mode in
its model. Settings, `gdctl show`, Xwayland's `xrandr` and `monitors.xml`
then all agree with each other and are all wrong; the only sign is one
`Failed to post KMS update: drmModeAtomicCommit: Invalid argument` line in
gnome-shell's journal. Truthful read-backs are the kernel's atomic state
(`kms-actual`, or `/sys/kernel/debug/dri/<card>/state` as root) and the
monitor's own OSD information page. Re-applying a valid pair resyncs mutter.

## Failure mode: closed-lid unlock leaves the panel lit, then every mode-set fails

**Symptom.** Every display change is rejected with the `Invalid argument`
line above, including re-applying a configuration that worked minutes ago.
Bandwidth reasoning goes nowhere because nothing fits any more.

**Mechanism.** On screen unlock with the lid closed, mutter lit `eDP-1` on a
CRTC, then its commit to turn the panel back off was rejected and it never
retried. The kernel keeps `eDP-1` active on that CRTC; mutter believes the
panel is off and the CRTC free. Every later commit unlinks `eDP-1` from a
CRTC mutter does not know is live without disabling the CRTC, and the DRM
core refuses the whole commit:

```text
[drm:drm_atomic_helper_check_modeset] [CRTC:82:crtc-1] enabled/connectors mismatch (1/0)
[drm:drm_atomic_check_only] atomic driver check for ... failed: -22
```

(Seen with `drm.debug=0x16`; `/sys/module/drm/parameters/debug` is root-only
to read as well as write, so save and restore it with root.)

**Diagnosis.** `kms-actual` shows `eDP-1` driven while the lid is closed, or a
`STALE` CRTC, and flags the mutter mismatch. Check this before any bandwidth
theory.

**Remedy.** mutter cannot be told to fix it (`gdctl set` with the panel
included answers "Refusing to activate a closed laptop panel"). Open the lid
until the panel lights, then close it: mutter then owns the CRTC and disables
it explicitly. Otherwise replug the monitor's USB-C, which makes mutter
re-read the kernel state on hotplug, or log out and in.

## Tools

- **`bin/kms-actual`** (installed to `~/bin` by `provision`): per connector,
  the CRTC and the mode the kernel is actually driving, a `STALE` line for any
  CRTC enabled with no connector, and mutter's belief with each disagreement
  marked `MISMATCH`. Exit 1 on any problem, so it doubles as an assertion.
- `nvidia_modeset debug=1` (hand-applied,
  `/etc/modprobe.d/nvidia-modeset-debug.conf`) is what makes the driver log
  MST topology, DSC mode and the
  `Requesting allocation Stream:N | Count:` slot lines; the NVIDIA connectors
  expose no DPCD or AUX device, so that log is the only view of the link.
