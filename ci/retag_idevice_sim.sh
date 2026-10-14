#!/bin/bash
# CI-only: StikDebug/idevice/libidevice_ffi.a is a prebuilt iOS-DEVICE static library, so the
# iphonesimulator link fails ("building for 'iOS-simulator', but linking in object file ... built for 'iOS'").
# arm64 device and arm64 simulator code are the same instructions; only the Mach-O platform tag differs.
# This rewrites the tag on every object inside the archive (in the CI workspace copy only; never committed).
set -euo pipefail
REPO="$(pwd)"
LIB="${1:-StikDebug/idevice/libidevice_ffi.a}"
LIB="$(cd "$(dirname "$LIB")" && pwd)/$(basename "$LIB")"
W="$(mktemp -d)"
cp "$LIB" "$W/orig.a"
cd "$W"
mkdir objs && cd objs
ar -t ../orig.a | sort | uniq -d | sed 's/^/WARNING duplicate member name: /' || true
echo "members: $(ar -t ../orig.a | wc -l)"
ar -x ../orig.a
python3 "$REPO/ci/retag_objs.py" *.o
rm -f ../new.a
ar crs ../new.a *.o
cp ../new.a "$LIB"
xcrun vtool -show-build "$(ls *.o | head -1)" | head -8
