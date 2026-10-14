"""In-place Mach-O platform retag (iOS=2 -> iOS-simulator=7) for thin arm64 .o files.
Same-size edit of LC_BUILD_VERSION, so no free space in the load commands is needed (vtool needs it)."""
import struct, sys
n = changed = 0
from collections import Counter
left = Counter()
for path in sys.argv[1:]:
    b = bytearray(open(path, "rb").read())
    n += 1
    if struct.unpack_from("<I", b, 0)[0] != 0xFEEDFACF:
        print("skip (not thin 64-bit Mach-O):", path)
        continue
    ncmds = struct.unpack_from("<I", b, 16)[0]
    off = 32
    cmds = []
    done = False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        cmds.append(hex(cmd))
        if cmd == 0x32:  # LC_BUILD_VERSION: cmd,size,platform,minos,sdk,ntools
            if struct.unpack_from("<I", b, off + 8)[0] == 2:
                struct.pack_into("<I", b, off + 8, 7)
                changed += 1
                done = True
            elif struct.unpack_from("<I", b, off + 8)[0] == 7:
                done = True
        off += size
    if not done:
        left[(tuple(sorted(set(cmds))), struct.unpack_from("<I", b, 4)[0])] += 1
        if sum(left.values()) <= 3:
            print("NOT RETAGGED", path, cmds)
    open(path, "wb").write(b)
print("objects:", n, "retagged:", changed)
print("not retagged groups (load cmds, cputype):", dict(left))
