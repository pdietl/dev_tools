#!/usr/bin/env python3
"""Explain why an Ubuntu TPM/FDE sealed key does not unseal.

Recomputes the PolicyOR branch digests that snapd/secboot sealed into a LUKS2
token and tests them against the PCR values the firmware actually produced,
trying the mispredictions secboot is known to make. Run the data collection on
the target machine, then this script anywhere:

  ssh HOST 'sudo cat /sys/kernel/security/tpm0/binary_bios_measurements' > log.bin
  ssh HOST 'systemd-analyze pcrs' | awk '$1 ~ /^[0-9]+$/ {print $1, $NF}' > pcrs.txt
  ssh HOST 'sudo cryptsetup token export --token-id 2 /dev/nvme0n1p5' > token2.json
  ssh HOST 'sudo cat /var/lib/snapd/device/fde/boot-chains' > boot-chains.json
  tpm-policy-match.py log.bin pcrs.txt boot-chains.json token2.json [token3.json ...]

Needs tcglog.py next to it.
"""
import base64, hashlib, importlib.util, itertools, json, os, struct, sys, uuid

sys.dont_write_bytecode = True  # tcglog.py is loaded from beside this file; keep ~/bin free of caches

H = lambda *a: hashlib.sha256(b"".join(a)).digest()

def load_tcglog():
    spec = importlib.util.spec_from_file_location("tcglog", os.path.join(os.path.dirname(os.path.abspath(__file__)), "tcglog.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def leaves(tokfile):
    tok = json.load(open(tokfile)); blob = base64.b64decode(tok["ubuntu_fde_data"]["platform_handle"])
    off = blob.find(b"\x00\x00\x00\x01\x00\x0b\x03")
    if off < 0: sys.exit(f"{tokfile}: no SHA-256 PCR selection found")
    sel = blob[off + 7:off + 10]; p = off + 10
    n = struct.unpack_from(">I", blob, p)[0]; p += 4; out = []
    for _ in range(n):
        _parent, cnt = struct.unpack_from(">II", blob, p); p += 8
        for _ in range(cnt):
            sz = struct.unpack_from(">H", blob, p)[0]; p += 2; out.append(blob[p:p + sz]); p += sz
    return sel, out

def replay(ds, start=b"\0" * 32):
    v = start
    for d in ds: v = H(v, d)
    return v

def model_digest(chain, grade_code=0x80000):
    key = base64.urlsafe_b64decode(chain["model-sign-key-id"] + "==")
    d1 = H(struct.pack("<H", 0x000C), key, chain["brand-id"].encode()); d2 = H(d1, chain["model"].encode())
    return H(d2, b"16", struct.pack("<I", grade_code | (0x80000000 if chain.get("classic") else 0)))

def main():
    if len(sys.argv) < 5: sys.exit(__doc__)
    logf, pcrf, chainsf, toks = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    tcg = load_tcglog(); ev = tcg.parse(open(logf, "rb").read())
    actual = {int(l.split()[0]): bytes.fromhex(l.split()[1]) for l in open(pcrf) if l.strip()}
    chains = json.load(open(chainsf))["boot-chains"]
    all_leaves = {}
    sel = None
    for t in toks:
        s, L = leaves(t)
        sel = sel or s
        for x in L: all_leaves[x.hex()] = os.path.basename(t)
    pcrs = [i for i in range(24) if sel[i // 8] >> (i % 8) & 1]
    SEL = b"\x00\x00\x00\x01\x00\x0b\x03" + sel
    print("policy PCRs:", pcrs, "| branches:", len(all_leaves))
    branch = lambda vals: H(b"\0" * 32, b"\x00\x00\x01\x7f", SEL, H(*[vals[p] for p in pcrs]))
    E = lambda pcr: [e for e in ev if e["pcr"] == pcr]
    # per-PCR candidate sets: 'actual' plus secboot-style predictions
    V = {p: {"actual": actual[p]} for p in pcrs}
    if 0 in V:
        V[0]["log-replay(zero start)"] = replay([e["sha256"] for e in E(0) if e["type"] != 3])
    if 2 in V:
        p2 = E(2); sep = next(i for i, e in enumerate(p2) if e["type"] == 4)
        V[2]["log-replay-to-separator"] = replay([e["sha256"] for e in p2[:sep + 1]])
    if 4 in V:
        p4 = [e["sha256"] for e in E(4)]
        V[4]["run-chain(all events)"] = replay(p4)
        if len(p4) >= 6: V[4]["recover-chain(no boot grub)"] = replay(p4[:4] + p4[5:])
    if 7 in V:
        V[7]["log-replay"] = replay([e["sha256"] for e in E(7)])
    if 12 in V:
        epoch = H(struct.pack("<I", 0))
        for c in chains:
            for cmd in c["kernel-cmdlines"]:
                cd = H(cmd.encode("utf-16-le") + b"\0\0")
                tag = cmd.split()[0].split("=")[1]
                V[12][f"{tag}:cmdline"] = replay([cd])
                V[12][f"{tag}:cmdline+epoch+model"] = replay([cd, epoch, model_digest(c)])
    hits = 0; next_boot_ok = False
    for combo in itertools.product(*[list(V[p].items()) for p in pcrs]):
        vals = {p: v for p, (_, v) in zip(pcrs, combo)}
        if branch(vals).hex() in all_leaves:
            hits += 1
            names = {p: n for p, (n, _) in zip(pcrs, combo)}
            print("MATCH:", ", ".join(f"PCR{p}={names[p]}" for p in pcrs))
            # At unlock time PCR12 is cmdline+epoch+model; the live value read later carries the
            # post-unlock fence, so judge the next boot on live PCRs 0/2/4/7 + predicted run PCR12.
            if all(names[p] == "actual" for p in pcrs if p != 12) and names.get(12, "").startswith("run:") \
               and names.get(12, "").endswith("cmdline+epoch+model"):
                next_boot_ok = True
    print("next boot should unseal with the TPM (live PCRs + predicted run-mode PCR12 form a sealed branch):",
          "YES" if next_boot_ok else "NO")
    if not hits: print("no candidate combination matched; the misprediction is outside the modelled set")

if __name__ == "__main__":
    main()
