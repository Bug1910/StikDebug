"""CI-only: retag thin arm64 Mach-O objects from iOS device to iOS simulator, in place.
- LC_BUILD_VERSION (0x32): platform 2 -> 7 (same size).
- LC_VERSION_MIN_IPHONEOS (0x25, 16 bytes): must become LC_BUILD_VERSION (24 bytes, platform 7).
  Make room by dropping harmless optional commands (LC_LINKER_OPTIMIZATION_HINT 0x2e, empty
  LC_DATA_IN_CODE 0x29); if still no room, shift the file body by 8 bytes and fix every file offset.
"""
import struct, sys
from collections import Counter

LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS = 0x19, 0x2, 0xB, 0x32, 0x25
DROPPABLE = (0x2E, 0x29)


def parse(b):
    ncmds, sizeofcmds = struct.unpack_from("<II", b, 16)
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        cmds.append((cmd, bytes(b[off:off + size])))
        off += size
    return cmds, sizeofcmds


def build_version(minos, sdk):
    return struct.pack("<IIIIII", LC_BUILD_VERSION, 24, 7, minos, sdk, 0)


def shift_offsets(cmd, data, delta):
    """Add delta to every file offset inside a load command (all offsets are >= end of load commands)."""
    d = bytearray(data)

    def add(o):
        v = struct.unpack_from("<I", d, o)[0]
        if v:
            struct.pack_into("<I", d, o, v + delta)

    if cmd == LC_SEGMENT_64:
        fo = struct.unpack_from("<Q", d, 40)[0]
        struct.pack_into("<Q", d, 40, fo + delta)
        nsects = struct.unpack_from("<I", d, 64)[0]
        for i in range(nsects):
            s = 72 + i * 80
            add(s + 48)  # section offset
            add(s + 56)  # reloff
    elif cmd == LC_SYMTAB:
        add(8)
        add(16)  # symoff, stroff
    elif cmd == LC_DYSYMTAB:
        for o in (32, 40, 48, 56, 64, 72):  # toc, modtab, extrefsym, indirectsym, extrel, locrel offsets
            add(o)
    elif cmd in (0x29, 0x2E, 0x26, 0x2B):  # linkedit_data_command: dataoff
        add(8)
    return bytes(d)


retagged = Counter()
for path in sys.argv[1:]:
    b = bytearray(open(path, "rb").read())
    if len(b) < 32 or struct.unpack_from("<I", b, 0)[0] != 0xFEEDFACF:
        retagged["skip-not-macho"] += 1
        continue
    cmds, sizeofcmds = parse(b)
    kinds = [c for c, _ in cmds]
    if LC_BUILD_VERSION in kinds:
        off = 32
        for c, d in cmds:
            if c == LC_BUILD_VERSION and struct.unpack_from("<I", d, 8)[0] == 2:
                struct.pack_into("<I", b, off + 8, 7)
            off += len(d)
        open(path, "wb").write(b)
        retagged["inplace"] += 1
        continue
    if LC_VERSION_MIN_IPHONEOS not in kinds:
        retagged["no-version-cmd"] += 1
        continue
    new = []
    for c, d in cmds:
        if c == LC_VERSION_MIN_IPHONEOS:
            _, _, ver, sdk = struct.unpack_from("<IIII", d, 0)
            new.append((LC_BUILD_VERSION, build_version(ver, sdk or ver)))
        else:
            new.append((c, d))
    cur = sum(len(d) for _, d in new)
    for drop in DROPPABLE:
        if cur <= sizeofcmds:
            break
        for i, (c, d) in enumerate(new):
            if c == drop and (drop != 0x29 or struct.unpack_from("<I", d, 12)[0] == 0):
                cur -= len(d)
                del new[i]
                break
    if cur <= sizeofcmds:
        block = b"".join(d for _, d in new)
        b[32:32 + sizeofcmds] = block + b"\0" * (sizeofcmds - len(block))
        struct.pack_into("<II", b, 16, len(new), len(block))
        retagged["rebuilt-in-space"] += 1
    else:
        delta = (cur - sizeofcmds + 7) // 8 * 8
        block = b"".join(shift_offsets(c, d, delta) for c, d in new)
        body = bytes(b[32 + sizeofcmds:])
        out = bytearray(b[:32]) + block + b"\0" * (sizeofcmds + delta - len(block)) + body
        struct.pack_into("<II", out, 16, len(new), len(block))
        retagged["shifted"] += 1
        b = out
    open(path, "wb").write(b)
print("retag summary:", dict(retagged))
