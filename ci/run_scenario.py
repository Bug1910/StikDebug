"""Play ci/scenarios/<tester>.json on one simulator using AXe (tap/type/swipe) and simctl (screenshots).
usage: run_scenario.py <tester> <device1;device2;...> <app> <outdir>
A failing step is recorded in results.json and the run continues."""
import json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simlib import *

tester, cands, app, out = sys.argv[1], sys.argv[2].split(";"), sys.argv[3], sys.argv[4]
os.makedirs(out, exist_ok=True)
steps = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios", tester + ".json"), encoding="utf-8"))
bid = bundle_id(app)
name, udid = by_name(cands)
print("tester", tester, "->", name, udid, flush=True)
prepare(udid, app, bid)
sh("xcrun", "simctl", "ui", udid, "appearance", "light", check=False, quiet=True)
launch(udid, bid)
time.sleep(10)
results = []
META = ("note", "persona", "situation")  # who the tester is and when they use the app; not steps
persona = {k: steps[0][k] for k in ("persona", "situation") if steps and k in steps[0]}


def ui_ready(limit=20):
    """Poll describe-ui until it returns a non-empty tree (sim accessibility is slow after boot/launch)."""
    end = time.time() + limit
    while time.time() < end:
        r = sh("axe", "describe-ui", "--udid", udid, check=False, quiet=True)
        if r.returncode == 0 and len(r.stdout.strip()) > 200:
            return True
        time.sleep(1)
    print("WARNING: accessibility tree still empty after", limit, "s", flush=True)
    return False


def tap_retry(*args):
    r = sh("axe", "tap", *args, "--wait-timeout", "3", "--udid", udid, check=False)
    if r.returncode:
        time.sleep(1.5)
        r = sh("axe", "tap", *args, "--wait-timeout", "3", "--udid", udid, check=False)
    return r


PASTE_BUTTONS = ("Allow Paste", "允許貼上")


def dismiss_paste_alert(limit=6):
    """After Cmd+V: wait for the system paste-permission alert and tap its allow button."""
    end = time.time() + limit
    quiet_polls = 0
    while time.time() < end:
        time.sleep(1)
        tree = sh("axe", "describe-ui", "--udid", udid, check=False, quiet=True).stdout
        for allow in PASTE_BUTTONS:
            if allow in tree:
                if sh("axe", "tap", "--label", allow, "--wait-timeout", "2", "--udid", udid,
                      check=False, quiet=True).returncode == 0:
                    time.sleep(1)
                    return True
        quiet_polls += 1
        if quiet_polls >= 3:  # no alert after 3 looks: already allowed, nothing to do
            return False
    return False


def tree_dump():
    """describe-ui with up to 3 tries (1 s apart): the dump is sometimes empty right after a tap."""
    r = None
    for _ in range(3):
        r = sh("axe", "describe-ui", "--udid", udid, check=False, quiet=True)
        if r.returncode == 0 and len(r.stdout.strip()) > 200:
            break
        time.sleep(1)
    return r


ui_ready()


def snap(path):
    return sh("xcrun", "simctl", "io", udid, "screenshot", path, check=False, quiet=True).returncode == 0


for n, step in enumerate(steps, 1):
    kind = next((k for k in step if k not in META), None)
    if kind is None:
        continue
    val = step[kind]
    ok, detail = True, ""
    try:
        if kind == "tap":
            r = tap_retry("--label", val)
            ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
        elif kind == "tapId":
            r = tap_retry("--id", val)
            ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
        elif kind == "tapXY":
            r = sh("axe", "tap", "-x", val[0], "-y", val[1], "--udid", udid, check=False)
            if r.returncode:
                time.sleep(1.5)
                r = sh("axe", "tap", "-x", val[0], "-y", val[1], "--udid", udid, check=False)
            ok, detail = r.returncode == 0, r.stderr.strip()[:200]
        elif kind == "longPress":  # touch down, hold 1 s, up (AXe `touch --down --up --delay`)
            r = sh("axe", "touch", "-x", val[0], "-y", val[1], "--down", "--up", "--delay", "1.0",
                   "--udid", udid, check=False)
            ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
        elif kind == "type":
            enter = val.endswith(chr(10))
            val = val.rstrip(chr(10))
            # Always paste (pasteboard + Cmd+V, modifier 227 key 25): with the zh-Hant locale the
            # simulator keyboard is Zhuyin, and HID-typed ASCII turned into bopomofo (seen 2026-10-15).
            import subprocess
            subprocess.run(["xcrun", "simctl", "pbcopy", udid], input=val.encode("utf-8"))
            r = sh("axe", "key-combo", "--modifiers", "227", "--key", "25", "--udid", udid, check=False)
            # iOS asks "would like to paste from CoreSimulatorBridge" for a cross-app paste and the
            # alert blocks every later step until answered. It can appear >1 s after Cmd+V, so poll the
            # UI tree for the alert button (up to ~6 s) and tap it; stop early when no alert shows.
            dismiss_paste_alert()
            if enter and r.returncode == 0:  # Return key (HID usage 40) submits the search
                r = sh("axe", "key", "40", "--udid", udid, check=False)
            ok, detail = r.returncode == 0, r.stderr.strip()[:200]
        elif kind == "swipe":
            r = sh("axe", "swipe", "--start-x", val[0], "--start-y", val[1], "--end-x", val[2], "--end-y", val[3],
                   "--udid", udid, check=False)
            ok, detail = r.returncode == 0, r.stderr.strip()[:200]
        elif kind == "selectAll":  # Cmd+A in the focused field (so the next `type` replaces the text)
            r = sh("axe", "key-combo", "--modifiers", "227", "--key", "4", "--udid", udid, check=False)
            ok, detail = r.returncode == 0, r.stderr.strip()[:200]
        elif kind == "wait":
            time.sleep(float(val))
        elif kind == "shot":
            pass
        elif kind == "tree":
            r = tree_dump()
            open("%s/%02d_tree_%s.json" % (out, n, re.sub(r"\W+", "_", str(val))), "w", encoding="utf-8").write(r.stdout)
            ok = r.returncode == 0 and len(r.stdout.strip()) > 200
        elif kind == "relaunch":
            launch(udid, bid, val)
            time.sleep(4)
            ui_ready()
        else:
            ok, detail = False, "unknown step type"
    except Exception as e:
        ok, detail = False, str(e)[:200]
    time.sleep(1)
    label = re.sub(r"\W+", "_", str(val))[:20] if kind in ("shot", "tree") else ""
    shot = "%02d_%s%s.png" % (n, kind, ("_" + label) if label else "")
    snap("%s/%s" % (out, shot))
    if os.path.exists("%s/%s" % (out, shot)) and os.path.getsize("%s/%s" % (out, shot)) < 10240:
        ok, detail = False, (detail + " screenshot under 10 KB (blank/failed)").strip()
    results.append({"n": n, "step": step, "ok": ok, "detail": detail, "screenshot": shot})
    print(n, kind, "OK" if ok else "FAIL " + detail, flush=True)

json.dump({"tester": tester, **persona, "device": name, "results": results, "failed": sum(not r["ok"] for r in results)},
          open(out + "/results.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
sh("xcrun", "simctl", "shutdown", udid, check=False, quiet=True)
sys.exit(1 if any(not r["ok"] for r in results) else 0)  # a scenario with any failed step turns the CI job red
