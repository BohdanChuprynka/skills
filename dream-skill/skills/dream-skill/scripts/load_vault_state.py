#!/usr/bin/env python3
"""
load_vault_state.py — snapshot an Obsidian vault for reconciliation.

Walks configured sub-vaults, extracts:
  - Page titles + paths
  - Frontmatter fields (status, updated, tags, needs_verification, etc.)
  - "Current Goals" / "Status" / "Current Priorities" sections if present
  - Stale flags (pages with `updated:` older than --stale-days)

Outputs compact markdown for LLM consumption. Skips body text — the goal is a
structural snapshot, not a content dump.

Configuration:
  Priority order: CLI flag > env var > config file > default.
  --vault-root / DREAM_VAULT_ROOT     vault location
  --config                            vault-paths.toml; if missing or empty,
                                      falls back to walking ALL .md files under
                                      vault root.

Examples:
    python load_vault_state.py --vault-root ~/Documents/Obsidian
    python load_vault_state.py --config ./config/vault-paths.toml --output /tmp/v.md
    python load_vault_state.py --stale-days 30
"""

import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    import tomllib  # py3.11+
except ImportError:
    tomllib = None


# ============================================================
# Defaults
# ============================================================

DEFAULT_VAULT_ROOT = Path(os.environ.get(
    "DREAM_VAULT_ROOT",
    str(Path.home() / "Documents" / "Obsidian"),
))
DEFAULT_OUTPUT = Path("/tmp/dream-vault.md")
DEFAULT_STALE_DAYS = 60

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---", re.DOTALL)


# ============================================================
# Frontmatter / section helpers
# ============================================================

def parse_frontmatter(text: str) -> dict:
    """Cheap YAML-ish frontmatter parser. Handles flat key: value only."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            k, _, v = line.partition(":")
            out[k.strip()] = v.strip().strip("\"'")
    return out


def parse_date(s: str):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).replace(
            tzinfo=timezone.utc if "T" not in s else None,
        )
    except (ValueError, TypeError):
        pass
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(s[:len(fmt)], fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def extract_section(text: str, header: str, max_chars: int = 400) -> str:
    """Pull content under a markdown `## <header>` until next `##`."""
    pattern = re.compile(
        rf"^##\s+{re.escape(header)}\s*\n(.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    m = pattern.search(text)
    if not m:
        return ""
    body = m.group(1).strip()
    return body[:max_chars] + ("…" if len(body) > max_chars else "")


# ============================================================
# Vault walking
# ============================================================

def walk_subvault(vault_path: Path, stale_cutoff: datetime) -> list:
    """Return list of page dicts for one sub-vault."""
    pages = []

    # Prefer wiki/ subfolder if present, else scan the sub-vault root
    wiki = vault_path / "wiki" if (vault_path / "wiki").exists() else vault_path

    for md in wiki.rglob("*.md"):
        if md.name.startswith("."):
            continue
        try:
            text = md.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        fm = parse_frontmatter(text)
        updated = parse_date(fm.get("updated", ""))
        stale = bool(updated and updated < stale_cutoff)

        pages.append({
            "vault": vault_path.name,
            "path": str(md.relative_to(vault_path)),
            "title": md.stem,
            "status": fm.get("status", ""),
            "tags": fm.get("tags", ""),
            "updated": fm.get("updated", ""),
            "needs_verification": fm.get("needs_verification", ""),
            "stale": stale,
            "current_goals": extract_section(text, "Current Goals"),
            "current_priorities": extract_section(text, "Current Priorities"),
            "status_section": extract_section(text, "Status"),
        })
    return pages


def walk_flat(root: Path, stale_cutoff: datetime) -> list:
    """Fallback when no sub-vault config exists: scan ALL .md under vault root."""
    pages = []
    for md in root.rglob("*.md"):
        if md.name.startswith("."):
            continue
        # Don't reconcile our own reports
        rel = md.relative_to(root)
        if rel.parts and rel.parts[0] in ("dream-reports", ".dream-rollback"):
            continue
        try:
            text = md.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        fm = parse_frontmatter(text)
        updated = parse_date(fm.get("updated", ""))
        stale = bool(updated and updated < stale_cutoff)

        # bucket by first path segment if any, else "(root)"
        bucket = rel.parts[0] if len(rel.parts) > 1 else "(root)"

        pages.append({
            "vault": bucket,
            "path": str(rel),
            "title": md.stem,
            "status": fm.get("status", ""),
            "tags": fm.get("tags", ""),
            "updated": fm.get("updated", ""),
            "needs_verification": fm.get("needs_verification", ""),
            "stale": stale,
            "current_goals": extract_section(text, "Current Goals"),
            "current_priorities": extract_section(text, "Current Priorities"),
            "status_section": extract_section(text, "Status"),
        })
    return pages


# ============================================================
# Output formatting
# ============================================================

def format_vault_section(vault_name: str, pages: list) -> str:
    lines = [f"\n## Vault: {vault_name} ({len(pages)} pages)"]

    actives = [p for p in pages if p["status"].lower() in ("active", "in-progress", "")]
    archived = [p for p in pages if p["status"].lower() in ("archived", "completed", "paused")]
    needs_verif = [p for p in pages if p["needs_verification"]]
    stales = [p for p in pages if p["stale"]]

    lines.append(f"\n### Active ({len(actives)})")
    for p in sorted(actives, key=lambda x: x["title"]):
        title = p["title"]
        status_part = f" [{p['status']}]" if p["status"] else ""
        upd_part = f" updated={p['updated']}" if p["updated"] else ""
        lines.append(f"- {title}{status_part}{upd_part}")
        if p["current_goals"]:
            lines.append(f"  current-goals: {p['current_goals']!r}")
        if p["current_priorities"]:
            lines.append(f"  current-priorities: {p['current_priorities']!r}")

    if archived:
        lines.append(f"\n### Archived ({len(archived)})")
        for p in sorted(archived, key=lambda x: x["title"]):
            lines.append(f"- {p['title']} [{p['status']}]")

    if needs_verif:
        lines.append(f"\n### Needs verification ({len(needs_verif)})")
        for p in needs_verif:
            lines.append(f"- {p['title']} -> needs: {p['needs_verification']}")

    if stales:
        lines.append(f"\n### Stale `updated:` older than cutoff ({len(stales)})")
        for p in stales[:20]:
            lines.append(f"- {p['title']} (updated={p['updated']})")

    return "\n".join(lines)


def load_config(path: Path) -> dict:
    if tomllib is None:
        return {}
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


# ============================================================
# Driver
# ============================================================

def main() -> int:
    ap = argparse.ArgumentParser(description="Snapshot Obsidian vault state.")
    ap.add_argument(
        "--vault-root",
        default=str(DEFAULT_VAULT_ROOT),
        help="Vault root directory (default: $DREAM_VAULT_ROOT or ~/Documents/Obsidian)",
    )
    ap.add_argument(
        "--config",
        default=None,
        help="Path to vault-paths.toml (default: <skill>/config/vault-paths.toml if present)",
    )
    ap.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="Output file path (default: /tmp/dream-vault.md). Use '-' for stdout.",
    )
    ap.add_argument(
        "--stale-days",
        type=int,
        default=DEFAULT_STALE_DAYS,
        help=f"Pages with `updated:` older than this are flagged stale (default: {DEFAULT_STALE_DAYS})",
    )
    ap.add_argument(
        "--verbose",
        action="store_true",
        help="Print scan progress to stderr",
    )
    args = ap.parse_args()

    root = Path(args.vault_root).expanduser()
    if not root.exists():
        print(f"load_vault_state.py: vault root not found: {root}", file=sys.stderr)
        return 1

    # Resolve config path: explicit > skill-dir default > none
    if args.config is None:
        script_dir = Path(__file__).resolve().parent
        candidate = script_dir.parent / "config" / "vault-paths.toml"
        cfg_path = candidate if candidate.is_file() else None
    else:
        cfg_path = Path(args.config).expanduser()

    cfg = load_config(cfg_path) if cfg_path else {}
    configured_vaults = cfg.get("vaults") if isinstance(cfg.get("vaults"), list) else None
    cfg_stale_days = cfg.get("stale_days") if isinstance(cfg.get("stale_days"), int) else None

    stale_days = args.stale_days
    if cfg_stale_days is not None:
        # CLI overrides config only if user explicitly set it (default == module default)
        if args.stale_days == DEFAULT_STALE_DAYS:
            stale_days = cfg_stale_days

    stale_cutoff = datetime.now(timezone.utc) - timedelta(days=stale_days)

    header_lines = [
        f"# Vault state snapshot — generated {datetime.now(timezone.utc).isoformat()}",
        f"# Vault root: {root}",
    ]

    body_lines: list[str] = []
    total_pages = 0

    if configured_vaults:
        header_lines.append(f"# Vaults scanned: {', '.join(configured_vaults)}")
        header_lines.append(f"# Stale cutoff: pages with updated < {stale_cutoff.date().isoformat()}")

        for vault_name in configured_vaults:
            vault_path = root / vault_name
            if not vault_path.exists():
                if args.verbose:
                    print(f"# WARN: vault not found at {vault_path}", file=sys.stderr)
                body_lines.append(f"\n## Vault: {vault_name} — NOT FOUND at {vault_path}")
                continue
            pages = walk_subvault(vault_path, stale_cutoff)
            total_pages += len(pages)
            body_lines.append(format_vault_section(vault_name, pages))
    else:
        # Graceful degradation: walk ALL .md under root, bucket by first path segment
        header_lines.append("# Vaults scanned: (no config — flat walk of all .md files)")
        header_lines.append(f"# Stale cutoff: pages with updated < {stale_cutoff.date().isoformat()}")

        all_pages = walk_flat(root, stale_cutoff)
        total_pages = len(all_pages)

        # Group by bucket
        buckets: dict[str, list] = {}
        for p in all_pages:
            buckets.setdefault(p["vault"], []).append(p)
        for bucket_name in sorted(buckets):
            body_lines.append(format_vault_section(bucket_name, buckets[bucket_name]))

    body_lines.append(f"\n# Total pages indexed: {total_pages}")

    body = "\n".join(header_lines + body_lines) + "\n"

    if args.output == "-":
        sys.stdout.write(body)
    else:
        out_path = Path(args.output).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(body, encoding="utf-8")
        if args.verbose:
            print(f"# wrote {out_path} ({out_path.stat().st_size} bytes)", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
