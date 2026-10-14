"""Shared helpers for the simulator CI jobs (device picking, boot, install, seed, launch)."""
import json, os, re, struct, subprocess

PLACES = {"favorites": [
    {"id": 1, "name": "台北101", "lat": 25.033964, "lon": 121.564468, "radius": 200},
    {"id": 2, "name": "台中公園", "lat": 24.144, "lon": 120.6831, "radius": 150},
    {"id": 3, "name": "高雄85大樓", "lat": 22.6118, "lon": 120.3, "radius": 300},
    {"id": 4, "name": "新竹火車站", "lat": 24.8018, "lon": 120.9714, "radius": 100},
    {"id": 5, "name": "台南赤崁樓", "lat": 22.9972, "lon": 120.2026, "radius": 50}]}

LANG_ARGS = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]

# Logical screen size (points) per model name. Only used to group device types that share a size.
SIZES = [
    (r"iPhone SE", "375x667"), (r"iPhone (12|13) mini", "375x812"),
    (r"iPhone (11|XR)$", "414x896"), (r"iPhone (11 Pro Max|XS Max)", "414x896"),
    (r"iPhone 11 Pro$|iPhone XS$|iPhone X$", "375x812"),
    (r"iPhone (12|13|14)$|iPhone (12|13) Pro$|iPhone 16e|iPhone 17e", "390x844"),
    (r"iPhone (12|13) Pro Max|iPhone 14 Plus", "428x926"),
    (r"iPhone 14 Pro$|iPhone (15|16|17)$|iPhone 15 Pro$", "393x852"),
    (r"iPhone (14|15) Pro Max|iPhone (15|16) Plus", "430x932"),
    (r"iPhone (16|17) Pro$", "402x874"), (r"iPhone (16|17) Pro Max", "440x956"),
    (r"iPhone Air", "420x912"),
    (r"iPad mini \(A17|iPad mini \(6th", "744x1133"), (r"iPad mini", "768x1024"),
    (r"iPad \((A16|10th)", "820x1180"), (r"iPad \((8th|9th)", "810x1080"),
    (r"iPad Air 11-inch|iPad Air \(5th|iPad Air \(4th", "820x1180"),
    (r"iPad Air 13-inch", "1024x1366"),
    (r"iPad Pro 11-inch \(M[45]", "834x1210"),
    (r"iPad Pro 11-inch|iPad Pro \(11-inch\)", "834x1194"),
    (r"iPad (Air \(3rd|Pro \(10\.5)", "834x1112"),
    (r"iPad Pro 13-inch", "1032x1376"), (r"iPad Pro \(12\.9", "1024x1366"),
]


def sh(*a, check=True, quiet=False):
    r = subprocess.run([str(x) for x in a], capture_output=True, text=True)
    if not quiet and (r.stdout.strip() or r.stderr.strip()):
        print("$ " + " ".join(map(str, a))[:200] + "\n" + (r.stdout + r.stderr).strip()[:600], flush=True)
    if check and r.returncode:
        raise RuntimeError("failed: %s: %s" % (a, r.stderr.strip()[:300]))
    return r


def jload(*a):
    return json.loads(sh(*a, quiet=True).stdout)


def runtime():
    rts = [r for r in jload("xcrun", "simctl", "list", "runtimes", "-j")["runtimes"]
           if r.get("isAvailable") and r.get("platform", "iOS") == "iOS"]
    rts.sort(key=lambda r: [int(x) for x in re.findall(r"\d+", r["version"])])
    return rts[-1]


def size_of(name):
    for pat, sz in SIZES:
        if re.search(pat, name):
            return sz
    return "unk-" + re.sub(r"\W+", "_", name)


def find_or_create(type_id, name, rt):
    for devs in jload("xcrun", "simctl", "list", "devices", "available", "-j")["devices"].values():
        for d in devs:
            if d.get("deviceTypeIdentifier") == type_id:
                return d["udid"]
    return sh("xcrun", "simctl", "create", "ci-" + name, type_id, rt["identifier"]).stdout.strip()


def by_name(candidates):
    """First candidate model name this runtime supports -> (name, udid)."""
    rt = runtime()
    types = {t["name"]: t["identifier"] for t in rt.get("supportedDeviceTypes", [])}
    for n in candidates:
        if n in types:
            return n, find_or_create(types[n], n, rt)
    raise RuntimeError("none of %s available; have %s" % (candidates, sorted(types)))


def distinct_sizes(family):
    """(runtime, [(size, name, typeid)]) one per distinct logical size, smallest first."""
    rt = runtime()
    print("runtime:", rt["name"], flush=True)
    out = {}
    for t in rt.get("supportedDeviceTypes", []):  # runtime lists newest first (observed on CI): first per size wins
        if not t["name"].startswith(family):
            continue
        out.setdefault(size_of(t["name"]), t)  # keep the newest model per size
    res = [(sz, t["name"], t["identifier"]) for sz, t in out.items()]
    res.sort(key=lambda r: tuple(int(x) for x in re.findall(r"\d+", r[0])[:2]) or (9999,))
    return rt, res


OFFICIAL = {"iPhone": "375x667 375x812 390x844 393x852 402x874 414x896 420x912 428x926 430x932 440x956".split(),
            "iPad": "744x1133 768x1024 810x1080 820x1180 834x1112 834x1194 834x1210 1024x1366 1032x1376".split()}


def png_size(path):
    with open(path, "rb") as f:
        h = f.read(24)
    return struct.unpack(">II", h[16:24])


def bundle_id(app):
    return sh("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", app + "/Info.plist", quiet=True).stdout.strip()


def prepare(udid, app, bid):
    """Boot, install, seed the 5 public places."""
    sh("xcrun", "simctl", "boot", udid, check=False)
    sh("xcrun", "simctl", "bootstatus", udid, "-b", check=False, quiet=True)
    sh("xcrun", "simctl", "install", udid, app)
    data = sh("xcrun", "simctl", "get_app_container", udid, bid, "data").stdout.strip()
    os.makedirs(data + "/Documents", exist_ok=True)
    with open(data + "/Documents/places.json", "w", encoding="utf-8") as f:
        json.dump(PLACES, f, ensure_ascii=False)


def launch(udid, bid, extra=()):
    sh("xcrun", "simctl", "terminate", udid, bid, check=False, quiet=True)
    sh("xcrun", "simctl", "launch", udid, bid, *LANG_ARGS, *extra, check=False)
