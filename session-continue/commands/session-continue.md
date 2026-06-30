---
description: Continue a continues-supported session by transcript ID in the current Claude Code thread; source is optional and normally auto-detected.
allowed-tools: Bash
---

Run the bundled helper with the provided arguments, read its output as the
handoff context, then continue the user's work in this same Claude Code thread.

Default to ID-only usage. With just a session ID, the helper locates the
transcript across configured Claude account dirs and the Codex sessions dir,
then resolves it automatically. Treat `from <source>` as an escape hatch only
when the user intentionally pins a provider.

```bash
node "$HOME/.claude/skills/session-continue/scripts/session-continue.mjs" "$ARGUMENTS"
```

Do not launch a separate Codex or Claude process unless the user explicitly asks.
