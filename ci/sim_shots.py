"""Screenshot every distinct iPhone/iPad logical size x 10 demo states.
usage: sim_shots.py <iphone|ipad> <shard> <of> <app> <outdir>"""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simlib import *

family, shard, of, app, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
os.makedirs(out, exist_ok=True)
STATES = "home newPlace manage simulating simulatingStale edit settings search undoToast error".split()
bid = bundle_id(app)
rt, sizes = distinct_sizes("iPad" if family == "ipad" else "iPhone")
if os.environ.get("SHOTS_QUICK") == "1":  # everyday push: smallest + largest iPhone, largest iPad
    sizes = [sizes[-1]] if family == "ipad" else [sizes[0], sizes[-1]]
print("sizes:", [(s, n) for s, n, _ in sizes], flush=True)
print("SKIPPED (no simulator type on this runtime):", [z for z in OFFICIAL["iPad" if family == "ipad" else "iPhone"] if z not in [s for s, _, _ in sizes]], flush=True)
sh("xcrun", "simctl", "list", "devices", "available")


def rotate_landscape():
    """simctl has no rotate command; try the Simulator menu shortcut (needs GUI + accessibility)."""
    sh("open", "-a", "Simulator", check=False, quiet=True)
    time.sleep(3)
    sh("osascript", "-e", 'tell application "System Events" to key code 124 using {command down}', check=False)
    time.sleep(3)


bad = []
for i, (size, name, tid) in enumerate(sizes):
    if i % of != shard:
        continue
    tag = size + "_" + re.sub(r"[^A-Za-z0-9]+", "", name)
    udid = None
    try:
        udid = find_or_create(tid, name, rt)
        print("==", tag, udid, flush=True)
        prepare(udid, app, bid)
        landscape_ok = True
        for orient in ["portrait"]:  # simctl cannot rotate; landscape verified impossible on CI runners
            if orient == "landscape":
                rotate_landscape()
            suffix = "_" + orient if family == "ipad" else ""
            for state in STATES:
                for mode in (["light", "dark"] if state in ("home", "simulating") else ["light"]):
                    sh("xcrun", "simctl", "ui", udid, "appearance", mode, check=False, quiet=True)
                    sh("xcrun", "simctl", "terminate", udid, bid, check=False, quiet=True)
                    seed(udid, bid)
                    launch(udid, bid, ["-GpsSimDemo", state])
                    time.sleep(6)
                    p = "%s/%s_%s_%s%s.png" % (out, tag, state, mode, suffix)
                    sh("xcrun", "simctl", "io", udid, "screenshot", p, check=False, quiet=True)
                    if not os.path.exists(p) or os.path.getsize(p) < 10240:
                        bad.append(p)
                        print("FAIL: screenshot missing or under 10 KB:", p, flush=True)
                    if orient == "landscape" and os.path.exists(p) and png_size(p)[0] < png_size(p)[1]:
                        os.remove(p)
                        landscape_ok = False
                        print("landscape rotation not possible on this runner; portrait only", flush=True)
                        break
                if orient == "landscape" and not landscape_ok:
                    break
        # Display Zoom can't be switched via simctl: emulate the 320 pt layouts with a demo launch arg
        # (needs the app to honour -GpsSimDemoWidth; harmless if it ignores it)
        # plus the largest accessibility text size, so truncation and button growth show up
        if family == "iphone" and size in ("375x667", "390x844"):
            sh("xcrun", "simctl", "ui", udid, "content_size", "accessibility-extra-extra-extra-large", check=False)
            for state in ("home", "edit", "simulating"):
                sh("xcrun", "simctl", "terminate", udid, bid, check=False, quiet=True)
                seed(udid, bid)
                launch(udid, bid, ["-GpsSimDemo", state, "-GpsSimDemoWidth", "320"])
                time.sleep(6)
                sh("xcrun", "simctl", "io", udid, "screenshot", "%s/%s_%s_light_zoom320_axxxl.png" % (out, tag, state), check=False, quiet=True)
            sh("xcrun", "simctl", "ui", udid, "content_size", "large", check=False)
    except Exception as e:  # one broken device must not kill the rest
        print("ERROR", tag, e, flush=True)
    finally:
        if udid:
            sh("xcrun", "simctl", "shutdown", udid, check=False, quiet=True)
print(sorted(os.listdir(out)))
if bad:
    sys.exit("bad screenshots: %s" % bad)
