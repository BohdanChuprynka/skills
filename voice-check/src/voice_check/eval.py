"""Evaluation harness: prove the profile discriminates the user's writing from
generic-AI text, and demo that mechanical rewriting moves drafts toward the
profile.

The written report carries aggregate numbers only — scores, AUC, means, deltas —
never the underlying texts, so it stays privacy-safe even when negatives are
content-matched paraphrases of the user's own writing.
"""

from __future__ import annotations

import hashlib
import re
import statistics
from pathlib import Path
from typing import Optional

from voice_check import checks, lexicons, profile as profile_mod, rewrite
from voice_check.corpus import EDITED, POLISHED, RAW_SPEECH, load_corpus

# eval.py lives at <pkg-root>/src/voice_check/eval.py, so the packaged examples/
# dir is parents[2] (the package root), NOT parents[1] (the src/ dir).
_DEFAULT_NEGATIVES = Path(__file__).resolve().parents[2] / "examples" / "contrast"

# Inverse of mechanical_polish, used ONLY to build content-matched negatives:
# degrade a clean sentence into generic-AI style (same content, AI styling).
_INVERSE_CONTRACTION: dict[str, str] = {}
for _expanded, _contraction in lexicons.EXPAND_TO_CONTRACTION.items():
    _INVERSE_CONTRACTION.setdefault(_contraction, _expanded)

_PLAIN_TO_CORPORATE = {
    "use": "utilize",
    "help": "facilitate",
    "start": "commence",
    "show": "demonstrate",
    "more": "additional",
    "many": "numerous",
    "before": "prior to",
    "try": "endeavor",
    "improve": "optimize",
}


def _swap_words(text: str, mapping: dict) -> str:
    if not mapping:
        return text
    keys = sorted(mapping, key=len, reverse=True)
    pattern = re.compile(r"\b(" + "|".join(re.escape(k) for k in keys) + r")\b", re.IGNORECASE)
    return pattern.sub(lambda m: mapping.get(m.group(0).lower(), m.group(0)), text)


def ai_ify(text: str) -> str:
    """Style-transfer a clean sentence into generic-AI prose without changing the
    underlying content: expand contractions, swap plain words for corporate ones,
    add an em dash, and prepend an AI connector."""
    out = _swap_words(text, _INVERSE_CONTRACTION)
    out = _swap_words(out, _PLAIN_TO_CORPORATE)
    if ", " in out:
        out = out.replace(", ", " — ", 1)
    elif ". " in out:
        out = out.replace(". ", " — ", 1)
    out = "Furthermore, " + (out[:1].lower() + out[1:] if out else out)
    return out


def roc_auc(pos: list[float], neg: list[float]) -> float:
    """Area under the ROC curve via the Mann-Whitney U statistic."""
    if not pos or not neg:
        return 0.5
    wins = 0.0
    for p in pos:
        for n in neg:
            if p > n:
                wins += 1.0
            elif p == n:
                wins += 0.5
    return round(wins / (len(pos) * len(neg)), 4)


def accuracy_at_best_threshold(pos: list[float], neg: list[float]) -> tuple[float, float]:
    """Best single-threshold classification accuracy (positive if score >= thr)."""
    if not pos or not neg:
        return 0.0, 0.0
    candidates = set()
    for s in pos + neg:
        candidates.add(s)
        candidates.add(s + 0.5)
    total = len(pos) + len(neg)
    best_acc, best_thr = 0.0, 0.0
    for thr in sorted(candidates):
        tp = sum(1 for p in pos if p >= thr)
        tn = sum(1 for n in neg if n < thr)
        acc = (tp + tn) / total
        if acc > best_acc:
            best_acc, best_thr = acc, thr
    return round(best_acc, 4), best_thr


def deterministic_split(items: list, train_frac: float, seed: int) -> tuple[list, list]:
    """Seeded, reproducible split into (train, test). test is never empty (n>=2)."""
    n = len(items)
    if n == 0:
        return [], []
    order = sorted(range(n), key=lambda i: hashlib.sha1(f"{seed}:{i}".encode()).hexdigest())
    k = int(round(n * train_frac))
    k = max(1, min(k, n - 1)) if n >= 2 else n
    train_idx = set(order[:k])
    train = [items[i] for i in range(n) if i in train_idx]
    test = [items[i] for i in range(n) if i not in train_idx]
    return train, test


def _signal_subset(sig: dict) -> dict:
    return {
        "filler_rate_per_1k": sig.get("filler_rate_per_1k", 0.0),
        "em_dash": sig.get("em_dash", 0),
        "corporate": len(sig.get("corporate", [])),
        "ai_tells": len(sig.get("ai_tells", [])),
        "sentence_len_mean": sig.get("sentence_len_mean", 0.0),
    }


def run_discrimination(positives: list[str], negatives: list[str], rules: dict) -> dict:
    pos_scores = [checks.check_draft(t, rules)["score"] for t in positives]
    neg_scores = [checks.check_draft(t, rules)["score"] for t in negatives]
    acc, thr = accuracy_at_best_threshold(pos_scores, neg_scores)
    mean_pos = round(statistics.fmean(pos_scores), 2) if pos_scores else 0.0
    mean_neg = round(statistics.fmean(neg_scores), 2) if neg_scores else 0.0
    return {
        "n_pos": len(pos_scores),
        "n_neg": len(neg_scores),
        "auc": roc_auc(pos_scores, neg_scores),
        "accuracy": acc,
        "threshold": thr,
        "mean_pos": mean_pos,
        "mean_neg": mean_neg,
        "score_gap": round(mean_pos - mean_neg, 2),
        "min_pos": min(pos_scores) if pos_scores else 0,
        "max_neg": max(neg_scores) if neg_scores else 0,
    }


def run_rewrite_demo(drafts: list[str], rules: dict) -> list[dict]:
    out = []
    for draft in drafts:
        before = checks.check_draft(draft, rules)
        polished = rewrite.mechanical_polish(draft, rules)
        after = checks.check_draft(polished, rules)
        out.append(
            {
                "before_score": before["score"],
                "after_score": after["score"],
                "delta": after["score"] - before["score"],
                "before_signals": _signal_subset(before["signals"]),
                "after_signals": _signal_subset(after["signals"]),
            }
        )
    return out


def _positive_records(records):
    writing = [r for r in records if r.kind in (POLISHED, EDITED)]
    if writing:
        return writing, "writing"
    speech = [r for r in records if r.kind == RAW_SPEECH]
    if speech:
        return speech, "speech"
    return records, "all"


def evaluate(
    input_dir,
    out_report=None,
    negatives_dir: Optional[Path] = None,
    train_frac: float = 0.6,
    seed: int = 7,
    min_auc: float = 0.85,
    content_matched: bool = False,
) -> dict:
    records = load_corpus(input_dir)
    positives, positive_source = _positive_records(records)
    train_recs, test_recs = deterministic_split(positives, train_frac, seed)

    rules = profile_mod.to_voice_rules(profile_mod.build_profile(train_recs or positives))

    test_texts = [r.text for r in test_recs]
    if content_matched:
        negatives = [ai_ify(t) for t in test_texts]
        negative_mode = "content_matched_ai_paraphrase"
    else:
        neg_dir = Path(negatives_dir) if negatives_dir else _DEFAULT_NEGATIVES
        negatives = [r.text for r in load_corpus(neg_dir)]
        if not negatives:
            # Loudly refuse rather than silently returning AUC 0.5 from an empty set.
            raise FileNotFoundError(
                f"no negative records loaded from {neg_dir} — eval cannot discriminate. "
                "Pass --negatives <dir> with records, or use --content-matched."
            )
        negative_mode = "independent_generic_ai"

    discrimination = run_discrimination(test_texts, negatives, rules)
    rewrite_demo = run_rewrite_demo(negatives[:6], rules)

    summary = {
        "positive_source": positive_source,
        "negative_mode": negative_mode,
        "n_train": len(train_recs),
        "n_test": len(test_recs),
        "min_auc": min_auc,
        "passed": discrimination["auc"] >= min_auc,
        "discrimination": discrimination,
        "rewrite_demo": rewrite_demo,
    }

    if out_report:
        Path(out_report).write_text(render_report(summary), encoding="utf-8")
    return summary


def render_report(summary: dict) -> str:
    d = summary["discrimination"]
    demo = summary["rewrite_demo"]
    before = statistics.fmean(x["before_score"] for x in demo) if demo else 0.0
    after = statistics.fmean(x["after_score"] for x in demo) if demo else 0.0
    lines = [
        "# Voice-check evaluation",
        "",
        "_Aggregate metrics only. No corpus or draft text is included._",
        "",
        "## Discrimination (held-out)",
        f"- Positive source: {summary['positive_source']} "
        f"(train {summary['n_train']}, held-out test {summary['n_test']})",
        f"- Negatives: {summary.get('negative_mode', 'independent_generic_ai')}",
        f"- **ROC-AUC: {d['auc']}** (target ≥ {summary['min_auc']}) — "
        f"{'PASS' if summary['passed'] else 'below target'}",
        f"- Accuracy at best threshold: {d['accuracy']} (threshold {d['threshold']})",
        f"- Mean score — your writing: {d['mean_pos']}, generic-AI: {d['mean_neg']} "
        f"(gap {d['score_gap']})",
        f"- Range — held-out min(you): {d['min_pos']}, max(AI): {d['max_neg']}",
        f"- n positives: {d['n_pos']}, n negatives: {d['n_neg']}",
        "",
        "## Rewrite demo (mechanical baseline on generic-AI drafts)",
        f"- Mean score before: {round(before, 1)} → after: {round(after, 1)}",
        f"- Drafts improved: {sum(1 for x in demo if x['delta'] > 0)}/{len(demo)}",
        "",
    ]
    return "\n".join(lines)
