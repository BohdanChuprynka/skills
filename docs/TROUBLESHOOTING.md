# Troubleshooting

Triage by symptom. If a fix doesn't help, run `./doctor.sh` first — it
catches most environment issues automatically.

---

### `dream.sh` exits immediately

**Cause:** typically a missing prerequisite (Python, claude CLI) or a config
file in an unexpected location.

**Fix:**

```bash
./doctor.sh
```

Read the output. Anything `[fail]` is your culprit. Common ones:

- **claude CLI not on PATH.** Install Claude Code, restart your shell, retry.
- **Python < 3.11.** `load_vault_state.py` needs `tomllib`. Upgrade Python.
- **No `config/vault-paths.toml`.** Run `./setup.sh` to create one from the
  shipped example.
- **vault root unreadable.** Check the path in `vault-paths.toml`. Permissions?

---

### Claude reconcile times out

**Cause:** usually an unresponsive MCP. The reconcile pass waits on MCP
initialization at startup; if Notion or Calendar can't reach their servers
(rate limit, expired token, network), the whole call hangs.

**Fix:**

```bash
./dream.sh --no-mcp
```

If that succeeds, you've isolated the issue to an MCP. Then:

```bash
# Identify which MCP
claude --mcp-config ~/.claude/skills/dream-skill/config/mcp-config.json \
       --strict-mcp-config \
       --print "list mcp tools"
```

Watch for which servers fail to register. Common causes:

- **Token expired.** See "Token rotation" below.
- **Wrong scopes.** Re-run the OAuth `auth` step for Google services.
- **Notion integration unshared.** The token works but no pages are accessible —
  the connection list is empty. Open Notion → integration page → confirm pages
  are connected.

---

### Reports are empty / say "nothing to reconcile"

**Cause:** either everything truly is in sync (rare), the time window has no
session activity, or the preprocess filter dropped everything as noise.

**Fix:** inspect what's going in.

```bash
./dream.sh --dry-run --verbose
```

Open `/tmp/dream-sessions-<date>.md`:

- If it's empty: your `--since` window is too short, or `~/.claude/projects/`
  has no matching JSONLs. Try `--since 30d`.
- If it has content but no `★` markers: signal patterns aren't matching your
  actual conversation style. Edit `config/signal-patterns.toml` to add
  entities or anchor phrases relevant to you.

Open `/tmp/dream-vault-<date>.md`:

- If it's empty: `vault_root` in `vault-paths.toml` is wrong, or no `subdirs`
  resolve to real directories. Check paths.

---

### Reports keep flagging the same fact every cycle

**Cause:** a vault page has stale `updated:` frontmatter, or the LLM doesn't
have a strong enough signal to mark the fact as "current and confirmed."

**Fix:** add explicit confirmation frontmatter:

```yaml
---
status: confirmed
updated: 2026-05-13
last_verified: 2026-05-13
---
```

The reconciliation prompt treats `status: confirmed` + recent `last_verified`
as "this is current and intentional; don't re-flag." If you also keep
`updated:` current after a manual review, the LLM gets a much stronger signal.

If a single fact keeps generating contradictions because session content
disagrees with vault content, **the contradiction is real** — update one or
the other. The dream cycle's job is to surface these; it can't resolve them
for you.

---

### MCP errors

Triage in this order:

1. **Is the MCP package reachable?**
   ```bash
   npx -y <package-name> --help
   ```
   If this fails, the issue is network/npm, not the MCP itself.

2. **Are credentials valid?**
   - Notion: visit https://www.notion.so/profile/integrations and confirm
     the integration is active. Regenerate token if needed.
   - Google Calendar/Gmail: re-run the package's `auth` subcommand.

3. **Are credentials at the path the config expects?**
   ```bash
   ls -la ~/.config/dream-skill/   # or wherever your credentials live
   ```

4. **Is `config/mcp-config.json` valid JSON?**
   ```bash
   python3 -m json.tool < ~/.claude/skills/dream-skill/config/mcp-config.json
   ```

Specific MCP issues are covered in detail in
[`MCP-SETUP.md`](MCP-SETUP.md#troubleshooting).

---

### Cron job doesn't run

**Cause:** PATH issue. Cron runs with a minimal environment. `claude` and
`npx` aren't found.

**Fix:** prefix the PATH in the crontab line.

```cron
30 22 * * 0 /bin/bash -lc 'PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ~/.claude/skills/dream-skill/dream.sh >> ~/.claude/skills/dream-skill/dream.log 2>&1'
```

Three things to verify:

- **PATH covers your Node install.** `which npx` from your shell will reveal
  the directory; add it to the PATH prefix.
- **Bash with `-lc`.** The `-l` makes bash source profile files so `nvm`-style
  setups load. If you don't use `nvm`, you can drop `-l`.
- **Log to a file.** `>> dream.log 2>&1` captures stdout+stderr. Inspect the
  log after the first scheduled fire to confirm it ran.

Check the log:

```bash
tail -100 ~/.claude/skills/dream-skill/dream.log
```

If the log is empty, cron isn't firing at all. Check the system cron log
(macOS: Console.app → search for "cron"; Linux: `journalctl -u cron`).

---

### Tokens leaked to git

**Cause:** `config/mcp-config.json` was accidentally committed.

**Fix:**

1. **Revoke the token immediately at the source service.**
   - Notion: https://www.notion.so/profile/integrations → delete the
     integration → recreate.
   - Google: https://myaccount.google.com/permissions → revoke the OAuth app
     → re-do setup.

2. **Remove the file from current and all historical commits.**
   ```bash
   git rm --cached config/mcp-config.json
   echo "config/mcp-config.json" >> .gitignore
   git commit -m "Remove leaked credentials"
   ```

3. **Purge from git history.** Use `git-filter-repo`:
   ```bash
   git filter-repo --invert-paths --path config/mcp-config.json
   ```
   Or `bfg-repo-cleaner` if you prefer. Force-push to overwrite the remote
   (`git push --force`) — note that anyone who already cloned the repo
   still has the secret in their copy.

4. **Audit your other secrets.** A leak here may signal weaker hygiene
   elsewhere. Check for similar mistakes.

The shipped `.gitignore` excludes `config/mcp-config.json` by default. If you
forked and removed that line, add it back.

---

### Vault path with spaces

**Cause:** unquoted shell expansion.

**Fix:**

- In `config/vault-paths.toml`, paths with spaces work as-is (TOML strings
  handle them).
- On the CLI, quote the path:
  ```bash
  ./dream.sh --vault-root "/Users/you/My Vault"
  ```
- In env vars, quote:
  ```bash
  export DREAM_VAULT_ROOT="/Users/you/My Vault"
  ```
- In MCP config (`config/mcp-config.json`), JSON strings handle spaces
  natively — no special escaping needed.

If a vault path is breaking despite quoting, check for non-ASCII characters
or trailing slashes that might confuse path comparison logic.

---

### Token rotation

Periodic — rotate tokens every 90 days as a minimum hygiene practice.

| Service | Rotation steps |
|---|---|
| Notion | Integrations page → regenerate → update `OPENAPI_MCP_HEADERS` in `config/mcp-config.json` |
| Google Calendar | Delete `~/.config/google-calendar-mcp/tokens.json` → re-run `npx @cocal/google-calendar-mcp auth` |
| Gmail | Delete the file at `$GMAIL_CREDENTIALS_PATH` → re-run `npx -y @gongrzhe/server-gmail-autoauth-mcp auth` |
| Filesystem | No token to rotate; just verify allowed dirs are still correct |

After any rotation, confirm:

```bash
chmod 600 ~/.claude/skills/dream-skill/config/mcp-config.json
./doctor.sh
./dream.sh --dry-run --verbose
```

---

### "I see costs higher than expected"

**Cause:** vault snapshot or session preprocessing is producing huge inputs,
or you're running daily on Opus.

**Fix:**

```bash
# Inspect last 10 cycles
jq -s 'sort_by(.ts) | reverse | .[:10] | .[] | {date,model,input_tokens,cost_usd}' \
  ~/.claude/skills/dream-skill/.usage-log.jsonl
```

Look for cycles where `input_tokens` spiked. Then run that day's preview:

```bash
./dream.sh --dry-run --verbose
wc -c /tmp/dream-sessions-*.md /tmp/dream-vault-*.md
```

If `vault.md` is large, check whether new long-form pages should be added to
the `frontmatter_only` glob in `vault-paths.toml`.

If `sessions.md` is large, your `--since` window may include heavy chat
days. The noise filter may also be missing patterns specific to your
workflow — extend `[noise]` in `signal-patterns.toml`.

---

### `dream.sh` works manually but not from cron

**Cause:** environment difference. The shell that runs cron jobs isn't the
shell you use interactively.

**Fix:** reproduce cron's environment.

```bash
env -i /bin/bash -lc 'PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin ~/.claude/skills/dream-skill/dream.sh'
```

`env -i` clears all environment variables, simulating cron. If this fails
where interactive shells succeed, you're depending on a variable cron doesn't
have. Add it to the crontab line or your bash profile (sourced via `-l`).
