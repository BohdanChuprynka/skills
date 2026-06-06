"""Render audit results and profiles to text / markdown / json. No dependencies."""

from __future__ import annotations

import json

_SEVERITY_ORDER = {"hard": 0, "soft": 1, "info": 2}
_SEVERITY_LABEL = {"hard": "HARD", "soft": "soft", "info": "info"}


def _score_bar(score: int, width: int = 20) -> str:
    filled = round(score / 100 * width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def render_audit(result: dict, fmt: str = "text") -> str:
    if fmt == "json":
        return json.dumps(result, ensure_ascii=False, indent=2)

    lines: list[str] = []
    score = result["score"]
    lines.append(f"Voice-check audit  ({result.get('kind_assumed', 'unknown')})")
    lines.append(f"Score: {score}/100  {_score_bar(score)}")
    lines.append("")

    violations = sorted(
        result.get("violations", []),
        key=lambda v: (_SEVERITY_ORDER.get(v["severity"], 9), -v["penalty"]),
    )
    lines.append(f"VIOLATIONS ({len(violations)})")
    if not violations:
        lines.append("  none — this reads in your voice.")
    for v in violations:
        tag = _SEVERITY_LABEL.get(v["severity"], v["severity"])
        lines.append(f"  [{tag}] {v['message']}  (-{v['penalty']})")
        if v.get("fix"):
            lines.append(f"        fix: {v['fix']}")
    lines.append("")

    matches = result.get("voice_matches", [])
    if matches:
        lines.append("VOICE MATCHES")
        for m in matches:
            lines.append(f"  + {m['trait']}: {m['detail']}")
        lines.append("")

    plan = result.get("rewrite_plan", [])
    if plan:
        lines.append("REWRITE PLAN")
        for i, step in enumerate(plan, 1):
            lines.append(f"  {i}. {step}")
        lines.append("")

    if result.get("suggested_rewrite"):
        lines.append("SUGGESTED REWRITE (mechanical baseline)")
        lines.append(f"  {result['suggested_rewrite']}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_profile_summary(profile: dict) -> str:
    overall = profile["overall"]
    wt = profile["written_target"]
    band = wt["sentence_len_band"]
    lines = [
        "Voice profile summary",
        f"  Corpus: {overall['n_words']} words, {overall['n_sentences']} sentences",
        f"  Written target from: {wt['derived_from']}",
        f"  Sentence length: ~{wt['sentence_len_mean']} words (band {band[0]}-{band[1]})",
        f"  Em dashes: {'allowed' if wt['em_dash_allowed'] else 'avoid'}",
        f"  Contraction target: {wt['contraction_rate_per_1k_target']} per 1k words",
        f"  Vocab anchors: {', '.join(wt['vocab_anchors'][:12]) or '(n/a)'}",
    ]
    return "\n".join(lines) + "\n"
