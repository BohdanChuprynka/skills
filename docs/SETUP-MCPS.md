# MCP setup walkthroughs

One-time setup for each MCP server the calendar-plan skill uses. After this, `setup.sh` collects the resulting paths/tokens and writes them into `config/mcp-config.json` (chmod 600).

> **All four MCPs are optional.** The skill degrades gracefully — the prompt tells the planner to continue with available sources and pause when a missing source could materially change the day. Configure only what you actually need.

| MCP | Required for | Setup difficulty |
|---|---|---|
| Google Calendar | Reading + writing calendar blocks | **Required**. Without it, nothing happens. |
| Notion | Reading the task-source page | Optional but recommended |
| Gmail | Surfacing email-derived obligations | Optional |
| Filesystem (vault) | Reading the Calendar Context markdown | Optional (skill can also use `--add-dir`) |

---

## 1. Google Calendar MCP

Package: `@cocal/google-calendar-mcp`

### Steps

1. **Create a Google Cloud project** at https://console.cloud.google.com — any name.
2. **Enable the Calendar API**: APIs & Services → Library → search "Google Calendar API" → Enable.
3. **Create OAuth 2.0 credentials**:
   - APIs & Services → Credentials → Create Credentials → OAuth client ID
   - Application type: **Desktop app**
   - Download the JSON → save to `~/.config/gcal-mcp/credentials.json`
4. **Add the calendar scope** to the OAuth consent screen (Test users tab, add your Gmail).
5. **First run will trigger an OAuth consent flow in your browser.** The MCP server caches the resulting token next to `credentials.json`.

### What to put in `setup.sh`

```
Absolute path to Google Calendar OAuth credentials.json:
  /Users/<you>/.config/gcal-mcp/credentials.json
```

### Verify

```bash
npx -y @cocal/google-calendar-mcp
# Should print "Server running" without errors. Ctrl+C to stop.
```

---

## 2. Notion MCP

Package: `@notionhq/notion-mcp-server`

### Steps

1. **Create an internal integration** at https://www.notion.so/profile/integrations → New integration → "Internal".
2. Note the **Integration token** (starts with `ntn_`). Treat like a password.
3. **Share your task-source page with the integration**:
   - Open the Notion page (e.g. "12-Week Planner")
   - Click `...` → Connections → Add → select your integration
   - Repeat for every page or database the planner should read

> The integration only sees pages you explicitly share with it. Without this step, the MCP can authenticate but will see nothing.

### What to put in `setup.sh`

```
Notion integration token (ntn_...):
  ntn_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Verify

```bash
OPENAPI_MCP_HEADERS='{"Authorization":"Bearer ntn_xxx","Notion-Version":"2022-06-28"}' \
  npx -y @notionhq/notion-mcp-server
```

---

## 3. Gmail MCP

Package: `@gongrzhe/server-gmail-autoauth-mcp`

### Steps

1. **Create OAuth credentials** in the same Google Cloud project you used for Calendar (or a new one).
2. **Enable the Gmail API** under APIs & Services → Library.
3. **OAuth client type**: Desktop app. Download JSON → save to `~/.config/gmail-mcp/credentials.json`.
4. **First run** triggers OAuth flow → token is saved to `~/.config/gmail-mcp/token.json`.

### What to put in `setup.sh`

```
Absolute path to Gmail OAuth credentials.json:
  /Users/<you>/.config/gmail-mcp/credentials.json
Absolute path to Gmail token.json:
  /Users/<you>/.config/gmail-mcp/token.json
```

### Why the token.json path is separate

The Gmail MCP loads `credentials.json` (OAuth client) and `token.json` (refreshable user token) from different env vars. The OAuth handshake materializes `token.json` on first use. After that, future runs auto-refresh without browser prompts.

### Verify

```bash
GMAIL_OAUTH_PATH=~/.config/gmail-mcp/credentials.json \
GMAIL_CREDENTIALS_PATH=~/.config/gmail-mcp/token.json \
  npx -y @gongrzhe/server-gmail-autoauth-mcp
```

---

## 4. Filesystem MCP (Obsidian vault)

Package: `@modelcontextprotocol/server-filesystem`

### Steps

1. **Identify the path** you want the agent to see. For Obsidian, this is your vault root.
2. **Decide scope**:
   - **Tight (recommended for first run):** the directory containing `Calendar Context.md` only.
   - **Wide:** the whole Obsidian vault — useful if the planner ever needs to cross-reference project pages or gym plans.
3. The MCP server is configured purely by command-line args — no separate credentials.

### What to put in `setup.sh`

```
Absolute path to Obsidian vault root (for filesystem MCP):
  /Users/<you>/Documents/.../Obsidian
```

### Verify

```bash
npx -y @modelcontextprotocol/server-filesystem /Users/<you>/Documents/.../Obsidian
```

### Alternative: skip the filesystem MCP

If you don't want the agent to have file-write access at all, set the `EXTRA_ADD_DIRS` field in `settings.conf` to the Obsidian path. `claude --add-dir <path>` grants read-only access via Claude's built-in Read tool — no MCP needed. The planner will still be able to read Calendar Context this way.

---

## Codex side

Codex's MCP model is different — MCPs live in `~/.codex/config.toml` as `[mcp_servers.<name>]` blocks, and the Codex desktop app handles OAuth for hosted MCPs (Notion, Linear, Figma, etc.) via remote URLs.

### Steps

1. Open Codex desktop app.
2. Settings → MCP Servers → enable each of the four:
   - Notion (toggles `enabled = true` in config.toml; uses OAuth)
   - Google Calendar (custom MCP — add via "Add server")
   - Gmail (custom MCP — add via "Add server")
   - Filesystem (custom MCP — add via "Add server")

> Codex's hosted Notion/Linear/Figma integrations use remote URLs like `https://mcp.notion.com/mcp` and the desktop app's OAuth flow. For Calendar/Gmail/Filesystem you'll add local stdio entries the same way the Claude side does (npx commands with env tokens).

### Verify

```bash
codex mcp list
codex mcp test notion       # or whichever name you used
```

---

## Token rotation

If a token leaks or you want to rotate:

1. **Notion**: regenerate the integration token in Notion settings → re-run `claude/setup.sh` (step 4 only) or edit `mcp-config.json` directly.
2. **Gmail/GCal**: delete `~/.config/gmail-mcp/token.json` (or `gcal-mcp/token.json`) → the next run re-prompts OAuth.
3. **Codex**: revoke OAuth in the relevant service → reconnect via the Codex desktop app.

No daemon restart needed for the Claude target — every `calendar-plan.sh` invocation spawns fresh MCP subprocesses.
