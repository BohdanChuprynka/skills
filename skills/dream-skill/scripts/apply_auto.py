#!/usr/bin/env python3
"""
apply_auto.py — parse a dream report and apply proposals after user review.

Default behavior: dry-run preview (no writes). Use --apply to actually edit
vault files. Use --drop "<regex>" (repeatable) to skip proposals whose title
matches the pattern.

Workflow:
  1. dream.sh produces dream-<date>.md with TWO proposal categories:
       ## Auto-apply (multi-channel evidence)        -- >= 2 distinct channels
       ## Needs your confirmation (single-channel)   -- 1 channel only
     Both sorted by confidence desc.
  2. You read the report.
  3. You run: ./dream.sh --apply  (which calls this script).
  4. You can also call this script directly with --drop filters.

Confidence numbers are LOGGED but NEVER used to gate action — see prompts/system.md.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


# ============================================================
# Defaults
# ============================================================

DEFAULT_VAULT_ROOT = Path(os.environ.get(
    "DREAM_VAULT_ROOT",
    str(Path.home() / "Documents" / "Obsidian"),
))
DEFAULT_MODEL = os.environ.get("DREAM_MODEL", "claude-sonnet-4-6")
DEFAULT_INDEX_FILE = os.environ.get("DREAM_INDEX_FILE")  # explicit override; optional


# ============================================================
# Vault index discovery + update
# ============================================================

def find_index_for(target: Path, vault_root: Path) -> Path | None:
    """
    Discover the wiki index file responsible for `target`.

    Conventions tried in order:
      <vault-root>/<subdir>/wiki/<page>.md → <vault-root>/<subdir>/wiki/index.md
      <vault-root>/<subdir>/<page>.md      → <vault-root>/<subdir>/index.md
    """
    try:
        rel = target.relative_to(vault_root)
    except ValueError:
        return None
    parts = rel.parts
    if len(parts) >= 3 and parts[1] == "wiki":
        idx = vault_root / parts[0] / "wiki" / "index.md"
        if idx.is_file():
            return idx
    if len(parts) >= 2:
        idx = vault_root / parts[0] / "index.md"
        if idx.is_file():
            return idx
    return None


def _page_title_from_content(content: str, fallback: str) -> str:
    for line in content.splitlines()[:80]:
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def append_index_entry_if_missing(
    index_path: Path,
    page_path: Path,
    page_title: str,
    summary: str,
    cycle_date: str,
) -> tuple[str, str] | None:
    """
    Append a list entry for `page_path` to `index_path` if not already linked.
    Idempotent: existing links (in any common form) cause the call to be a no-op
    so we never duplicate or clobber user-curated descriptions.

    Returns (old_content, new_content) on change, or None if no change made.
    """
    old = index_path.read_text(encoding="utf-8")
    rel_link = os.path.relpath(page_path, index_path.parent)
    # Match the link in markdown link form, optionally with ./ prefix or
    # with the .md extension stripped (Obsidian-style)
    stem_link = re.sub(r"\.md$", "", rel_link)
    rx = re.compile(
        r"\]\(\.?/?\s*(?:"
        + re.escape(rel_link)
        + r"|"
        + re.escape(stem_link)
        + r")\s*\)"
    )
    if rx.search(old):
        return None
    # Also catch Obsidian [[wikilink]] style — strip dir + .md
    wikilink_name = Path(rel_link).stem
    wikilink_rx = re.compile(r"\[\[\s*" + re.escape(wikilink_name) + r"\s*(?:\|[^\]]*)?\]\]")
    if wikilink_rx.search(old):
        return None

    new_line = (
        f"- [{page_title}]({rel_link}) — added {cycle_date}"
        + (f": {summary}" if summary else "")
    )
    lines = old.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    lines.append(new_line)
    new = "\n".join(lines) + "\n"
    index_path.write_text(new, encoding="utf-8")
    return old, new

# Channels we detect heuristically in the "Evidence" field
CHANNEL_PATTERNS = [
    (re.compile(r"Session\s+[0-9a-f]{6,}", re.IGNORECASE), "sessions"),
    (re.compile(r"\bNotion[\s:]", re.IGNORECASE), "notion"),
    (re.compile(r"\bCalendar[\s:]", re.IGNORECASE), "calendar"),
    (re.compile(r"\bGmail[\s:]", re.IGNORECASE), "gmail"),
    (re.compile(r"\bFile(?:system)?[\s:]", re.IGNORECASE), "filesystem"),
    (re.compile(r"\bGitHub[\s:]", re.IGNORECASE), "github"),
]


# ============================================================
# Vault subdir discovery
# ============================================================

def load_vault_subdirs(vault_root: Path, config_path: Path | None) -> list[str]:
    """Read vault subdirs from TOML config; fall back to scanning the vault root."""
    if config_path and config_path.is_file():
        try:
            import tomllib
            cfg = tomllib.loads(config_path.read_text(encoding="utf-8"))
            vaults = cfg.get("vaults")
            if isinstance(vaults, list) and vaults:
                return [str(v) for v in vaults]
        except Exception:
            pass

    # Fallback: every top-level directory under vault_root (skipping hidden/output)
    if vault_root.is_dir():
        out = []
        for d in sorted(vault_root.iterdir()):
            if not d.is_dir():
                continue
            if d.name.startswith(".") or d.name in ("dream-reports", ".dream-rollback"):
                continue
            out.append(d.name)
        return out
    return []


# ============================================================
# Report parsing
# ============================================================

def count_channels(evidence_text: str) -> list[str]:
    found = set()
    for pattern, label in CHANNEL_PATTERNS:
        if pattern.search(evidence_text):
            found.add(label)
    return sorted(found)


def _parse_section(section_text: str, category_label: str) -> list[dict]:
    """Extract proposal dicts from one report section."""
    proposals = []
    # The dream report uses `- ?` as the per-proposal bullet leader
    # (the question-mark emoji u2753). Match either the emoji or a literal '?'.
    chunks = re.split(r"\n(?=-\s+(?:❓|\?))", section_text)
    for chunk in chunks:
        chunk = chunk.strip()
        if not re.match(r"^-\s+(❓|\?)", chunk):
            continue

        title_m = re.match(r"-\s+(?:❓|\?)\s*(.+)", chunk)
        title = title_m.group(1).strip() if title_m else ""
        title = re.sub(r"\*\*", "", title)

        ev_m = re.search(
            r"\*\*Evidence:\*\*\s*(.+?)(?=\n\s+-\s+\*\*|\Z)",
            chunk,
            re.DOTALL,
        )
        prop_m = re.search(
            r"\*\*Proposed update:\*\*\s*(.+?)(?=\n\s+-\s+\*\*|\Z)",
            chunk,
            re.DOTALL,
        )
        conf_m = re.search(r"\*\*Confidence:\*\*\s*([0-9.]+)", chunk)

        evidence = ev_m.group(1).strip() if ev_m else ""
        proposed = prop_m.group(1).strip() if prop_m else ""
        confidence = float(conf_m.group(1)) if conf_m else None
        channels = count_channels(evidence)

        proposals.append({
            "category": category_label,
            "title": title,
            "evidence": evidence,
            "proposed": proposed,
            "llm_confidence": confidence,
            "channels": channels,
        })
    return proposals


def parse_report(report_path: Path) -> list[dict]:
    """Parse BOTH proposal sections from the dream report."""
    text = report_path.read_text(encoding="utf-8")

    auto_m = re.search(
        r"^## Auto-apply.*?(?=^## |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    needs_m = re.search(
        r"^## Needs your confirmation.*?(?=^## |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )

    proposals = []
    if auto_m:
        proposals.extend(_parse_section(auto_m.group(0), "auto-apply"))
    if needs_m:
        proposals.extend(_parse_section(needs_m.group(0), "needs-confirmation"))
    return proposals


# ============================================================
# Target-file resolution
# ============================================================

def resolve_target_file(
    proposed_text: str,
    vault_root: Path,
    subdirs: list[str],
) -> Path | None:
    """Extract first vault file referenced in proposal text. Heuristic, multi-pass."""
    backticks = re.findall(r"`([^`]+)`", proposed_text)

    for raw in backticks:
        candidate = raw.strip()
        if not candidate:
            continue

        if candidate.endswith(".md"):
            # Try each subdir/wiki/<candidate>, then vault_root/<candidate>
            for sub in subdirs:
                p = vault_root / sub / "wiki" / candidate
                if p.exists():
                    return p
                p2 = vault_root / sub / candidate
                if p2.exists():
                    return p2
            p3 = vault_root / candidate
            if p3.exists():
                return p3
            # Last resort: glob match by basename
            for sub in subdirs:
                wiki = vault_root / sub / "wiki"
                if wiki.exists():
                    matches = list(wiki.rglob(Path(candidate).name))
                    if matches:
                        return matches[0]

        # No .md suffix — search by stem, possibly stripping `[status]` suffix
        stripped = re.sub(r"\s*\[[^\]]+\]\s*$", "", candidate).strip()
        for variant in (stripped, candidate, candidate + ".md", stripped + ".md"):
            for sub in subdirs:
                wiki = vault_root / sub / "wiki"
                if not wiki.exists():
                    wiki = vault_root / sub
                    if not wiki.exists():
                        continue
                for md in wiki.rglob("*.md"):
                    if md.stem in (variant, stripped) or md.name == variant:
                        return md
    return None


# ============================================================
# Apply (per-proposal Claude call)
# ============================================================

def apply_proposal(
    proposal: dict,
    vault_root: Path,
    subdirs: list[str],
    model: str,
) -> dict:
    target = resolve_target_file(proposal["proposed"], vault_root, subdirs)
    base_record = {
        "title": proposal["title"],
        "channels": proposal["channels"],
        "llm_confidence": proposal["llm_confidence"],
    }
    if not target:
        return {**base_record, "status": "skipped",
                "reason": "could not resolve target file from proposal text"}

    old_content = target.read_text(encoding="utf-8")
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    target_rel = target.relative_to(vault_root)

    prompt = f"""You are applying ONE update to a markdown file in the user's Obsidian vault.

# PROPOSAL FROM DREAM REPORT

Title: {proposal['title']}

Evidence:
{proposal['evidence']}

Proposed update:
{proposal['proposed']}

# CURRENT FILE CONTENT -- {target_rel}

```
{old_content}
```

# TASK

Apply the proposed update to this file. Rules:
- Output the COMPLETE new file content (frontmatter + body).
- Update the `updated:` frontmatter field to {today} if present; add it if missing.
- Preserve all existing content not affected by the proposal.
- Use Obsidian-style [[wikilinks]] for cross-references.
- Be surgical: minimum diff that satisfies the proposal.
- The very first character of your output MUST be `-` (the start of YAML frontmatter `---`).
- Do NOT wrap output in a code fence. Do NOT add commentary. Just the file content."""

    try:
        result = subprocess.run(
            [
                "claude",
                "--model", model,
                "--print",
                "--output-format", "json",
                "--tools", "",
                "--permission-mode", "bypassPermissions",
                prompt,
            ],
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired:
        return {**base_record, "status": "error",
                "reason": "claude call timed out after 180s",
                "file": str(target_rel)}

    if result.returncode != 0:
        return {**base_record, "status": "error",
                "reason": f"claude exit {result.returncode}: {result.stderr[:200]}",
                "file": str(target_rel)}

    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {**base_record, "status": "error",
                "reason": "invalid JSON from claude",
                "file": str(target_rel)}

    new_content = response.get("result", "").strip()
    if not new_content:
        return {**base_record, "status": "error",
                "reason": "empty result from claude",
                "file": str(target_rel)}

    if new_content.startswith("```"):
        new_content = re.sub(r"^```[a-zA-Z]*\n", "", new_content)
        new_content = re.sub(r"\n```\s*$", "", new_content).strip()

    if not new_content.startswith("---"):
        return {**base_record, "status": "error",
                "reason": "applied content missing frontmatter opener (---)",
                "file": str(target_rel)}

    if not new_content.endswith("\n"):
        new_content += "\n"
    target.write_text(new_content, encoding="utf-8")

    return {
        **base_record,
        "status": "applied",
        "file": str(target_rel),
        "old_content": old_content,
        "new_content": new_content,
        "apply_cost_usd": response.get("total_cost_usd", 0.0),
    }


# ============================================================
# Dry-run diff
# ============================================================

def print_dry_run(proposal: dict, target: Path | None, vault_root: Path) -> None:
    cat_tag = "AUTO" if proposal["category"] == "auto-apply" else "NEEDS"
    conf = (f"{proposal['llm_confidence']:.2f}"
            if proposal["llm_confidence"] is not None else "?")
    title = proposal["title"][:80]
    channels = ",".join(proposal["channels"]) or "(none)"
    print(f"  [dry-run] [{cat_tag}] conf={conf} channels={channels}")
    print(f"            title: {title}")
    if target:
        print(f"            target: {target.relative_to(vault_root)}")
    else:
        print("            target: (UNRESOLVED — would be skipped)")
    if proposal["proposed"]:
        first_line = proposal["proposed"].splitlines()[0][:140]
        print(f"            proposed: {first_line}")
    print()


# ============================================================
# Driver
# ============================================================

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Parse a dream report and (optionally) apply proposals after user review.",
    )
    ap.add_argument(
        "--vault-root",
        default=str(DEFAULT_VAULT_ROOT),
        help="Vault root (default: $DREAM_VAULT_ROOT or ~/Documents/Obsidian)",
    )
    ap.add_argument(
        "--report",
        required=True,
        help="Path to dream-<date>.md",
    )
    ap.add_argument(
        "--config",
        default=None,
        help="Path to vault-paths.toml (default: <skill>/config/vault-paths.toml)",
    )
    ap.add_argument(
        "--rollback-dir",
        default=None,
        help="Where to write rollback-<date>.json (default: <vault-root>/.dream-rollback)",
    )
    ap.add_argument(
        "--apply-log",
        default=None,
        help="Append-only JSONL log of every applied/dropped/error decision "
             "(default: <skill>/.apply-log.jsonl)",
    )
    ap.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model for per-proposal apply calls (default: {DEFAULT_MODEL})",
    )
    ap.add_argument(
        "--apply",
        action="store_true",
        help="Actually apply proposals. Without this flag, the script is a dry-run preview.",
    )
    ap.add_argument(
        "--drop",
        action="append",
        default=[],
        metavar="REGEX",
        help="Regex matched against proposal title (case-insensitive). Repeatable. "
             "Matching proposals are skipped.",
    )
    ap.add_argument(
        "--channels",
        default=None,
        help="Comma-separated channel allow-list. Only proposals whose detected "
             "channels overlap this set will be considered (e.g. 'notion,sessions').",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="(default; alias for not passing --apply)",
    )
    ap.add_argument(
        "--index-file",
        default=DEFAULT_INDEX_FILE,
        help="Path to a single vault index file to update with applied edits. "
             "Default: auto-discover <vault-root>/<subdir>/wiki/index.md per "
             "edit. Env: DREAM_INDEX_FILE. Skipped silently if no index is "
             "found at the resolved location.",
    )
    ap.add_argument(
        "--no-index-update",
        action="store_true",
        help="Disable post-apply vault index updates entirely.",
    )
    args = ap.parse_args()

    vault_root = Path(args.vault_root).expanduser().resolve()
    if not vault_root.is_dir():
        print(f"apply_auto.py: vault root not found: {vault_root}", file=sys.stderr)
        return 1

    report_path = Path(args.report).expanduser()
    if not report_path.exists():
        print(f"apply_auto.py: report not found: {report_path}", file=sys.stderr)
        return 1

    # Resolve config path
    if args.config is None:
        script_dir = Path(__file__).resolve().parent
        candidate = script_dir.parent / "config" / "vault-paths.toml"
        cfg_path = candidate if candidate.is_file() else None
    else:
        cfg_path = Path(args.config).expanduser()

    subdirs = load_vault_subdirs(vault_root, cfg_path)
    if not subdirs:
        print(f"apply_auto.py: WARN  no vault subdirs found "
              f"(no config, and no top-level dirs under {vault_root})", file=sys.stderr)

    rollback_dir = Path(args.rollback_dir).expanduser() if args.rollback_dir \
        else vault_root / ".dream-rollback"
    rollback_dir.mkdir(parents=True, exist_ok=True)

    skill_dir = Path(__file__).resolve().parent.parent
    apply_log_path = Path(args.apply_log).expanduser() if args.apply_log \
        else skill_dir / ".apply-log.jsonl"

    # Parse
    proposals = parse_report(report_path)
    if not proposals:
        print("  no proposals found in report")
        return 0

    auto = [p for p in proposals if p["category"] == "auto-apply"]
    needs = [p for p in proposals if p["category"] == "needs-confirmation"]
    print(f"  proposals parsed: {len(proposals)} total")
    print(f"    auto-apply section:        {len(auto)}")
    print(f"    needs-confirmation:        {len(needs)}")

    # Drop filter (regex)
    drop_patterns = []
    for d in args.drop:
        try:
            drop_patterns.append(re.compile(d, re.IGNORECASE))
        except re.error as e:
            print(f"apply_auto.py: invalid --drop regex {d!r}: {e}", file=sys.stderr)
            return 1

    # Channel allow-list
    channel_allow = None
    if args.channels:
        channel_allow = {c.strip() for c in args.channels.split(",") if c.strip()}

    def drop_reason(p: dict) -> str | None:
        for rx in drop_patterns:
            if rx.search(p["title"]):
                return f"regex /{rx.pattern}/"
        if channel_allow is not None:
            if not (set(p["channels"]) & channel_allow):
                return f"channels {p['channels']} not in allow-list {sorted(channel_allow)}"
        return None

    selected = []
    dropped_records = []
    for p in proposals:
        reason = drop_reason(p)
        if reason:
            dropped_records.append({**p, "drop_reason": reason})
            print(f"    DROP: {p['title'][:60]}  ({reason})")
        else:
            selected.append(p)

    # Dry-run
    if not args.apply:
        print("\n  [dry-run] proposals that WOULD be applied:")
        for p in selected:
            target = resolve_target_file(p["proposed"], vault_root, subdirs)
            print_dry_run(p, target, vault_root)
        summary = {
            "applied": 0,
            "errors": 0,
            "selected_for_apply": len(selected),
            "dropped": len(dropped_records),
            "auto_section_count": len(auto),
            "needs_section_count": len(needs),
            "apply_cost_usd": 0.0,
            "rollback_log": None,
            "dry_run": True,
        }
        print(f"::APPLY_SUMMARY::{json.dumps(summary)}")
        return 0

    # Real apply
    records = []
    total_cost = 0.0
    cycle_date = datetime.now(timezone.utc).date().isoformat()

    for p in selected:
        record = apply_proposal(p, vault_root, subdirs, model=args.model)
        record["category"] = p["category"]
        records.append(record)
        total_cost += float(record.get("apply_cost_usd") or 0.0)
        if record["status"] == "applied":
            print(f"  applied [{p['category']}] {record['file']}: {record['title'][:55]}")
        else:
            print(f"  ERROR   {record['title'][:60]}: {record.get('reason', '?')[:80]}")

    # Rollback log
    rollback_path = rollback_dir / f"rollback-{cycle_date}.json"
    rollback = {
        "cycle_date": cycle_date,
        "vault_root": str(vault_root),
        "applied": [r for r in records if r["status"] == "applied"],
        "errors": [r for r in records if r["status"] != "applied"],
        "dropped": [
            {
                "title": d["title"],
                "category": d["category"],
                "channels": d["channels"],
                "llm_confidence": d["llm_confidence"],
                "drop_reason": d["drop_reason"],
            }
            for d in dropped_records
        ],
        "apply_cost_usd": total_cost,
    }
    rollback_path.write_text(json.dumps(rollback, indent=2), encoding="utf-8")

    # Update vault index file(s) so newly-recorded pages show up in the
    # vault's content catalog. Idempotent: existing links are left alone.
    if not args.no_index_update:
        index_edits = []
        for r in records:
            if r["status"] != "applied":
                continue
            target = (vault_root / r["file"]).resolve()
            if args.index_file:
                idx = Path(args.index_file).expanduser().resolve()
                if not idx.is_file():
                    continue
            else:
                idx = find_index_for(target, vault_root)
                if idx is None:
                    continue
            page_title = _page_title_from_content(
                r.get("new_content", ""), target.stem
            )
            summary = (r.get("title") or "").strip()[:140]
            try:
                result = append_index_entry_if_missing(
                    idx, target, page_title, summary, cycle_date,
                )
            except Exception as e:
                print(f"  WARN: index update failed for {idx}: {e}")
                continue
            if result is None:
                continue
            old, new = result
            try:
                idx_rel = str(idx.relative_to(vault_root))
            except ValueError:
                idx_rel = str(idx)
            index_edits.append({
                "index": idx_rel,
                "before": old,
                "after": new,
            })
        if index_edits:
            rb = json.loads(rollback_path.read_text(encoding="utf-8"))
            rb["index_edits"] = index_edits
            rollback_path.write_text(
                json.dumps(rb, indent=2), encoding="utf-8",
            )
            print(f"  index updates: {len(index_edits)} file(s)")

    # Append apply log
    apply_log_path.parent.mkdir(parents=True, exist_ok=True)
    with apply_log_path.open("a", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "cycle_date": cycle_date,
                "category": r.get("category"),
                "title": r["title"][:200],
                "file": r.get("file"),
                "status": r["status"],
                "reason": r.get("reason"),
                "channels": r.get("channels", []),
                "llm_confidence": r.get("llm_confidence"),
                "apply_cost_usd": r.get("apply_cost_usd"),
            }) + "\n")
        for d in dropped_records:
            f.write(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "cycle_date": cycle_date,
                "category": d["category"],
                "title": d["title"][:200],
                "status": "dropped",
                "channels": d["channels"],
                "llm_confidence": d["llm_confidence"],
                "drop_reason": d["drop_reason"],
            }) + "\n")

    applied_count = sum(1 for r in records if r["status"] == "applied")
    err_count = sum(1 for r in records if r["status"] != "applied")
    summary = {
        "applied": applied_count,
        "errors": err_count,
        "dropped": len(dropped_records),
        "auto_section_count": len(auto),
        "needs_section_count": len(needs),
        "apply_cost_usd": round(total_cost, 4),
        "rollback_log": str(rollback_path),
        "dry_run": False,
    }
    print(f"::APPLY_SUMMARY::{json.dumps(summary)}")
    print(f"\n  rollback log: {rollback_path}")
    print(f"  to undo:      ./scripts/apply_undo.sh {cycle_date}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
