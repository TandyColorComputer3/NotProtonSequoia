#!/usr/bin/env python3
# Development tool. The real patcher lives in the app (NtdllPatcher.swift).
# This is the original Python version, kept for validating patches against
# new CrossOver builds.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from resolve import PE, SECTION_FLAGS, SECTION_NAME, SECTION_SIZE, resolve, shell_vars  # noqa: E402

DEFAULT_PAYLOAD = {0x8664: "detour2.bin", 0x14c: "detour32.bin", 0xaa64: "detour64-fex.bin"}


def append_section(pe, d, r):
    import struct
    raw = r['rawOffset']
    e = struct.unpack_from('<I', d, 0x3c)[0]
    d[pe.table_end:pe.table_end + 40] = struct.pack(
        '<8sIIIIIIHHI', SECTION_NAME, SECTION_SIZE, r['caveRVA'], SECTION_SIZE, raw,
        0, 0, 0, 0, SECTION_FLAGS)
    struct.pack_into('<H', d, e + 6, struct.unpack_from('<H', d, e + 6)[0] + 1)
    struct.pack_into('<I', d, pe.opt + 56, r['caveRVA'] + SECTION_SIZE)
    d.extend(b"\0" * (raw + SECTION_SIZE - len(d)))
    return raw


def main():
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} <src ntdll.dll> [dst] [payload.bin]")
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else "ntdll.dll.patched"
    here = os.path.dirname(os.path.abspath(__file__))

    r = resolve(src)
    v = shell_vars(src)
    if r['machine'] not in DEFAULT_PAYLOAD:
        raise SystemExit(f"{src}: machine {r['machine']:#x} carries no detour")
    payload_path = sys.argv[3] if len(sys.argv) > 3 \
        else os.path.join(here, DEFAULT_PAYLOAD[r['machine']])
    detour = open(payload_path, "rb").read()
    payload_rva = int(v['NP_PAYLOAD_RVA'], 16)
    fill = r['fill']
    sites = r.get('sites') or [r]

    pe = PE(src)
    d = bytearray(pe.d)
    if r['placement'] == 'section':
        cave_off = append_section(pe, d, r)
    else:
        cave_off = pe.off(payload_rva)

    if any(b != fill for b in d[cave_off:cave_off + len(detour)]):
        raise SystemExit(f"cave at {cave_off:#x} is not {fill:#02x} pad for {len(detour)} bytes")
    d[cave_off:cave_off + len(detour)] = detour

    hooks = []
    for site in sites:
        bm_off = pe.off(site['hookRVA'])
        stolen = bytes.fromhex(site['stolen'])
        if d[bm_off:bm_off + len(stolen)] != stolen:
            raise SystemExit(f"unexpected hook site at {site['hookRVA']:#x}: "
                             f"{d[bm_off:bm_off + len(stolen)].hex()}")
        if r['machine'] == 0xaa64:
            rel = payload_rva - site['hookRVA']
            if rel % 4 or not -(1 << 27) <= rel < (1 << 27):
                raise SystemExit(f"cave is {rel:#x} from the hook, out of bl range")
            patch = (0x94000000 | ((rel >> 2) & 0x03ffffff)).to_bytes(4, 'little')
        else:
            # E9 rel32 to the shim at the payload start
            rel = payload_rva - (site['hookRVA'] + 5)
            patch = b"\xE9" + rel.to_bytes(4, 'little', signed=True) + b"\xCC" * (len(stolen) - 5)
        assert len(patch) == len(stolen)
        d[bm_off:bm_off + len(patch)] = patch
        hooks.append((site, bm_off, rel, stolen))

    # patch in memory and write once, like a pro
    tmp = dst + ".tmp"
    with open(tmp, "wb") as f:
        f.write(d)
    os.replace(tmp, dst)

    print(f"patched {src} -> {dst}")
    print(f"  payload {os.path.basename(payload_path)}, {len(detour)} bytes at rva "
          f"{payload_rva:#x} (off {cave_off:#x}), cave pad {fill:#02x}")
    for site, bm_off, rel, stolen in hooks:
        print(f"  hook {site['hookRVA']:#x} (off {bm_off:#x}) branch rel {rel:#x} to cave "
              f"entry, stolen {stolen.hex()}")


if __name__ == "__main__":
    main()
