# Configuration

Every knob has a safe default. Override with an environment variable (set it before the Claude session, or in your shell profile) or a flag on `scripts/route-to-codex.sh` — the flag wins.

## Sandbox — how much Codex can do

| Mode | Codex can… | Blocked | Use when |
|---|---|---|---|
| `read-only` | read files, propose a diff | any write, any command | you want to apply changes yourself |
| `workspace-write` | edit files + run sandboxed commands (tests, build) | **network**, writes outside the repo | the safer everyday default |
| `danger-full-access` | run **arbitrary** shell — network, installs, deletes | nothing | you accept full autonomy (this skill's default) |

```bash
export ROUTING_SANDBOX=workspace-write     # tighten globally
# or per call:
bash scripts/route-to-codex.sh plan.md -s workspace-write
```

> The default is `danger-full-access`. The rail is that the helper refuses to run on a dirty tree, so every change is a reviewable, revertable diff — and Claude reviews it before you commit. If you don't need network/installs during execution, `workspace-write` is strictly safer with little downside.

## Model

```bash
export ROUTING_MODEL=gpt-5.5     # default; alternatives: gpt-5.4, gpt-5.4-mini, …
bash scripts/route-to-codex.sh plan.md -m gpt-5.4
```

Whatever your account exposes to `codex exec -m <id>` is valid. Execution from a reviewed plan does not need a frontier model — that's the whole point of routing.

## Effort

```bash
export ROUTING_EFFORT=high       # low | medium | high | xhigh (default: high)
bash scripts/route-to-codex.sh plan.md --effort medium
```

Executing a spec doesn't need max reasoning; `high` (or lower) is usually the right cost/quality point. Raise to `xhigh` only for genuinely hard implementations.

## Dirty working tree

The helper refuses to run if `git status` is not clean, so the diff is only Codex's work. Override (not recommended):

```bash
bash scripts/route-to-codex.sh plan.md --allow-dirty
```

## Relationship to your global Codex config

`~/.codex/config.toml` sets Codex's *interactive* defaults. `routing-mode` passes `-m`, `--effort`, and `-s` on every call, so it runs independently of those defaults and won't change them.
