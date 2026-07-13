#!/usr/bin/env python3
"""Convert dream-skill pending.md + sidecar JSONs to the web review queue format.

Output is a cleanup-queue.json-compatible JSON file readable by serve-review.py.
Each pending.md entry becomes one card in the flip-card UI.

Usage:
    build-review-queue.py \
        --pending-md  ~/.claude/dream-skill/queue/pending.md \
        --sidecars-dir ~/.claude/dream-skill/queue/sidecars \
        --output ~/.claude/dream-skill/queue/review-input.json \
        [--existing-decisions ~/.claude/dream-skill/queue/review-decisions.json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

BUCKET_LABEL = {
    "destructive":  "destructive edit",
    "uncertain":    "uncertain fact",
    "brainstormed": "brainstormed idea",
}

BUCKET_SIGNAL = {
    "destructive":  "destructive",
    "uncertain":    "uncertain",
    "brainstormed": "brainstormed",
}

ACTION_VERB = {
    "new":        "APPEND",
    "supersede":  "SUPERSEDE",
    "contradict": "CONTRADICT",
    "duplicate":  "DUPLICATE",
}

# Existing review sidecars predate the bounded fact_class field.  Keep those
# cards filterable without rewriting their durable sidecars.  New runs carry
# the classifier's value directly, which always wins over this type-only
# compatibility map.
FACT_CLASS_MARKERS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("relationship", ("relationship", "person", "people", "mentor", "contact", "networking")),
    ("health", ("health", "medical", "symptom", "acne", "skin", "medication", "condition")),
    ("fitness", ("fitness", "workout", "exercise", "running", "nutrition", "body_composition")),
    ("schedule", ("schedule", "calendar", "appointment", "meeting_time", "deadline")),
    ("preference", ("preference", "preferred", "communication_style", "workflow_preference", "tool_choice")),
    ("identity", ("identity", "bio", "background", "education", "credential", "experience", "skill", "role")),
    ("learning", ("learning", "study", "course", "exam_prep", "knowledge")),
    ("project_constraint", ("project_constraint", "architecture_constraint", "security_constraint", "product_constraint")),
    ("project_decision", ("project_decision", "architecture_decision", "product_decision", "technical_decision")),
    ("goal", ("goal", "priority", "aspiration", "career_direction", "objective")),
    ("audit_telemetry", ("test_receipt", "commit_hash", "file_churn", "debug_state", "git_state")),
    ("active_state", ("active_work", "active_project", "project_state", "project_status", "project_blocker", "project_issue", "project_context", "current_state", "blocker", "task_request", "next_action", "work_context")),
)


def parse_pending_md(text: str) -> list[dict]:
    """Parse pending.md into a list of entry dicts."""
    entries = []
    # Split into blocks at "### " headings
    blocks = re.split(r"\n(?=### )", "\n" + text)
    for block in blocks:
        block = block.strip()
        if not block.startswith("### "):
            continue
        lines = block.splitlines()
        title = lines[0][4:].strip()

        def field(name: str) -> str:
            pat = re.compile(rf"^\*\*{re.escape(name)}:\*\*\s*(.*)", re.IGNORECASE)
            for ln in lines:
                m = pat.match(ln.strip())
                if m:
                    return m.group(1).strip()
            return ""

        # Evidence block: lines after "> "
        evidence_lines = [
            ln.lstrip("> ").strip()
            for ln in lines
            if ln.strip().startswith("> ")
        ]
        evidence = " ".join(evidence_lines).strip()

        entries.append({
            "title":      title,
            "bucket":     field("Bucket"),
            "confidence": field("Confidence"),
            "id":         field("ID"),
            "target":     field("Target"),
            "captured":   field("Captured"),
            "evidence":   evidence,
        })
    return entries


def parse_target(target_str: str) -> tuple[str, str, str | None]:
    """Parse 'vault_root/page.md#section' → (vault_root, page_rel, section|None)."""
    section = None
    if "#" in target_str:
        target_str, section = target_str.rsplit("#", 1)
    # vault_root is everything up to the first occurrence of /wiki/ or just split at first /
    # We don't need to fully resolve it here — just extract vault name from sidecar
    return target_str, section


def load_sidecar(sidecars_dir: Path, candidate_id: str) -> dict | None:
    if not candidate_id:
        return None
    p = sidecars_dir / f"{candidate_id}.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def first_nonempty_string(*values: object) -> str:
    """Return the first non-empty string without coercing structured values."""
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def fallback_fact_class(candidate_type: object, memory_tier: object) -> str:
    normalized = re.sub(
        r"[^a-z0-9]+", "_", str(candidate_type or "").casefold()
    ).strip("_")
    for fact_class, markers in FACT_CLASS_MARKERS:
        if any(marker in normalized for marker in markers):
            return fact_class
    return "active_state" if memory_tier == "current" else "other"


def build_entry(raw: dict, sidecar: dict | None, existing_decisions: dict) -> dict:
    # Stable digest (NOT builtin hash(), which is per-process randomized via
    # PYTHONHASHSEED): a fallback id must be identical across runs so resume /
    # existing-decisions keyed by id still match on the next invocation.
    cid = raw["id"] or "md-" + hashlib.sha1(
        (raw["title"] + raw["target"]).encode("utf-8")
    ).hexdigest()[:12]
    confidence = raw["confidence"] or "medium"
    bucket = raw["bucket"] or "uncertain"
    title = raw["title"]
    target_str = raw["target"]
    evidence = raw["evidence"]

    # Parse vault name and page from target string
    vault_name = ""
    page_path = target_str
    section_hint = ""

    # Always parse section from raw target_str as fallback
    if "#" in target_str:
        page_path, section_hint = target_str.rsplit("#", 1)

    if sidecar:
        t = sidecar.get("target", {})
        vault_name = t.get("vault", "") or vault_name
        page_path = t.get("page", page_path)
        section_hint = t.get("section", section_hint)

    # Build diff block
    action = sidecar.get("action", "new") if sidecar else "new"
    verb = ACTION_VERB.get(action, "APPEND")
    content = sidecar.get("content", title) if sidecar else title
    old_content = sidecar.get("old_content", "") if sidecar else ""
    # pending.md historically called reconciliation rationale "evidence".  Do
    # not repeat that ambiguity in the review JSON: exact MAP evidence and the
    # reconciler's explanation are separate fields.  Older sidecars do not
    # carry source evidence, so they correctly report it as unavailable.
    source_evidence = first_nonempty_string(
        sidecar.get("source_evidence") if sidecar else None,
        sidecar.get("evidence") if sidecar else None,
        sidecar.get("exact_evidence") if sidecar else None,
    )
    rationale = first_nonempty_string(
        sidecar.get("rationale") if sidecar else None,
        evidence,
    )

    diff: dict = {"verb": verb, "note": rationale}
    if action == "supersede" and old_content:
        diff["before"] = old_content
        diff["after"] = content
    elif action == "contradict" and old_content:
        diff["before"] = old_content
        diff["after"] = content
    else:
        diff["addLine"] = content

    # ``context`` remains for compatibility with older review clients, but it
    # is source material only.  Rationale never silently falls back into it.
    context = source_evidence

    decided = cid in existing_decisions
    decision = existing_decisions.get(cid)

    candidate_type = sidecar.get("candidate_type", "") if sidecar else ""
    memory_tier = sidecar.get("memory_tier", "") if sidecar else ""
    fact_class = first_nonempty_string(
        sidecar.get("fact_class") if sidecar else None,
        fallback_fact_class(candidate_type, memory_tier),
    )
    source_role = sidecar.get("source_role", "") if sidecar else ""
    source_date = sidecar.get("source_date", "") if sidecar else ""
    source_chat = sidecar.get("source_chat", "") if sidecar else ""
    source_event = sidecar.get("source_event") if sidecar else None
    historical_review = bool(sidecar.get("historical_review")) if sidecar else False
    quality_review_sample = bool(sidecar.get("quality_review_sample")) if sidecar else False
    run_id = sidecar.get("run_id", "") if sidecar else ""
    run_window = sidecar.get("run_window", {}) if sidecar else {}
    model_profile = sidecar.get("model_profile", {}) if sidecar else {}
    review_kind = sidecar.get("review_kind", "fact") if sidecar else "fact"
    detected_names = sidecar.get("detected_names", []) if sidecar else []
    review_cohort = first_nonempty_string(
        sidecar.get("review_cohort") if sidecar else None,
        "run" if run_id else "legacy",
    )

    return {
        "id":             cid,
        "signal":         BUCKET_SIGNAL.get(bucket, bucket),
        "signal_label":   BUCKET_LABEL.get(bucket, bucket),
        "confidence":     confidence,
        "category":       "judgment",
        "vault":          vault_name,
        "target_file":    page_path,
        "target_section": section_hint,
        "target_line":    None,
        "proposed_action": action,
        "diff":           diff,
        "context":        context,
        "source_evidence": source_evidence,
        "source_evidence_available": bool(source_evidence),
        "reconciliation_rationale": rationale,
        "deferred_count": 0,
        "first_seen":     raw.get("captured", "")[:10],
        "decided":        decided,
        "decision":       decision,
        "candidate_type": candidate_type,
        "fact_class":     fact_class,
        "memory_tier":    memory_tier,
        "source_role":    source_role,
        "source_date":    source_date,
        "source_chat":    source_chat,
        "source_event":   source_event,
        "historical_review": historical_review,
        "quality_review_sample": quality_review_sample,
        "run_id":         run_id,
        "review_cohort":  review_cohort,
        "cohort_id":      run_id or "legacy",
        "run_window":     run_window,
        "model_profile":  model_profile,
        "review_kind":    review_kind,
        "detected_names": detected_names if isinstance(detected_names, list) else [],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pending-md",  type=Path, required=True)
    ap.add_argument("--sidecars-dir", type=Path, required=True)
    ap.add_argument("--output",      type=Path, required=True)
    ap.add_argument("--existing-decisions", type=Path, default=None)
    ap.add_argument(
        "--include-orphans",
        action="store_true",
        help="include legacy pending entries without an applyable sidecar (diagnostics only)",
    )
    args = ap.parse_args()

    if not args.pending_md.exists():
        print(f"build-review-queue: {args.pending_md} not found", file=sys.stderr)
        # Write empty queue
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"schema_version": 2, "entries": []}, indent=2))
        args.output.chmod(0o600)
        args.output.parent.chmod(0o700)
        return 0

    text = args.pending_md.read_text(encoding="utf-8", errors="ignore")
    raw_entries = parse_pending_md(text)

    existing_decisions: dict = {}
    if args.existing_decisions and args.existing_decisions.exists():
        try:
            loaded = json.loads(args.existing_decisions.read_text())
            if isinstance(loaded, dict):
                existing_decisions = loaded
        except (json.JSONDecodeError, OSError):
            pass

    entries = []
    orphaned = 0
    for raw in raw_entries:
        sidecar = load_sidecar(args.sidecars_dir, raw["id"])
        if sidecar is None and not args.include_orphans:
            orphaned += 1
            continue
        entry = build_entry(raw, sidecar, existing_decisions)
        entries.append(entry)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"schema_version": 2, "entries": entries}, indent=2))
    args.output.chmod(0o600)
    args.output.parent.chmod(0o700)
    print(
        f"build-review-queue: wrote {len(entries)} entries; skipped_orphans={orphaned} → {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
