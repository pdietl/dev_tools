#!/usr/bin/env python3
"""Parse a TCG 2.0 EFI event log (/sys/kernel/security/tpm0/binary_bios_measurements).

usage: tcglog.py LOG [PCR ...]      print events (all PCRs, or the listed ones)
       tcglog.py LOG --json OUT      also dump [{pcr,type,sha256,data_hex}] to OUT

EV_EFI_VARIABLE_AUTHORITY events have their certificate subject decoded with openssl.
"""
import json, struct, subprocess, sys, uuid

EV = {0x1: "POST_CODE", 0x3: "NO_ACTION", 0x4: "SEPARATOR", 0x6: "EVENT_TAG", 0x8: "S_CRTM_VERSION",
      0xD: "IPL", 0x11: "EFI_HCRTM_EVENT", 0x80000001: "VAR_DRIVER_CONFIG", 0x80000002: "VAR_BOOT",
      0x80000003: "BS_APPLICATION", 0x80000004: "BS_DRIVER", 0x80000005: "RT_DRIVER",
      0x80000006: "GPT_EVENT", 0x80000007: "ACTION", 0x80000008: "PLATFORM_FIRMWARE_BLOB",
      0x8000000A: "HANDOFF_TABLES", 0x8000000B: "PLATFORM_FIRMWARE_BLOB2", 0x800000E0: "VAR_AUTHORITY"}
SHA256 = 0xB

def parse(buf):
    off = 0
    _pcr, _etype, size = struct.unpack_from("<II20xI", buf, off); off += 32
    spec = buf[off:off + size]; off += size
    nalg = struct.unpack_from("<I", spec, 24)[0]
    algs = {}
    for i in range(nalg):
        aid, dsz = struct.unpack_from("<HH", spec, 28 + 4 * i); algs[aid] = dsz
    events = []
    while off + 12 <= len(buf):
        pcr, etype, count = struct.unpack_from("<III", buf, off); off += 12
        digests = {}
        for _ in range(count):
            aid = struct.unpack_from("<H", buf, off)[0]; off += 2
            digests[aid] = buf[off:off + algs[aid]]; off += algs[aid]
        size = struct.unpack_from("<I", buf, off)[0]; off += 4
        data = buf[off:off + size]; off += size
        events.append({"pcr": pcr, "type": etype, "sha256": digests.get(SHA256, b""), "data": data})
    return events

def x509_subject(der):
    r = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-subject"],
                       input=der, capture_output=True)
    return r.stdout.decode(errors="replace").strip() if r.returncode == 0 else "(not a certificate)"

def describe(e):
    t, data = e["type"], e["data"]
    if t in (0x80000001, 0x800000E0):
        name_len, data_len = struct.unpack_from("<QQ", data, 16)
        name = data[32:32 + 2 * name_len].decode("utf-16-le")
        vdata = data[32 + 2 * name_len:32 + 2 * name_len + data_len]
        if t == 0x800000E0 and vdata[16:18] == b"\x30\x82":
            return f"var={name} owner={uuid.UUID(bytes_le=vdata[:16])} {x509_subject(vdata[16:])}"
        if t == 0x800000E0:
            return f"var={name} data={vdata.decode('utf-8', 'replace')!r}"
        return f"var={name} ({data_len} bytes)"
    if t == 0xD:
        s = data.decode("utf-16-le", "replace") if len(data) % 2 == 0 and b"\0" in data[1:2] else data.decode("utf-8", "replace")
        return repr(s)
    if t in (0x80000003, 0x80000004, 0x80000005):
        return "image, device path %d bytes" % max(0, len(data) - 32)
    if t == 0x80000007 or t == 0x8:
        return repr(data.decode("utf-8", "replace") if t == 0x80000007 else data.decode("utf-16-le", "replace"))
    return f"{len(data)} bytes"

def main():
    args = sys.argv[1:]
    out = None
    if "--json" in args:
        i = args.index("--json"); out = args[i + 1]; del args[i:i + 2]
    events = parse(open(args[0], "rb").read())
    want = {int(a) for a in args[1:]} or None
    for e in events:
        if want and e["pcr"] not in want:
            continue
        print(f"PCR{e['pcr']:<2} {EV.get(e['type'], hex(e['type'])):24} {e['sha256'].hex()}  {describe(e)[:120]}")
    if out:
        json.dump([{"pcr": e["pcr"], "type": e["type"], "sha256": e["sha256"].hex(), "data_hex": e["data"].hex()}
                   for e in events], open(out, "w"))

if __name__ == "__main__":
    main()
