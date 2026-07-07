# routing-mode

**A Claude Code skill that cuts coding costs by routing *planning* to Claude and *code execution* to the [Codex CLI](https://github.com/openai/codex) (`gpt-5.5`).**

Planning is reasoning-heavy but token-light. Writing code is token-heavy — and output tokens are the expensive ones. So use the strong model where it matters (design, review) and a cheaper model for the volume (typing the code). `routing-mode` automates that split inside a single Claude Code session — no more copy-pasting between two chats.

> Concept credit: the planning-vs-execution routing idea is from Matthew Berman's video *["Cut your AI cost IN HALF"](https://www.youtube.com/watch?v=1KKB_UiW6ls)*. This skill turns it into a one-command, reviewed, git-safe workflow.

---

## How it works

```
Claude (this session)                         Codex CLI (gpt-5.5)
─────────────────────                         ───────────────────
1. Plan          → writing-plans → plan.md
2. Review        → zero-context subagent audits the plan   (never blind-execute)
3. Delegate ─────────────────────────────────────────────► implements the plan
4. Verify        ◄── diff ── reviews Codex's changes, runs tests
5. Hand back     → you commit
```

- **Plan** with the current session model (e.g. Opus 4.8), using the `superpowers:writing-plans` skill.
- **Gate**: a fresh subagent with *zero conversation context* reviews the plan for gaps and bias before any code is written.
- **Execute** by handing the reviewed plan to `codex exec -m gpt-5.5` at `high` effort.
- **Verify** the resulting diff on the strong model, then you commit. The skill never commits for you.

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated — see [`docs/installing-codex-cli.md`](docs/installing-codex-cli.md)
- `git` (routing-mode only runs inside a git repo, so Codex's changes stay reviewable)

## Install

**As a plugin (recommended)** — from the [`BohdanChuprynka/skills`](https://github.com/BohdanChuprynka/skills) marketplace, inside Claude Code:

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

Full steps (verifying, per-project rules): [`docs/installing-the-skill.md`](docs/installing-the-skill.md).

## Usage

Inside a git repo, just describe the work:

> "Add rate limiting to the API client."

The skill triggers automatically for nontrivial coding tasks, or force it with `/routing-mode`. It plans, gets the plan reviewed, delegates the code to Codex, shows you the diff, and hands back for you to commit.

## ⚠️ Safety

The **default sandbox is `danger-full-access`** — Codex runs arbitrary shell with no sandbox (network, installs, deletes). Two rails contain this:

1. The helper **refuses to run unless the git working tree is clean**, so every change Codex makes is a reviewable, revertable diff.
2. **Claude reviews the diff** before you commit — nothing is auto-committed.

To reduce blast radius, set `ROUTING_SANDBOX=workspace-write` (file edits + sandboxed commands, no network). See [`docs/configuration.md`](docs/configuration.md).

## Configuration

| Knob | Default | Override |
|---|---|---|
| model | `gpt-5.5` | `ROUTING_MODEL` env / `-m` |
| effort | `high` | `ROUTING_EFFORT` env / `--effort` |
| sandbox | `danger-full-access` | `ROUTING_SANDBOX` env / `-s` |
| dirty tree | refuse | `--allow-dirty` |

Details: [`docs/configuration.md`](docs/configuration.md).

## Uninstall

```bash
rm ~/.claude/skills/routing-mode
```

## License

MIT © 2026 Bohdan Chuprynka — see [LICENSE](LICENSE).
