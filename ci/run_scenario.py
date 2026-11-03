"""Play ci/scenarios/<tester>.json on one simulator using AXe (tap/type/swipe) and simctl (screenshots).
usage: run_scenario.py <tester> <device1;device2;...> <app> <outdir>
A failing step is retried once after 3 s; a second failure (not "optional") stops the run: STOPPED_AT=<n>, SCEN_RC=1."""
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
META = ("note", "persona", "situation", "optional", "index")  # who the tester is and when they use the app; not steps
# "index": N on a "tap"/"tapId" step = when several elements share that label or id (e.g. a place name in the picker
# list and on the map sheet behind it), tap the N-th one counted top to bottom (default 0).
# "optional": true on a step = its failure is recorded (detail starts with "optional:") but does not
# fail the run; for branches the app picks by the clock (e.g. itinerary 開始 vs 從目前的項目接續).
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


def nth_frame(prefix, idx):
    """Frame of the idx-th on-screen element (tree order; -1 = last) whose id starts with prefix.
    For rows that share one accessibility id (itin.edit.row, itin.row)."""
    hits = []

    def walk(node):
        if isinstance(node, list):
            for x in node:
                walk(x)
        elif isinstance(node, dict):
            f = node.get("frame") or {}
            if (node.get("AXUniqueId") or "").startswith(prefix) and f.get("height", 0) > 0:
                hits.append(f)
            walk(node.get("children") or [])
    try:
        walk(json.loads(tree_dump().stdout))
    except ValueError:
        pass
    try:
        return hits[idx]
    except IndexError:
        return None


def snap(path):
    return sh("xcrun", "simctl", "io", udid, "screenshot", path, check=False, quiet=True).returncode == 0


def tap_nth(field, val, idx, r):
    """AXe refuses to tap when several elements match (--label or --id). Collect every on-screen element whose
    field (AXLabel / AXUniqueId) equals val, merge ones sharing a frame, sort top to bottom and tap the centre
    of the idx-th one. Seen 2026-11-03: a place name in the picker list and on the map sheet behind it; a
    toolbar button (itin.item.commit / itin.edit.save) reported twice, once as the bar item and once inside."""
    if not r.returncode or "Multiple" not in (r.stderr or r.stdout):
        return r
    frames = []

    def walk(node):
        if isinstance(node, list):
            for x in node:
                walk(x)
        elif isinstance(node, dict):
            f = node.get("frame") or {}
            if node.get(field) == val and f.get("height", 0) > 0:
                key = tuple(round(f[k]) for k in ("x", "y", "width", "height"))
                if key not in frames:
                    frames.append(key)
            walk(node.get("children") or [])
    try:
        walk(json.loads(tree_dump().stdout))
    except ValueError:
        pass
    frames.sort(key=lambda k: (k[1], k[0]))
    if idx >= len(frames):
        r.stderr = "%s: only %d matches, index %d " % (val, len(frames), idx) + (r.stderr or "")
        return r
    x, y, w, h = frames[idx]
    r2 = tap_retry("-x", str(int(x + w / 2)), "-y", str(int(y + h / 2)))
    r2.stderr = ("%s #%d of %d at %d,%d " % (val, idx, len(frames), x + w / 2, y + h / 2)) + (r2.stderr or "")
    return r2




def pasteboard_ok():
    """`type` steps paste through the simulator pasteboard. With no macOS GUI login (VM rebooted to the login
    window) simctl pbcopy returns 0 but stores nothing and every paste is silently empty (seen 2026-11-03)."""
    import subprocess
    probe = "pinfly-pb-%d" % int(time.time())
    subprocess.run(["xcrun", "simctl", "pbcopy", udid], input=probe.encode())
    return sh("xcrun", "simctl", "pbpaste", udid, check=False, quiet=True).stdout.strip() == probe


if any("type" in s for s in steps) and not pasteboard_ok():
    print("PASTEBOARD_DEAD: simctl pbcopy stored nothing; log in to the macOS GUI (login window) first", flush=True)
    print("STOPPED_AT=0", flush=True)
    print("SCEN_RC=1", flush=True)
    sys.exit(1)
stopped = None


def run_step(n, step, kind, val):
    """Do one scenario step; returns (ok, detail)."""
    ok, detail = True, ""
    try:
        if kind == "tap":
            r = tap_nth("AXLabel", val, int(step.get("index", 0)), tap_retry("--label", val))
            ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
        elif kind == "tapId":
            r = tap_nth("AXUniqueId", val, int(step.get("index", 0)), tap_retry("--id", val))
            if r.returncode and val.startswith("settings."):
                # Settings rows off screen are not in the accessibility tree until scrolled into view
                # (the help section moved under 位置微飄, 2026-11-02): up to 3 scrolls down, looking after
                # each one; still missing = the row is above, so up to 3 scrolls up the same way.
                for start_y, end_y in [(650, 300)] * 3 + [(300, 650)] * 3:
                    sh("axe", "swipe", "--start-x", "196", "--start-y", str(start_y), "--end-x", "196",
                       "--end-y", str(end_y), "--udid", udid, check=False)
                    time.sleep(1)
                    if val in (tree_dump().stdout or ""):
                        r = tap_retry("--id", val)
                        if r.returncode == 0:
                            break
            ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
        elif kind == "tapLastId":  # tap the last on-screen element whose id starts with val (rows whose label is a geocoded name)
            hits = []

            def walk(node):
                if isinstance(node, list):
                    for x in node:
                        walk(x)
                elif isinstance(node, dict):
                    uid = node.get("AXUniqueId") or ""
                    f = node.get("frame") or {}
                    if uid.startswith(val) and f.get("height", 0) > 0:
                        hits.append(f)
                    walk(node.get("children") or [])
            try:
                walk(json.loads(tree_dump().stdout))
            except ValueError:
                pass
            if hits:
                f = hits[-1]
                r = tap_retry("-x", str(int(f["x"] + f["width"] / 2)), "-y", str(int(f["y"] + f["height"] / 2)))
                ok, detail = r.returncode == 0, (r.stderr or r.stdout).strip()[:200]
            else:
                ok, detail = False, "no element with id prefix " + val
        elif kind == "tapXY":
            r = sh("axe", "tap", "-x", val[0], "-y", val[1], "--udid", udid, check=False)
            if r.returncode:
                time.sleep(1.5)
                r = sh("axe", "tap", "-x", val[0], "-y", val[1], "--udid", udid, check=False)
            ok, detail = r.returncode == 0, r.stderr.strip()[:200]
        elif kind == "drag":  # ["<accessibility id>", dx, dy]: press-and-hold that element, then move by (dx, dy) pt
            def find_frame(node, uid):
                if isinstance(node, list):
                    for x in node:
                        hit = find_frame(x, uid)
                        if hit:
                            return hit
                elif isinstance(node, dict):
                    f = node.get("frame") or {}
                    if node.get("AXUniqueId") == uid and f.get("height", 0) > 0:
                        return f
                    return find_frame(node.get("children") or [], uid)
                return None
            try:
                frame = find_frame(json.loads(tree_dump().stdout), val[0])
            except ValueError:
                frame = None
            if frame is None:
                ok, detail = False, "no element with id " + val[0]
            else:
                sx, sy = int(frame["x"] + frame["width"] / 2), int(frame["y"] + frame["height"] / 2)
                ex, ey = sx + int(val[1]), sy + int(val[2])
                # The app needs a 0.45 s hold before the finger moves (else the map pans). `axe drag` has no
                # hold flag (--pre-delay waits BEFORE touch-down), but its event list is fixed (AXe
                # HIDInteractor.makeCompositeDragEvent): down, 0.05 s, then per step delay(duration/steps) + move,
                # then up. duration 3 / steps 3 = first move at 1.05 s after touch-down, i.e. held still past 0.45 s.
                # No swipe fallback: swipe's timing is not documented, a silent non-hold would look like a pass.
                r = sh("axe", "drag", "--start-x", str(sx), "--start-y", str(sy), "--end-x", str(ex), "--end-y", str(ey),
                       "--duration", "3", "--steps", "3", "--udid", udid, check=False)
                ok, detail = r.returncode == 0, ("%d,%d -> %d,%d " % (sx, sy, ex, ey) + (r.stderr or r.stdout).strip())[:200]
        elif kind == "expect":  # text (or "!text" = must be absent) somewhere in the accessibility tree
            want = not val.startswith("!")
            text = val if want else val[1:]
            # A positive expect keeps looking for up to 30 s: on the slow Intel VM a new screen can take
            # 10-20 s to draw, and one early look failed steps whose screen simply was not drawn yet.
            deadline = time.time() + (30 if want else 0)
            while True:
                raw = tree_dump().stdout or ""
                try:  # compare decoded text, in case the dump escapes non-ASCII as \uXXXX
                    raw = json.dumps(json.loads(raw), ensure_ascii=False)
                except ValueError:
                    pass
                found = text in raw
                if found == want or time.time() >= deadline:
                    break
                time.sleep(2)
            ok, detail = found == want, ("" if found == want else ("missing: " if want else "still shown: ") + text)
        elif kind == "expectRow":  # ["<id prefix>", "text"]: some element with that id prefix has text in its label
            def rows(node, out):
                if isinstance(node, list):
                    for x in node:
                        rows(x, out)
                elif isinstance(node, dict):
                    if (node.get("AXUniqueId") or "").startswith(val[0]):
                        out.append(node.get("AXLabel") or "")
                    rows(node.get("children") or [], out)
                return out
            try:
                labels = rows(json.loads(tree_dump().stdout), [])
            except ValueError:
                labels = []
            ok = any(val[1] in lab for lab in labels)
            detail = "" if ok else ("no %s* row with %s; rows: %s" % (val[0], val[1], " | ".join(labels)))[:200]
        elif kind == "longPress":  # touch down, hold 1 s, up (AXe `touch --down --up --delay`)
            # Optional 4th item = an accessibility id that must show up afterwards; if it does not (the
            # first touch after a relaunch is sometimes swallowed while the map is still settling), press
            # again, up to 3 presses in all.
            for attempt in range(3 if len(val) > 3 else 1):
                r = sh("axe", "touch", "-x", val[0], "-y", val[1], "--down", "--up", "--delay", str(val[2] if len(val) > 2 else 1.0),
                       "--udid", udid, check=False)
                if len(val) <= 3 or r.returncode:
                    break
                time.sleep(2)
                if val[3] in (tree_dump().stdout or ""):
                    break
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
        elif kind in ("longPressId", "swipeId"):
            # longPressId ["<id prefix>", nth]: hold 2 s on the nth match (context menu).
            # swipeId ["<id prefix>", nth, dx, dy]: swipe from its centre by (dx, dy) pt (swipe actions).
            f = nth_frame(val[0], int(val[1]))
            if f is None:
                ok, detail = False, "no element #%s with id prefix %s" % (val[1], val[0])
            else:
                cx, cy = int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2)
                if kind == "longPressId":
                    # separate down / wait / up commands: on the Intel VM one `touch --down --up --delay` arrived
                    # as a plain tap (opened the row instead of its context menu), 2026-11-03
                    r = sh("axe", "touch", "-x", str(cx), "-y", str(cy), "--down", "--udid", udid, check=False)
                    time.sleep(2.0)
                    r2 = sh("axe", "touch", "-x", str(cx), "-y", str(cy), "--up", "--udid", udid, check=False)
                    if r.returncode == 0:
                        r = r2
                else:
                    r = sh("axe", "swipe", "--start-x", str(cx), "--start-y", str(cy), "--end-x",
                           str(max(1, cx + int(val[2]))), "--end-y", str(cy + int(val[3])), "--udid", udid, check=False)
                ok, detail = r.returncode == 0, ("%d,%d " % (cx, cy) + (r.stderr or r.stdout).strip())[:200]
        else:
            ok, detail = False, "unknown step type"
    except Exception as e:
        ok, detail = False, str(e)[:200]
    return ok, detail


for n, step in enumerate(steps, 1):
    kind = next((k for k in step if k not in META), None)
    if kind is None:
        continue
    val = step[kind]
    ok, detail = run_step(n, step, kind, val)
    if not ok and not step.get("optional") and kind not in ("wait", "shot"):
        # the slow Intel VM: give the screen 3 s more and do the same step once again before giving up
        print(n, kind, "RETRY after: " + detail, flush=True)
        time.sleep(3)
        ok, detail = run_step(n, step, kind, val)
    time.sleep(1)
    label = re.sub(r"\W+", "_", str(val))[:20] if kind in ("shot", "tree") else ""
    shot = "%02d_%s%s.png" % (n, kind, ("_" + label) if label else "")
    snap("%s/%s" % (out, shot))
    if os.path.exists("%s/%s" % (out, shot)) and os.path.getsize("%s/%s" % (out, shot)) < 10240:
        ok, detail = False, (detail + " screenshot under 10 KB (blank/failed)").strip()
    if not ok and step.get("optional"):
        ok, detail = True, ("optional: " + detail).strip()
    results.append({"n": n, "step": step, "ok": ok, "detail": detail, "screenshot": shot})
    print(n, kind, "OK" if ok else "FAIL " + detail, flush=True)

    if not ok:  # stop here instead of a long tail of knock-on failures (2026-11-03)
        stopped = n
        break

json.dump({"tester": tester, **persona, "device": name, "results": results, "failed": sum(not r["ok"] for r in results), "stopped_at": stopped},
          open(out + "/results.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
sh("xcrun", "simctl", "shutdown", udid, check=False, quiet=True)
if stopped:
    print("STOPPED_AT=%d" % stopped, flush=True)
    print("SCEN_RC=1", flush=True)
    sys.exit(1)
sys.exit(1 if any(not r["ok"] for r in results) else 0)  # a scenario with any failed step turns the CI job red
