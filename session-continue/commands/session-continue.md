---
description: Continue a continues-supported session by session id (source optional, auto-detected across Claude accounts + Codex) in the current Claude Code thread.
allowed-tools: Bash
---

Run the bundled helper with the provided arguments, read its output as the handoff context, then continue the user's work in this same Claude Code thread. The source tool is optional: with just a session id, the helper locates the transcript across the configured Claude account dirs and the Codex sessions dir and resolves it automatically.

```bash
node "$HOME/.claude/skills/session-continue/scripts/session-continue.mjs" "$ARGUMENTS"
```

Do not launch a separate Codex or Claude process unless the user explicitly asks.
