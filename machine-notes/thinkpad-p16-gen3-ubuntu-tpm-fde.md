# ThinkPad P16 Gen 3 — Ubuntu TPM-backed full-disk encryption

Current state of what is known about Ubuntu 26.04's hardware-backed encryption
(snapd/secboot sealing the disk key to the TPM) on this model. Established on a
second P16 Gen 3 unit (`21RQCTO1WW`, BIOS N4FET49W 1.30) installed with Ubuntu
26.04.1; `pdietl-laptop` itself runs a ZFS root without it. How the conclusions
were reached, including the ones later refuted, is in
`thinkpad-p16-gen3-ubuntu-tpm-fde-chronology.md`.

---

## Symptom

A fresh install with "Use hardware-backed encryption" asks for the passphrase
and then the recovery key on every boot. The initramfs journal shows, for both
TPM keyslots:

```text
snap-bootstrap: Error with keyslot "default": cannot recover keys from keyslot:
incompatible key data role params: invalid PCR policy data: cannot complete
authorization policy assertions: the PCR policy is not authorized for the
current configuration
```

snapd reseals after every boot (`reseal-count` in
`/var/lib/snapd/device/fde/boot-chains` climbs by one each time) and nothing
changes. Firmware updates, `snap changes` repairs and re-entering the
passphrase do not help.

## Cause

The sealed policy covers PCRs 0, 2, 4, 7 and 12. secboot predicts PCR 2 by
replaying the TPM event log up to `EV_SEPARATOR` and stopping
(`efi/fw_load_handler.go`, `measureDriversAndApps`). This firmware loads one
more `EV_EFI_BOOT_SERVICES_DRIVER` into PCR 2 after the separators and before
it verifies shim: the file `AbtAgentInst` in Lenovo's firmware volume, GUID
`821aca26-29ea-4993-839f-597fc021708d`, 24 KB, the **Absolute Persistence
Module** (Computrace) agent installer. It is measured identically on every
boot, so every reseal produces a policy the TPM can never match. The
pre-install check stops at the separator too, so the installer accepts the
platform. The same file GUID and digest appear on the E16 Gen 1 and X1 Yoga
Gen 8; on AMD ThinkPads an AGESA event plays the same role.

Nothing on the Ubuntu side can be configured around it: the shim is verified
through the Microsoft UEFI CA 2011, which secboot distrusts for drivers, so
PCR 2 is mandatory and the `trust-authorities-for-addon-drivers` option is
rejected. A shim verified through the 2023 CA would drop PCR 2 automatically.

## Fix

**Security ▸ Absolute Persistence Module ▸ Disabled.** Not "Permanently
Disabled", which cannot be undone. The boot manager then no longer loads the
driver, the boot right after the change still needs the recovery key (the
policy from the previous reseal expects the old PCR 2), snapd reseals during
that boot, and the following boot unseals with the passphrase alone.
Re-enabling Absolute brings the recovery-key prompt straight back. Ship state
is Enabled, and it is dispatched even when Absolute reports "Not Activated".

Startup ▸ Boot Mode (Quick/Diagnostics) has no effect on this driver.

Upstream: canonical/secboot issue 570 tracks the class
(https://github.com/canonical/secboot/issues/570); pull request 556 is the
intended fix. Once a snapd carrying it ships, Absolute can be re-enabled.

## What the policy holds, and what is normal

| PCR | Sealed prediction | Note |
|---|---|---|
| 0 | log replay, starting at locality 3 | reconstructs from the log |
| 2 | log replay **up to the separator** | the mismatch above |
| 4 | shim, seed GRUB, boot GRUB, kernel.efi | Authenticode digests of the assets |
| 7 | Secure Boot variables, db authority, SbatLevel, MokListRT | reconstructs from the log |
| 12 | command line (UTF-16 + NUL), epoch `H(u32 0)`, model digest | see below |

PCR 12 read after boot is the sealed value extended once more with a
four-zero-byte fence: snap-bootstrap locks the sealed keys after mounting
(`BlockPCRProtectionPolicies`). That later value never matches the policy and
is not a fault. The `default-fallback` keyslot logs a policy error on every
normal boot; it is sealed for recovery mode and cannot match in run mode.

## Checking any boot

`tpm-fde-probe user@host` (in `bin/`) pulls the event log, PCR values, LUKS
tokens and boot-chains from a machine over SSH and reports how many drivers
follow the PCR 2 separator and whether the policy resealed on that boot matches
the live registers. `tcglog.py` prints an event log with certificates decoded;
`tpm-policy-match.py` recomputes the PolicyOR branches from a token and names
the register that was mispredicted; `tpm-fde-diag.sh` gathers the journal and
fwupd evidence on the target. Passwordless sudo on the target is needed for
the token and log reads.

## Related: the installer's "manufacturing mode" warning

The installer showed `NO_HARDWARE_ROOT_OF_TRUST … checking Intel BootGuard
configuration … system is in manufacturing mode` on this platform, and then
required a PIN or passphrase. That is a false positive: secboot's CSME 18+ check
requires HFSTS6 bit 21 (MfgLock), which stays clear on fused Lenovo units that
use Intel's Flexible EOM (on this unit HFSTS6 is `0x40000000`, HFSTS1
`0x90000245`), while fwupd reads the same registers and reports Boot Guard
enabled and manufacturing mode locked. fwupd removed its equivalent test in
2025. Reported as https://github.com/canonical/secboot/issues/572. "Ignore and
continue" is the right answer; a passphrase is wanted on a laptop anyway.
