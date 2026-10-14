"""In-place Mach-O platform retag (iOS=2 -> iOS-simulator=7) for thin arm64 .o files.
Same-size edit of LC_BUILD_VERSION, so no free space in the load commands is needed (vtool needs it)."""
import struct, sys
n = changed = 0
for path in sys.argv[1:]:
    b = bytearray(open(path, "rb").read())
    n += 1
    if struct.unpack_from("<I", b, 0)[0] != 0xFEEDFACF:
        print("skip (not thin 64-bit Mach-O):", path)
        continue
    ncmds = struct.unpack_from("<I", b, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        if cmd == 0x32:  # LC_BUILD_VERSION: cmd,size,platform,minos,sdk,ntools
            if struct.unpack_from("<I", b, off + 8)[0] == 2:
                struct.pack_into("<I", b, off + 8, 7)
                changed += 1
        elif cmd == 0x24:  # LC_VERSION_MIN_IPHONEOS has no simulator form; flag it
            print("WARNING LC_VERSION_MIN_IPHONEOS in", path)
        off += size
    open(path, "wb").write(b)
print("objects:", n, "retagged:", changed)
