#!/bin/bash
# 10 separate launches per case; fail on any repeated first landing or a point outside the circle(s).
set -e
swiftc -O -o /tmp/landing StikDebug/GpsSim/GpsSimPlaces.swift ci/landing/stubs.swift ci/landing/main.swift
status=0
for mode in single --overlap; do
  out=$(for i in $(seq 1 10); do /tmp/landing $mode; done)
  echo "== $mode"; echo "$out" | nl
  dups=$(echo "$out" | awk '{print $1, $2}' | sort | uniq -d | wc -l | tr -d ' ')
  limit=25; [ "$mode" = "--overlap" ] && limit=60  # union of two 25 m circles 33 m apart
  far=$(echo "$out" | awk -v l=$limit '$3 > l' | wc -l | tr -d ' ')
  echo "repeated first coordinates: $dups, outside circle: $far"
  [ "$dups" = 0 ] && [ "$far" = 0 ] || status=1
done
exit $status
