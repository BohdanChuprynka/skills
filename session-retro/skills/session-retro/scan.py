#!/usr/bin/env python3
"""Measure a Claude Code session from its transcript. Stdlib only.

The model's memory of a session is unreliable, and after a compaction it is
partly gone. The transcript on disk is neither. This counts what actually
happened so the retrospective argues from numbers instead of impressions.

Usage:
  python3 scan.py                 # newest session for the current project
  python3 scan.py --session <id>  # a specific one
  python3 scan.py --list          # what is available
"""
import argparse, collections, datetime as dt, glob, hashlib, json, os, sys

PROJECTS = os.path.expanduser("~/.claude/projects")
# A run of the same tool this long usually means a loop that wanted a script.
RUN_ALERT = 4
# A gap this big is the session waiting on something, not thinking.
GAP_ALERT_S = 60
# A gap this big is the user stepping away, not the session waiting. Excluded from
# both the waits and the elapsed span, or one overnight break swamps the report.
GAP_BREAK_S = 1800


def project_dir(cwd):
    return os.path.join(PROJECTS, cwd.replace("/", "-"))


def load(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def ts(rec):
    t = rec.get("timestamp")
    if not t:
        return None
    try:
        return dt.datetime.fromisoformat(t.replace("Z", "+00:00"))
    except ValueError:
        return None


def blocks(rec, kind):
    msg = rec.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return []
    return [b for b in content if isinstance(b, dict) and b.get("type") == kind]


def sig(name, inp):
    """Identity of a call, for spotting exact repeats."""
    try:
        s = json.dumps(inp, sort_keys=True)[:2000]
    except (TypeError, ValueError):
        s = str(inp)[:2000]
    return name + ":" + hashlib.sha1(s.encode()).hexdigest()[:12]


def summarise(inp):
    for k in ("command", "url", "file_path", "pattern", "query", "expression"):
        v = inp.get(k)
        if isinstance(v, str):
            return v.replace("\n", " ")[:90]
    return ""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--session")
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--list", action="store_true")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()

    if a.selftest:
        assert sig("A", {"x": 1}) == sig("A", {"x": 1})
        assert sig("A", {"x": 1}) != sig("A", {"x": 2})
        assert summarise({"command": "ls -la\nwc"}) == "ls -la wc"
        assert summarise({}) == ""
        assert ts({"timestamp": "bad"}) is None
        assert GAP_ALERT_S < GAP_BREAK_S
        print("selftest ok")
        return

    d = project_dir(a.cwd)
    files = sorted(glob.glob(os.path.join(d, "*.jsonl")), key=os.path.getmtime, reverse=True)
    if not files:
        sys.exit(f"no transcripts under {d}")
    if a.list:
        for f in files[:15]:
            m = dt.datetime.fromtimestamp(os.path.getmtime(f))
            print(f"{os.path.basename(f)[:-6]}  {m:%Y-%m-%d %H:%M}  {os.path.getsize(f)/1e6:.1f} MB")
        return

    path = next((f for f in files if a.session and a.session in f), files[0])
    recs = load(path)

    calls, results, gaps, breaks, user_turns = [], {}, [], [], 0
    prev_t, active = None, 0.0
    for r in recs:
        t = ts(r)
        if prev_t and t:
            d = (t - prev_t).total_seconds()
            if GAP_ALERT_S < d <= GAP_BREAK_S:
                gaps.append((d, prev_t))
            elif d > GAP_BREAK_S:
                breaks.append((d, prev_t))
            else:
                active += d
        if t:
            prev_t = t
        if r.get("type") == "user" and isinstance((r.get("message") or {}).get("content"), str):
            user_turns += 1
        for b in blocks(r, "tool_use"):
            calls.append({"name": b.get("name", "?"), "input": b.get("input") or {},
                          "id": b.get("id"), "t": t})
        for b in blocks(r, "tool_result"):
            body = b.get("content")
            text = body if isinstance(body, str) else json.dumps(body)[:4000]
            results[b.get("tool_use_id")] = {"err": bool(b.get("is_error")), "len": len(text or "")}

    by_name = collections.Counter(c["name"] for c in calls)
    dupes = collections.Counter(sig(c["name"], c["input"]) for c in calls)
    errs = sum(1 for c in calls if results.get(c["id"], {}).get("err"))
    payload = sum(results.get(c["id"], {}).get("len", 0) for c in calls)

    runs, cur = [], []
    for c in calls:
        if cur and c["name"] == cur[-1]["name"]:
            cur.append(c)
        else:
            if len(cur) >= RUN_ALERT:
                runs.append(cur)
            cur = [c]
    if len(cur) >= RUN_ALERT:
        runs.append(cur)

    span = f"{active/60:.0f} min active"
    if breaks:
        span += f" across {len(breaks)+1} sittings"

    print(f"session      {os.path.basename(path)[:-6]}")
    print(f"span         {span}")
    print(f"user turns   {user_turns}")
    print(f"tool calls   {len(calls)}   errors {errs}")
    print(f"result bytes {payload/1e6:.2f} MB returned into context")
    print()
    print("BY TOOL")
    for n, c in by_name.most_common(12):
        print(f"  {c:>4}  {n}")
    print()
    print(f"RUNS OF THE SAME TOOL ({RUN_ALERT}+ back to back) -- each is a candidate for a script")
    if not runs:
        print("  none")
    for r in sorted(runs, key=len, reverse=True)[:8]:
        print(f"  {len(r):>3}x {r[0]['name']:<28} first: {summarise(r[0]['input'])}")
    print()
    print("EXACT REPEATS (same tool, same input)")
    rep = [(k, v) for k, v in dupes.items() if v > 1]
    if not rep:
        print("  none")
    for k, v in sorted(rep, key=lambda kv: -kv[1])[:8]:
        c = next(c for c in calls if sig(c["name"], c["input"]) == k)
        print(f"  {v:>3}x {c['name']:<28} {summarise(c['input'])}")
    print()
    print(f"WAITS OVER {GAP_ALERT_S}s (breaks over {GAP_BREAK_S//60} min excluded as time away)")
    if not gaps:
        print("  none")
    for secs, when in sorted(gaps, key=lambda g: -g[0])[:6]:
        print(f"  {secs/60:>5.1f} min  after {when:%H:%M:%S}")


if __name__ == "__main__":
    main()
