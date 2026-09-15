# ThinkPad P16 Gen 3 — external displays: investigation chronology

How the conclusions in `thinkpad-p16-gen3-ubuntu-external-displays.md` were
reached. **Entries are snapshots, and later entries refute earlier ones**:
two bandwidth explanations below were believed and written down before being
disproved the same night. The main doc holds present state; read this only
for the provenance of a conclusion.

- **2026-09-14 evening** — two new BenQ RD280UG daisy-chained from one USB-C
  port showed as one mirrored display. Kernel saw one DP sink and no MST
  branch; USB showed monitor 2's hub reachable through monitor 1's at
  480 Mbps only, proving the chain cable was right and the link four-lane.
  BenQ's RD280U manual gives the missing step: MST is off by default and
  enabled per monitor in the OSD. Turning it on produced two displays.
- **21:28** — first working pair was 120 (direct) + 60 (chained). A request
  for 120 + 120 was rejected. The driver's slot log gave 33 slots per
  120 Hz stream, 17 per 60 Hz; the "66 > 63 slots" explanation was formed
  here and turned out correct, but at this point it was one data point.
- **23:08** — screen unlock with the lid closed lit `eDP-1` on a CRTC and
  mutter's commit to turn it off failed. From here on every mode-set was
  rejected regardless of content. Not noticed at the time.
- **23:09–00:00** — 60 + 120 and 120 + 100 were requested and rejected. Read
  as bandwidth evidence, this produced the false conclusion that the
  monitor-to-monitor hop was two-lane and could not carry a 120 Hz stream;
  it was written into memory. The tell that broke the story: re-applying
  120 + 60, which had worked at 21:28, was rejected too.
- **00:00** — `drm.debug=0x16` on one attempt gave the real reason:
  `[CRTC:82:crtc-1] enabled/connectors mismatch (1/0)`; the debugfs atomic
  state showed `eDP-1` active on crtc-1 while mutter believed it off.
  `gdctl` cannot heal it ("Refusing to activate a closed laptop panel").
- **00:10** — lid opened and closed; the kernel state became consistent and
  mutter's stored 60 + 120 config applied on its own, which by itself
  disproved the hop theory (the chained monitor at 120 Hz).
- **00:12** — clean-state tests: 120 + 100 (61 slots) and 100 + 100 (56) work;
  120 + 120 (66) still rejected. Slot budget at the driver's fixed 10 bpp is
  the whole explanation. Set 100 + 100 persistently.
- **Refuted and retired:** "the second hop is two-lane"; "any rejection after
  23:08 says anything about bandwidth". Kept: MST off means mirror; four
  lanes proven from USB enumeration; 63-slot budget at 10 bpp; mutter
  reports requests, not results; closed-lid unlock desync and its remedy.
