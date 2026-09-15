# ThinkPad P16 Gen 3 — TPM-backed FDE: investigation chronology

How the conclusions in `thinkpad-p16-gen3-ubuntu-tpm-fde.md` were reached.
**Entries are snapshots, and later entries refute earlier ones.** The main doc
holds present state; read this only for the provenance of a conclusion.

- **2026-09-14 18:20** — installer on a fresh P16 Gen 3 reported the platform
  had no hardware root of trust ("system is in manufacturing mode"). Taken at
  face value: a Lenovo warranty defect, with a firmware update as the first
  post-install step. Refuted the same evening by `fwupdmgr security` on the
  installed system (Boot Guard enabled, ACM and OTP fuse valid, manufacturing
  mode locked) and by reading secboot's CSME 18 check against the raw HFSTS
  registers: it demands a bit Lenovo does not set.
- **18:31, 18:42** — first and second boots both fell back to the recovery
  key. Hypotheses in play: a firmware setting changed between install and boot,
  the TPM in dictionary-attack lockout, snapd unable to reseal after a
  recovery-key unlock because the primary key was missing from the kernel
  keyring (a log line said exactly that on the first boot). The third boot
  failed after a reseal had demonstrably run, which killed all three.
- **19:00–19:15** — PCR values and every logged event were byte-identical
  across boots, so the firmware was deterministic and the prediction wrong for
  a stable value. The PCR selection (0, 2, 4, 7, 12) was read out of the LUKS
  token's sealed policy data. Candidate mispredictions for PCR 0 (startup
  locality), PCR 7 (SBAT level "latest" vs "previous", the MokListRT authority
  event's variable name) were tested against the PolicyOR branches with no
  match, then the session ended.
- **2026-09-15 08:30** — the laptop's scratch data had been wiped by a reboot;
  everything was re-collected. Suspected next: PCR 4, because the seed shim is
  dual-signed and the Authenticode hash of a UKI is easy to get wrong. Refuted:
  an independent implementation (`systemd-pcrlock lock-pe`) reproduced every
  PCR 4 digest the firmware and shim logged.
- **08:45** — suspected PCR 12 next, on the theory of version skew between the
  OS snapd and the snap-bootstrap inside the kernel initrd, which is built from
  a separate module. The measured PCR 12 did not equal command line, epoch,
  model as secboot defines them. Partly wrong: the difference is the post-unlock
  fence secboot extends into PCR 12 after mounting, and at unlock time the
  register is exactly as predicted. The false lead was useful: it forced an
  exact reimplementation of the epoch and model digests, which the final match
  depended on.
- **09:00** — validated the branch-digest method using the recovery-mode
  branches, whose inputs are fully known; they did not match either, which
  meant a register shared by every chain was wrong. An exhaustive cross-product
  over all five PCRs matched all 13 branches of both tokens only with PCR 2
  replayed up to the separator. The event log showed one driver after it. The
  PCR 2 profile code confirmed it stops at the separator by design.
- **09:26** — Boot Mode Diagnostics changed nothing: same seven PCR 2 events,
  same values. Meanwhile the BIOS 1.30 package from LVFS, parsed with
  uefi-firmware-parser, named the file `AbtAgentInst`: Absolute's agent
  installer.
- **09:31** — Absolute Persistence Module set to Disabled. That boot needed the
  recovery key once (old policy), reported zero drivers after the separator,
  and the reseal it triggered matched the live registers. The next boot
  unsealed with the passphrase.
- **09:40** — upstream already had the class as canonical/secboot#570, opened
  six days earlier, including another reporter's Absolute finding from the day
  before. Added the P16 data point, the driver's name from the firmware image
  and the sealed-policy verification there; filed the manufacturing-mode false
  positive as #572, since it existed only in comments on unrelated issues and
  fwupd had dropped the same test in January 2025.
