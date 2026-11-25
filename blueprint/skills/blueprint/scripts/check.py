#!/usr/bin/env python3
"""Check a built blueprint in headless Chrome: data errors, warnings, and screenshots.

Usage: check.py PAGE.html [--shots overview|zones|none] [--also HASH ...]

Prints errors and warnings that the page found in its own data, then writes
screenshots to <page dir>/shots/: overview.png, one per zone (zone-<id>.png) and
one per --also hash (for example --also c_check --also case:AG-004). Exit code 1
when the data has errors.

Chrome: BLUEPRINT_CHROME (path) or the usual install paths. Extra Chrome flags:
BLUEPRINT_CHROME_ARGS, for example "--proxy-server=socks5://127.0.0.1:1080"
when a local policy blocks direct network access.
"""
import html
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys

CANDIDATES = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              "/Applications/Chromium.app/Contents/MacOS/Chromium", "google-chrome", "chromium", "chromium-browser"]


def chrome():
    for c in [os.environ.get("BLUEPRINT_CHROME"), *CANDIDATES]:
        if c and (pathlib.Path(c).exists() or shutil.which(c)):
            return c
    sys.exit("No Chrome found. Set BLUEPRINT_CHROME.")


def run(args):
    base = [chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--virtual-time-budget=8000",
            *shlex.split(os.environ.get("BLUEPRINT_CHROME_ARGS", ""))]
    return subprocess.run(base + args, capture_output=True, text=True, timeout=120)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.exit(__doc__)
    page = pathlib.Path(argv[0]).resolve()
    shots = argv[argv.index("--shots") + 1] if "--shots" in argv else "zones"
    also = [argv[i + 1] for i, a in enumerate(argv) if a == "--also"]
    url = page.as_uri()
    dom = run(["--window-size=1800,1100", "--dump-dom", url]).stdout
    attr = lambda k: json.loads(html.unescape(m.group(1))) if (m := re.search(rf'data-bp-{k}="([^"]*)"', dom)) else None
    errors, warnings, zones = attr("errors"), attr("warnings"), attr("zones") or []
    if errors is None:
        print("The page did not finish its self-check (a script error, or no Chrome network for the CDN?).")
        sys.exit(1)
    for e in errors:
        print("ERROR  ", e)
    for w in warnings:
        print("WARN   ", w)
    print(f"{len(errors)} errors, {len(warnings)} warnings, {len(zones)} zones")
    if shots != "none":
        out = page.parent / "shots"
        out.mkdir(exist_ok=True)
        targets = [("overview", "")]
        if shots == "zones":
            targets += [(f"zone-{z}", f"zone:{z}") for z in zones]
        targets += [(re.sub(r"[^\w-]+", "-", h), h) for h in also]
        for name, h in targets:
            run(["--window-size=1800,1100", f"--screenshot={out / (name + '.png')}", url + ("#" + h if h else "")])
            print("shot   ", out / (name + ".png"))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
