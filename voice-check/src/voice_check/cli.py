"""voice-check command-line interface.

Single entry point with four subcommands: profile, check, build-skill, eval.
Installed as the `voice-check` console script (see pyproject). The thin wrappers
in scripts/ delegate here so there is one source of truth.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from voice_check import checks, corpus, profile, report, rewrite, skill_template
from voice_check import eval as ev


def _default_profile_dir() -> str:
    """Default profile location: the canonical installed path if it exists,
    otherwise the repo-local data/profiles for in-repo development. A bare
    `voice-check check` run outside the repo would otherwise fail on a missing
    relative data/profiles dir."""
    xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    canonical = Path(xdg) / "voice-check" / "profile"
    return str(canonical) if canonical.exists() else "data/profiles"


def cmd_profile(args) -> int:
    records = corpus.load_corpus(args.input)
    if not records:
        print(f"No supported files (.txt/.md/.jsonl/.csv) found in {args.input}", file=sys.stderr)
        return 2
    prof = profile.build_profile(records)
    profile.write_profile(prof, args.out)
    if not args.quiet:
        print(report.render_profile_summary(prof))
        print(f"Wrote profile_stats.json, voice_rules.json, voice_profile.md to {args.out}")
    return 0


def _read_draft(args) -> str:
    if args.draft:
        return Path(args.draft).read_text(encoding="utf-8", errors="replace")
    if args.text is not None:
        return args.text
    return sys.stdin.read()


def cmd_check(args) -> int:
    profile_dir = Path(args.profile)
    if not (profile_dir / "voice_rules.json").exists():
        print(f"No voice_rules.json in {profile_dir}. Run `voice-check profile` first.", file=sys.stderr)
        return 2
    rules = profile.load_rules(profile_dir)
    text = _read_draft(args)
    if not text.strip():
        print("Empty draft.", file=sys.stderr)
        return 2
    result = checks.check_draft(text, rules)
    if args.rewrite:
        result["suggested_rewrite"] = rewrite.mechanical_polish(text, rules)
    print(report.render_audit(result, fmt=args.format))
    if args.strict and result["score"] < args.min_score:
        return 1
    return 0


def cmd_build_skill(args) -> int:
    profile_dir = Path(args.profile)
    if not (profile_dir / "voice_rules.json").exists():
        print(f"No voice_rules.json in {profile_dir}. Run `voice-check profile` first.", file=sys.stderr)
        return 2
    targets = tuple(t.strip() for t in args.targets.split(",") if t.strip())
    written = skill_template.write_skill(profile_dir, args.out, targets=targets)
    for path in written:
        print(f"Wrote {path}")
    return 0


def cmd_eval(args) -> int:
    summary = ev.evaluate(
        args.input,
        out_report=args.report,
        negatives_dir=args.negatives,
        train_frac=args.train_frac,
        seed=args.seed,
        min_auc=args.min_auc,
        content_matched=args.content_matched,
    )
    print(ev.render_report(summary))
    if args.report:
        print(f"Wrote report to {args.report}")
    return 0 if summary["passed"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="voice-check",
        description="Audit and rewrite drafts in your own voice. Offline, standard-library only.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_profile = sub.add_parser("profile", help="Build a voice profile from a corpus directory.")
    p_profile.add_argument("--input", required=True, help="Directory of .txt/.md/.jsonl/.csv files.")
    p_profile.add_argument("--out", required=True, help="Output directory for profile artifacts.")
    p_profile.add_argument("--quiet", action="store_true")
    p_profile.set_defaults(func=cmd_profile)

    p_check = sub.add_parser("check", help="Audit a draft against your voice profile.")
    p_check.add_argument("--draft", help="Path to a draft file.")
    p_check.add_argument("--text", help="Draft text passed inline.")
    p_check.add_argument("--profile", default=_default_profile_dir(), help="Profile directory.")
    p_check.add_argument("--format", choices=["text", "json"], default="text")
    p_check.add_argument("--rewrite", action="store_true", help="Include the mechanical baseline rewrite.")
    p_check.add_argument("--strict", action="store_true", help="Exit 1 when score < --min-score.")
    p_check.add_argument("--min-score", type=int, default=70, dest="min_score")
    p_check.set_defaults(func=cmd_check)

    p_build = sub.add_parser("build-skill", help="Generate the /voice-check skill from a profile.")
    p_build.add_argument("--profile", default=_default_profile_dir())
    p_build.add_argument("--out", default="skills/voice-check")
    p_build.add_argument("--targets", default="claude,codex", help="Comma list: claude,codex.")
    p_build.set_defaults(func=cmd_build_skill)

    p_eval = sub.add_parser("eval", help="Prove discrimination + rewrite demo (aggregate metrics only).")
    p_eval.add_argument("--input", required=True)
    p_eval.add_argument("--negatives")
    p_eval.add_argument("--report")
    p_eval.add_argument("--train-frac", type=float, default=0.6, dest="train_frac")
    p_eval.add_argument("--seed", type=int, default=7)
    p_eval.add_argument("--min-auc", type=float, default=0.85, dest="min_auc")
    p_eval.add_argument("--content-matched", action="store_true", dest="content_matched")
    p_eval.set_defaults(func=cmd_eval)

    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
