# -*- coding: utf-8 -*-
"""make_source.py - PinFly 更新來源產生器（免費公開自動更新頻道的「出版社」）。

角色比喻：把蓋好的 IPA（iPhone 安裝檔）登記到一本「新書目錄」source/apps.json，
SideStore／AltStore 加入這個目錄網址後，就會自動發現新版本並提示更新。

做什麼：
1. 讀 IPA 檔，算出大小（bytes）。
2. 讀既有 apps.json（沒有就建新的），把新版本插到 versions 最前面（最新在前）；
   同版本號重跑會取代，不會重複。
3. 同時寫 AltStore 舊版頂層欄位（version、downloadURL…），舊用戶端也看得懂。
4. 每次執行寫 logs/make_source_<YYYYMMDD>.log（保留 7 天），只用 Python 標準函式庫。

用法：
  python tools/source/make_source.py --ipa PinFly.ipa --version 1.2.0 \
    --changelog "修正…" --download-url https://github.com/.../PinFly.ipa
"""
import argparse
import datetime
import json
import os
import sys
import plistlib
import re
import traceback
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LOG_DIR = os.path.join(ROOT, "logs")
BUNDLE_ID = "com.pinfly.app"
DEFAULT_ICON = ("https://raw.githubusercontent.com/Bug1910/GpsSimSelfRenew/member-channel/"
                "StikDebug/Assets.xcassets/PinFlyLogo.imageset/PinFlyLogo-1024.png")


def vkey(v):
    """語意版號轉可比較的數字串列，例如 1.10.0 > 1.9.0。"""
    if not re.fullmatch(r"\d+(\.\d+)*", v):
        raise SystemExit("版號格式不合 (需為 1.2.3 型): %s" % v)
    return [int(x) for x in v.split(".")]


def read_plist(ipa):
    """從 IPA(zip) 的 Payload/*.app/Info.plist 讀出 Info.plist 內容。"""
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise SystemExit("IPA 內需剛好一個 Info.plist，找到 %d" % len(names))
        return plistlib.loads(z.read(names[0]))


def log(msg):
    os.makedirs(LOG_DIR, exist_ok=True)
    now = datetime.datetime.now()
    path = os.path.join(LOG_DIR, "make_source_%s.log" % now.strftime("%Y%m%d"))
    with open(path, "a", encoding="utf-8") as f:
        f.write("%s %s\n" % (now.strftime("%Y-%m-%d %H:%M:%S"), msg))


def prune_logs(days=7):
    cutoff = datetime.datetime.now().timestamp() - days * 86400
    for n in os.listdir(LOG_DIR):
        p = os.path.join(LOG_DIR, n)
        if n.startswith("make_source_") and os.path.getmtime(p) < cutoff:
            os.remove(p)


def build(args):
    ipa = args.ipa
    if not os.path.isfile(ipa):
        raise SystemExit("找不到 IPA: %s" % ipa)
    size = os.path.getsize(ipa)
    info = read_plist(ipa)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise SystemExit("IPA 的 CFBundleIdentifier=%s，不是 %s" % (info.get("CFBundleIdentifier"), BUNDLE_ID))
    short = info.get("CFBundleShortVersionString")
    if short != args.version:
        raise SystemExit("--version %s 與 IPA 的 CFBundleShortVersionString %s 不符" % (args.version, short))
    vkey(args.version)
    build_no = str(info.get("CFBundleVersion", ""))
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
    date = args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    version = {
        "version": args.version,
        "buildVersion": build_no,
        "date": date,
        "localizedDescription": args.changelog,
        "downloadURL": args.download_url,
        "size": size,
        "minOSVersion": args.min_os,
    }
    out = args.out
    if os.path.isfile(out):
        with open(out, "r", encoding="utf-8") as f:
            src = json.load(f)
    else:
        src = {
            "name": args.source_name,
            "identifier": "com.pinfly.source",
            "subtitle": "PinFly 更新來源",
            "description": "PinFly 預編譯安裝檔的更新頻道。",
            "apps": [],
            "news": [],
        }
    app = next((a for a in src["apps"] if a.get("bundleIdentifier") == BUNDLE_ID), None)
    if app is None:
        app = {
            "name": "PinFly",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": args.developer,
            "subtitle": "iPhone 定位工具",
            "localizedDescription": "PinFly：改 iPhone 定位並自動續簽。",
            "iconURL": args.icon_url,
            "tintColor": "2D7DD2",
            "screenshots": [],
            "appPermissions": {"entitlements": [], "privacy": privacy},
            "versions": [],
        }
        src["apps"].append(app)
    app["appPermissions"] = {"entitlements": [], "privacy": privacy}
    old = [v for v in app.get("versions", []) if v.get("version") != args.version]
    if old and not args.allow_downgrade and vkey(args.version) < max(vkey(v["version"]) for v in old):
        raise SystemExit("版本 %s 低於目前最新，若確定請加 --allow-downgrade" % args.version)
    vs = sorted(old + [version], key=lambda v: vkey(v["version"]), reverse=True)
    app["versions"] = vs
    # 舊版 AltStore 頂層欄位（取最新版）
    app.update({"version": version["version"], "versionDate": date,
                "versionDescription": args.changelog,
                "downloadURL": args.download_url, "size": size})
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(src, f, ensure_ascii=False, indent=2)
        f.write("\n")
    log("寫入 %s：版本 %s、大小 %d、共 %d 個版本" % (out, args.version, size, len(vs)))
    print("OK %s version=%s size=%d versions=%d" % (out, args.version, size, len(vs)))


def main():
    p = argparse.ArgumentParser(description="產生／更新 SideStore 來源 apps.json")
    p.add_argument("--ipa", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--changelog", default="")
    p.add_argument("--download-url", required=True)
    p.add_argument("--out", default=os.path.join(ROOT, "source", "apps.json"))
    p.add_argument("--allow-downgrade", action="store_true")
    p.add_argument("--date", default=None, help="ISO8601，預設現在 UTC")
    p.add_argument("--min-os", default="17.4")
    p.add_argument("--developer", default="PinFly")
    p.add_argument("--source-name", default="PinFly")
    p.add_argument("--icon-url", default=DEFAULT_ICON)
    log("啟動 argv=%s" % sys.argv[1:])
    try:
        args = p.parse_args()
    except SystemExit as e:
        log("參數錯誤 結束碼=%s" % e.code)
        raise
    try:
        build(args)
        prune_logs()
        log("結束 成功")
    except SystemExit as e:
        log("結束 失敗: %s" % e)
        raise
    except Exception:
        log("錯誤\n" + traceback.format_exc())
        raise


if __name__ == "__main__":
    main()
