# ThinkPad T16 Gen 4 — investigation chronology

How the conclusions in `thinkpad-t16-gen4-ubuntu-suspend.md` were reached,
session by session. Entries are snapshots and may be refuted by later ones;
the main doc holds present state. Read this file only for the provenance of
a conclusion, never as a source of facts to act on.

- **Jun 25–29 2026** — 8 freeze-failure suspends across 49 cycles, all
  `fuse_statfs` (unnoticed at the time; found retroactively).
- **2026-07-12** — quick-unplugged USB hub / HDMI / power / ethernet
  (Wi-Fi disabled) at 11:10:44 with a Drive read in flight; the
  on-battery idle suspend fired 14 s later and every freeze attempt
  failed on `fuse_do_getattr`/`fuse_file_read_iter`. Hard power-off at
  11:13. Root-caused the same day; wrote `gdfuse-suspend-guard`, added
  hardware-gated suspend mitigations to `provision`, and created the main
  doc.
- **2026-07-12 (later)** — while routing journal spam to files
  (`system/journal-hygiene/`), found LocalSearch recursively indexes all of
  `$HOME` on 26.04 and had the Drive mount in scope — the probable
  in-flight reader above. Excluded `mnt` from its `ignored-directories`.
