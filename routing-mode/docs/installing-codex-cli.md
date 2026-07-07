# Installing the Codex CLI

`routing-mode` delegates code execution to OpenAI's [Codex CLI](https://github.com/openai/codex). Install and authenticate it once.

## 1. Prerequisites

- **Node.js 18+** (`node --version`). If you use `nvm`, activate a recent version first.

## 2. Install

```bash
npm install -g @openai/codex
```

Verify:

```bash
codex --version        # e.g. codex-cli 0.142.5
```

## 3. Authenticate

`routing-mode` calls Codex **non-interactively** (`codex exec`), so credentials must already be stored — pick one:

**Option A — sign in with ChatGPT (recommended if you have a plan):**

```bash
codex login
```

This stores credentials in `~/.codex/auth.json`; no environment variable needed afterward.

**Option B — API key:**

```bash
export OPENAI_API_KEY="sk-..."      # add to your shell profile to persist
```

Verify auth with a safe, read-only smoke test:

```bash
codex exec -s read-only "Print the word: ready"
```

If that prints a reply, Codex is authenticated and non-interactive execution works.

## 4. Confirm model access

`routing-mode` uses `gpt-5.5` by default. Make sure your account can use it:

```bash
codex exec -m gpt-5.5 -s read-only "Print the word: ok"
```

If `gpt-5.5` is unavailable, set a model you do have (e.g. `export ROUTING_MODEL=gpt-5.4`) — see [`configuration.md`](configuration.md).

## Maintenance

```bash
codex doctor                          # diagnose install / auth / runtime
codex update                          # or: npm install -g @openai/codex@latest
```

## Notes

- Your global Codex defaults live in `~/.codex/config.toml`. `routing-mode` overrides model, effort, and sandbox **per call**, so it does not depend on (or disturb) those defaults.
- Standing project conventions belong in each project's `AGENTS.md` — Codex reads it automatically. `routing-mode` does not duplicate them.
