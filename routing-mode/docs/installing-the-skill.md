# Installing the routing-mode skill

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- Codex CLI installed and authenticated — see [`installing-codex-cli.md`](installing-codex-cli.md)

## Install

`routing-mode` ships as a plugin in the [`BohdanChuprynka/skills`](https://github.com/BohdanChuprynka/skills) marketplace.

**As a plugin (recommended)** — inside Claude Code:

```
/plugin marketplace add BohdanChuprynka/skills
/plugin install routing-mode@skills
```

**Or manually** — clone the monorepo and symlink the nested skill directory:

```bash
git clone https://github.com/BohdanChuprynka/skills.git
cd skills
ln -s "$PWD/routing-mode/skills/routing-mode" ~/.claude/skills/routing-mode
```

Claude Code loads any `~/.claude/skills/<name>/SKILL.md`; the symlink points at the plugin's `skills/routing-mode/` directory.

## Verify

Start (or restart) Claude Code. In a git-backed project, ask for a real coding task ("implement …") or type `/routing-mode`. The skill should announce itself and begin the plan → review → delegate flow.

Quick sanity check that the helper is reachable:

```bash
bash ~/.claude/skills/routing-mode/scripts/route-to-codex.sh --help
```

## Per-project standing rules (DRY)

`routing-mode` does **not** embed your coding standards. Keep them in each project once:

- `AGENTS.md` — read by Codex during execution.
- `CLAUDE.md` — read by Claude during planning and review.

Point both at one file if you like (`AGENTS.md` → symlink to `CLAUDE.md`) so planner, reviewer, and executor share a single source of truth with nothing rewritten per project.

## Update

```bash
cd ~/.claude/skills/routing-mode    # (symlink install) or your clone
git pull
```

## Uninstall

```bash
rm ~/.claude/skills/routing-mode    # removes the symlink/copy; your clone stays
```
