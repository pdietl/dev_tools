#!/usr/bin/env bash
# tpm-fde-diag.sh — read-only evidence gathering on an Ubuntu TPM/FDE machine
# that keeps asking for the recovery key, plus the firmware security report
# and the sshd penalty log. Prints; changes nothing.
#
# Usage on the target:   ./tpm-fde-diag.sh 2>&1 | tee fde-diag.txt
set -uo pipefail

section() { printf '\n== %s\n' "$*"; }

section "Machine"
sudo dmidecode -s system-product-name 2>/dev/null
sudo dmidecode -s system-version 2>/dev/null
printf 'BIOS: '; sudo dmidecode -s bios-version 2>/dev/null
printf 'snapd: '; snap version 2>/dev/null | awk '$1=="snapd"{print $2}'
snap list pc-kernel pc 2>/dev/null

section "Firmware security (fwupd HSI)"
fwupdmgr security --force 2>&1

section "Boot-time unlock messages, this boot"
journalctl -b -o short-precise 2>/dev/null \
  | grep -iE 'snap-bootstrap|recovery key|unseal|sealed|tpm|lockout|pcr' \
  | head -60

section "Boot-time unlock messages, previous boot"
journalctl -b -1 -o short-precise 2>/dev/null \
  | grep -iE 'snap-bootstrap|recovery key|unseal|sealed|tpm|lockout|pcr' \
  | head -40

section "snapd reseal activity"
journalctl -u snapd --since '-2 days' 2>/dev/null \
  | grep -iE 'reseal|seal|fde|tpm|recovery' | tail -40
snap changes 2>/dev/null | tail -15

section "TPM lockout state (only if tpm2-tools is installed)"
if command -v tpm2_getcap >/dev/null; then
  sudo tpm2_getcap properties-variable 2>&1 | grep -iE 'lockout|inLockout'
  sudo tpm2_getcap properties-fixed  2>&1 | grep -iE 'MANUFACTURER|VENDOR_STRING_1|FIRMWARE'
else
  echo "tpm2-tools not installed; skipped"
fi

section "sshd per-source penalties"
sudo sshd -T 2>/dev/null | grep -iE 'persourcepenalt|passwordauth|pubkeyauth'
journalctl -u ssh -b 2>/dev/null | grep -iE 'penal|drop connection' | tail -15
