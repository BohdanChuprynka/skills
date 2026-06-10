---
description: Import a continues-supported session by source and session id, then continue in the current Claude Code thread.
allowed-tools: Bash
---

Run the bundled helper with the provided arguments, read its output as the handoff context, then continue the user's work in this same Claude Code thread.

```bash
node "$HOME/.claude/skills/session-continue/scripts/session-continue.mjs" "$ARGUMENTS"
```

Do not launch a separate Codex or Claude process unless the user explicitly asks.
