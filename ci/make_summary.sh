#!/bin/bash
# Small review bundle: usage make_summary.sh <src_dir> <dst_dir>
# Copies logs/json/txt as-is, downscales every PNG to 360 px wide JPEG q60, writes summary.txt.
src="$1"; dst="$2"
mkdir -p "$dst"; src="$(cd "$src" 2>/dev/null && pwd)"; dst="$(cd "$dst" && pwd)"
[ -d "$src" ] || { echo "no $src" > "$dst/summary.txt"; exit 0; }
(cd "$src" && find . -type f \( -name '*.json' -o -name '*.jsonl' -o -name '*.txt' -o -name '*.log' \) -print0 |
  while IFS= read -r -d '' f; do mkdir -p "$dst/$(dirname "$f")"; cp "$f" "$dst/$f"; done)
(cd "$src" && find . -type f -name '*.png' -print0 |
  while IFS= read -r -d '' f; do
    o="$dst/${f%.png}.jpg"; mkdir -p "$(dirname "$o")"
    sips -s format jpeg -s formatOptions 60 --resampleWidth "${SUMMARY_WIDTH:-360}" "$f" --out "$o" >/dev/null 2>&1 || true
  done)
{
  echo "pngs: $(find "$src" -name '*.png' | wc -l | tr -d ' ')  jpgs: $(find "$dst" -name '*.jpg' | wc -l | tr -d ' ')"
  if [ -f "$src/results.json" ]; then
    python3 - "$src/results.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
r = d.get("results", [])
bad = [x for x in r if not x.get("ok")]
print("steps: %d passed, %d failed" % (len(r) - len(bad), len(bad)))
for x in bad:
    print("FAIL #%s %s: %s" % (x.get("n"), x.get("step"), x.get("detail")))
PY
  fi
} > "$dst/summary.txt"
du -sh "$dst" >> "$dst/summary.txt"
