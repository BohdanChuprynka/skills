#!/usr/bin/env python3
"""Build a blueprint page from a data folder.

Usage: build.py DIR [--name NAME]

DIR/blueprint.js   required: `const BLUEPRINT = {...}` (see references/data-format.md)
DIR/sources.json   optional: verbatim texts, {key: {title, text, note?, parts?: [{name, text}]}}
DIR/eval.json      optional: eval cases, {label?, runs: {v0, v1}, totals?, cases: [...]}

Writes DIR/NAME.page.html (the body to publish as an Artifact) and DIR/NAME.html
(a standalone file with doctype). NAME defaults to the title in kebab case.
"""
import json
import pathlib
import re
import sys

SKILL = pathlib.Path(__file__).resolve().parent.parent


def stats(text):
    return {"chars": len(text), "bytes": len(text.encode()), "lines": text.count("\n") + 1,
            "words": len(text.split()), "tokens": round(len(text) / 4)}


def load_sources(path):
    if not path.exists():
        return {}
    out = {}
    for key, s in json.loads(path.read_text()).items():
        src = {"title": s.get("title", key), "text": s["text"], "note": s.get("note", ""), "stats": stats(s["text"])}
        if s.get("parts"):
            src["parts"] = [{"name": p["name"], **(stats(p["text"]) if "text" in p else {"chars": p["chars"], "tokens": round(p["chars"] / 4)})}
                            for p in s["parts"]]
        out[key] = src
    return out


def safe(js):
    # Keep "</script>" inside data from closing the page's script tag.
    return js.replace("</", "<\\/")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.exit(__doc__)
    d = pathlib.Path(argv[0]).resolve()
    data = (d / "blueprint.js").read_text()
    m = re.search(r'title:\s*"([^"]+)"', data)
    title = m.group(1) if m else "Architecture"
    name = argv[argv.index("--name") + 1] if "--name" in argv else re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    sources = load_sources(d / "sources.json")
    ev = (d / "eval.json").read_text() if (d / "eval.json").exists() else "null"
    page = (SKILL / "assets/renderer.html").read_text()
    for k, v in (("__TITLE__", title.replace("<", "&lt;")), ("__SOURCES__", safe(json.dumps(sources, ensure_ascii=False))),
                 ("__EVAL__", safe(ev)), ("__BLUEPRINT__", data.replace("</script", "<\\/script"))):
        assert page.count(k) == 1, k
        page = page.replace(k, v)
    (d / f"{name}.page.html").write_text(page)
    (d / f"{name}.html").write_text('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
                                    '<meta name="viewport" content="width=device-width, initial-scale=1">\n' + page + "\n</html>\n")
    print(f"{d / (name + '.html')}  ({len(page) // 1024} KB, {len(sources)} sources, eval {'yes' if ev != 'null' else 'no'})")


if __name__ == "__main__":
    main(sys.argv[1:])
