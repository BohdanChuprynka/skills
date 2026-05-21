# MCP Setup

calendar-plan-skill talks to four external services via MCP (Model Context Protocol). This document is the per-server setup walkthrough — auth, tokens, scopes, gotchas — and the tier model that explains which servers you actually need.

> All four MCPs are **optional**. The planner degrades gracefully. Configure only what you need. The single load-bearing piece is `--strict-mcp-config`, which is on by default and isolates these servers from your daily Claude Code session.

---

## Tier model

| Tier | What's added | What it gives you |
|------|--------------|-------------------|
| **0** | Nothing — just calendar context + planning preferences via `--add-dir` | Draft-mode planner. Reads the prompt and config, proposes a plan, prints it to stdout. **Cannot write to Google Calendar.** Useful for first-run validation or daily preview. |
| **1** | + **Google Calendar MCP** | Minimum viable cron. The planner can now read existing events across all sub-calendars AND write planning blocks. Every other connector is augmentation. |
| **2** | + **Notion / Gmail / Filesystem** (each independently) | Richer signals. Notion provides the task sequence. Gmail surfaces email-derived obligations. Filesystem lets the planner read/write the Calendar Context page (otherwise it's read-only via `--add-dir`). |

The tiers compose. Tier 2 implies Tier 1. You can adopt them in any order, or mix-and-match within Tier 2 (e.g. Calendar + Notion only, no Gmail).

---

## The recommended path: setup wizard

The cleanest way to wire MCPs is the setup wizard:

```bash
cd ~/.claude/skills/calendar-plan
./setup.sh --mcp
```

The `--mcp` flag re-runs ONLY the MCP step — prompts for each integration and (re)writes `config/mcp-config.json` (chmod 600). Re-run any time you rotate a token.

The file looks like the example at [`config/mcp-config.example.json`](../skills/calendar-plan/config/mcp-config.example.json). Each entry is `{ "command": "npx", "args": [...], "env": { TOKEN: VALUE } }`. The `--strict-mcp-config` flag means **only** servers listed here load when the planner runs.

---

## After any change: verify isolation

After you wire (or rotate) tokens, confirm the isolation is intact:

```bash
# 1. JSON parses
python3 -c "import json; json.load(open('config/mcp-config.json'))"

# 2. File perms are 600
stat -f '%Lp' config/mcp-config.json   # mac
stat -c '%a'  config/mcp-config.json   # linux

# 3. The planner sees the configured servers (one-shot probe)
claude --mcp-config config/mcp-config.json --strict-mcp-config \
  -p "List the MCP tools you have available right now. One bullet per tool. No commentary."
```

The probe should list only tools from servers you configured here — no plugin-installed MCPs, no project `.mcp.json`, no user-global `~/.claude.json` MCPs. If you see extra tools, `--strict-mcp-config` is missing from the invocation.

---

## Tier 1: Google Calendar MCP

**Package:** `@cocal/google-calendar-mcp`

### What it adds to the planner

- Reads existing events across every configured sub-calendar (the planner's existing-event check before writing)
- Writes planning blocks to the correct sub-calendar per `planning-preferences.md` routing
- Re-queries post-write to detect overlaps and stale duplicates

Without this MCP, the planner is read-only. With it, the cron is viable.

### Prerequisites

- A Google account with Calendar enabled.
- A Google Cloud project (free).
- `npx` on `$PATH`.

### Setup

1. **Create a Google Cloud project** at https://console.cloud.google.com — any name.
2. **Enable the Calendar API**: APIs & Services → Library → search "Google Calendar API" → Enable.
3. **Configure the OAuth consent screen**:
   - User type: External (unless you're on a Workspace).
   - App name: anything (e.g. `calendar-plan-mcp`).
   - Add yourself as a Test user.
4. **Create OAuth 2.0 credentials**:
   - APIs & Services → Credentials → Create Credentials → OAuth client ID.
   - Application type: **Desktop app**.
   - Download the JSON → save as `~/.config/gcal-mcp/credentials.json` (chmod 600).
5. **First run triggers OAuth**: a browser tab opens, you consent, and the MCP server caches the resulting token alongside `credentials.json` as `token.json`. Future runs auto-refresh.
6. **Publish the consent screen** (recommended — see next section). Without this, refresh tokens expire every 7 days and you'll re-OAuth weekly.

### Publishing the consent screen (avoid weekly token expiry)

By default the OAuth consent screen sits in **Testing** mode. Refresh tokens issued to Testing-mode apps **expire every 7 days**, which is the root cause of recurring `invalid_grant` errors that force a re-OAuth.

Google Cloud Console → **APIs & Services** → **OAuth consent screen** → **Publishing status** → click **Publish app**. Status flips to *In production*. That's the entire fix — refresh tokens minted afterward last indefinitely under normal use.

**What "In production" does NOT change:**

- **Verification status.** The app is still unverified. Anyone authenticating still sees Google's "Google hasn't verified this app" warning. For solo personal use this is fine and expected.
- **Discoverability.** Publishing does not list the app in any Google directory. The only way someone can authenticate against your app is if they already have your `client_id`. Without the matching `client_secret` they can't start the OAuth flow at all.
- **Scopes.** Whatever scopes the OAuth client requests are still controlled entirely by you. Publishing doesn't broaden access.

**User isolation — what happens if someone else uses your client:**

- Each Google user who completes OAuth gets a token **issued to themselves**, stored on **their machine**. Your account is never exposed to them. Theirs is never exposed to you. There is no shared store.
- Unverified apps are capped at **100 distinct users for sensitive scopes** (Calendar, Gmail). For solo use you will never hit this.
- The `client_secret` for "Desktop / Installed" app type is officially not meaningfully secret per Google's docs — installed apps can't actually keep secrets, since the binary contains them. Treat it as low-sensitivity, not as a password.

**Do not put yourself or others at risk:**

- **Do not** publish `client_id` + `client_secret` + redirect URI together in any public place (gist, README, screenshot, video). That combo lets a phisher craft a convincing consent URL in your app's name and harvest other users' tokens — those tokens authorize *their* Google account, not yours, but you're now the named operator of a phishing front.
- **Do not** apply for Google "App Verification" (the formal review). Verification requires domain ownership, a privacy policy, and a security review. Pointless for a solo personal client, and permanently attaches your real-name app to Google's verified-apps directory.
- **Do not** add other users under *Test users* after publishing. Leave that field empty — the field is meaningless for published apps and adds confusion.
- **Keep scopes minimal.** Calendar read+write is required by this planner. Don't grant Drive, Photos, or other scopes you don't need.

### Where the credentials go

In `config/mcp-config.json`:

```json
"google-calendar": {
  "command": "npx",
  "args": ["-y", "@cocal/google-calendar-mcp"],
  "env": {
    "GOOGLE_OAUTH_CREDENTIALS": "/Users/<you>/.config/gcal-mcp/credentials.json"
  }
}
```

### Required OAuth scopes

The MCP server requests:
- `https://www.googleapis.com/auth/calendar` — read/write all calendars
- `https://www.googleapis.com/auth/calendar.events` — events R/W

Both are required. The planner needs write to create blocks, and broad read to see across sub-calendars.

### Verify

```bash
GOOGLE_OAUTH_CREDENTIALS=~/.config/gcal-mcp/credentials.json \
  npx -y @cocal/google-calendar-mcp
# Expect "Server running" without errors. Ctrl+C to stop.
```

Then test through the planner:

```bash
claude --mcp-config config/mcp-config.json --strict-mcp-config \
  -p "Use the google-calendar MCP to list my calendar IDs and the next 5 events on the primary calendar."
```

### Common gotchas

- **`invalid_grant` on token refresh**: the OAuth client is in "Testing" mode and the refresh token expired after 7 days. **Permanent fix:** [publish the consent screen](#publishing-the-consent-screen-avoid-weekly-token-expiry) — tokens minted afterward don't expire under normal use. **Temporary fix only:** `rm ~/.config/gcal-mcp/token.json && <run the planner once>` (re-OAuths, but you'll hit this again in 7 days if the app is still in Testing mode).
- **`Calendar not found` for a specific sub-calendar**: the calendar ID in `planning-preferences.md` is wrong or the OAuth scope is missing that calendar. Verify by fetching the calendar list above and confirming the ID is present.
- **`Quota exceeded`**: Google Calendar API has generous limits but a runaway test loop can hit them. The planner makes ~5-10 calls per run, so this only happens during development.

---

## Tier 2: Notion MCP

**Package:** `@notionhq/notion-mcp-server`

### What it adds to the planner

- Reads the task-source page (your "12-Week Planner" or equivalent) to get tomorrow's task sequence
- Preserves the page's ordering as intentional sequence data (the planner won't reorder tasks unless calendar constraints demand it)

Without Notion, the planner writes a calendar-only scaffold — wake/school/meals/recovery — and skips the task placement step.

### Prerequisites

- A Notion workspace with a daily/weekly planner page.
- `npx` on `$PATH`.

### Setup

1. **Create an internal integration** at https://www.notion.so/profile/integrations → "New integration" → Type: Internal.
2. Note the **Integration token** (starts with `ntn_`). Treat like a password.
3. **Share your task-source page with the integration**:
   - Open the Notion page (e.g. "12-Week Planner").
   - Click `...` → Connections → Add → select your integration.
   - Repeat for every page or database the planner should read.

> The integration only sees pages you explicitly share with it. Without this step, the MCP can authenticate but will see nothing.

### Where the token goes

In `config/mcp-config.json`:

```json
"notion": {
  "command": "npx",
  "args": ["-y", "@notionhq/notion-mcp-server"],
  "env": {
    "OPENAPI_MCP_HEADERS": "{\"Authorization\":\"Bearer ntn_xxx\",\"Notion-Version\":\"2022-06-28\"}"
  }
}
```

`OPENAPI_MCP_HEADERS` is a JSON string passed as a header — note the escaped quotes.

### Verify

```bash
OPENAPI_MCP_HEADERS='{"Authorization":"Bearer ntn_xxx","Notion-Version":"2022-06-28"}' \
  npx -y @notionhq/notion-mcp-server
```

Then test through the planner:

```bash
claude --mcp-config config/mcp-config.json --strict-mcp-config \
  -p "Use the notion MCP to search for a page titled '12-Week Planner' and return its child blocks."
```

### Common gotchas

- **`object_not_found`** even though the page exists: the integration is not shared with the page. Open the page → ... → Connections → Add → integration name.
- **`Notion-Version` header missing**: some MCP server versions require it explicitly. Always include `"Notion-Version":"2022-06-28"` in the headers JSON.
- **Modern search misses the page**: Notion's search is fuzzy and sometimes lossy. The fallback is the page UUID — add it to `planning-preferences.md` as the prompt instructs: "If modern Notion search cannot find it, fallback Notion page ID `<uuid>`".

---

## Tier 2: Gmail MCP

**Package:** `@gongrzhe/server-gmail-autoauth-mcp`

### What it adds to the planner

- Surfaces recent emails that suggest obligations not yet on the calendar (replies due, deadlines, errands)
- The planner uses these as flags, not as authoritative task sources — Gmail signal augments Notion, doesn't replace it

### Prerequisites

- A Google account with Gmail enabled.
- A Google Cloud project (same one as Calendar is fine).
- `npx` on `$PATH`.

### Setup

1. **Enable the Gmail API** in the same Google Cloud project under APIs & Services → Library.
2. **Create OAuth 2.0 credentials** (Desktop app) — download JSON to `~/.config/gmail-mcp/credentials.json`.
3. **First run** triggers OAuth → token saved to `~/.config/gmail-mcp/token.json` automatically.

### Where the credentials go

```json
"gmail": {
  "command": "npx",
  "args": ["-y", "@gongrzhe/server-gmail-autoauth-mcp"],
  "env": {
    "GMAIL_OAUTH_PATH": "/Users/<you>/.config/gmail-mcp/credentials.json",
    "GMAIL_CREDENTIALS_PATH": "/Users/<you>/.config/gmail-mcp/token.json"
  }
}
```

Two paths, not one — the OAuth client (`credentials.json`) and the refreshable user token (`token.json`) load from different env vars. The OAuth handshake materializes `token.json` on first use.

### Required OAuth scopes

- `https://www.googleapis.com/auth/gmail.readonly` — read-only is sufficient; the planner never sends mail

### Verify

```bash
GMAIL_OAUTH_PATH=~/.config/gmail-mcp/credentials.json \
GMAIL_CREDENTIALS_PATH=~/.config/gmail-mcp/token.json \
  npx -y @gongrzhe/server-gmail-autoauth-mcp
```

Then through the planner:

```bash
claude --mcp-config config/mcp-config.json --strict-mcp-config \
  -p "Use the gmail MCP to search for unread mail from the last 24 hours that might suggest a deadline or reply needed. Return as a bullet list."
```

### Common gotchas

- **OAuth flow stalls on a Mac with the Codex desktop app open**: the Codex app intercepts `localhost:*` callbacks. Quit Codex during the Gmail OAuth handshake, then reopen.
- **Token revoked from Google account dashboard**: delete `~/.config/gmail-mcp/token.json` and re-OAuth.
- **Scope mismatch**: if you originally granted `gmail.readonly` but later need `gmail.modify`, you must delete `token.json` AND re-consent in the OAuth screen — adding a scope doesn't auto-elevate.

---

## Tier 2: Filesystem MCP

**Package:** `@modelcontextprotocol/server-filesystem` (official Anthropic)

### What it adds to the planner

- Read/write access to your Obsidian vault (or any directory) during the run
- Useful if you want the planner to *write* to additional pages (rare; default behavior is read-only). The Calendar Context page is read via `--add-dir` which is enough for most cases.

### Prerequisites

- Just a directory path. No credentials.

### Setup

There's no auth dance — you point it at a directory and it serves files in that directory:

```json
"filesystem-vault": {
  "command": "npx",
  "args": [
    "-y",
    "@modelcontextprotocol/server-filesystem",
    "/Users/<you>/Documents/Obsidian"
  ]
}
```

### Scope decisions

- **Tight (recommended for first run):** the directory containing `Calendar Context.md` only.
- **Wide:** the whole Obsidian vault. Useful if the planner ever needs to cross-reference project pages, gym plans, or other vault content for context.

### Alternative: skip Filesystem MCP, use `--add-dir`

`claude --add-dir <path>` grants the agent read-only access via Claude's built-in Read tool — no MCP needed. The planner can still read the Calendar Context page this way. Default `calendar-plan.sh` does this automatically using the path in `CALENDAR_CONTEXT`.

If you don't need write access from the planner, you don't need this MCP at all.

### Verify

```bash
npx -y @modelcontextprotocol/server-filesystem /Users/<you>/Documents/Obsidian
```

---

## Codex side

Codex's MCP model is different from Claude's. MCPs live in `~/.codex/config.toml` under `[mcp_servers.<name>]` blocks, and the Codex desktop app handles OAuth for hosted MCPs (Notion, Linear, Figma, etc.) via remote URLs.

### Steps

1. Open the Codex desktop app.
2. Settings → MCP Servers → enable each you need:
   - **Notion** (hosted, OAuth via app — produces `[mcp_servers.notion] url = "https://mcp.notion.com/mcp" enabled = true` in config.toml)
   - **Google Calendar** (custom — add via "Add server" with the same `npx -y @cocal/google-calendar-mcp` command + env)
   - **Gmail** (custom — same as Claude side)
   - **Filesystem** (custom — same as Claude side)

### Verify

```bash
codex mcp list
codex mcp test notion       # or whichever name you used
```

### Why two MCP configs

You'd think the two runtimes could share MCP config. They can't:

- Claude's `--strict-mcp-config` reads JSON. Codex reads TOML.
- Claude's tokens isolated per skill via `--mcp-config` + `--strict-mcp-config`. Codex's tokens are global to all Codex skills.
- Codex's hosted integrations (Notion, Linear) use remote URLs + OAuth handshakes that Claude's stdio MCPs don't.

If you're running BOTH targets ad-hoc but only one as cron, this isn't a problem — set up MCPs once on each side, pick one for the schedule.

---

## Manual `mcp-config.json` reference

If you'd rather skip the wizard and hand-edit the file, here's the schema:

```json
{
  "mcpServers": {
    "<server-name>": {
      "command": "npx",
      "args": ["-y", "<package-name>", "<optional positional args>"],
      "env": {
        "<TOKEN_OR_PATH_VAR>": "<value>"
      }
    }
  }
}
```

- `<server-name>` is the key the planner uses internally — keep it stable (`notion`, `google-calendar`, `gmail`, `filesystem-vault`).
- `command` + `args` are how the subprocess is launched. `npx -y` is convention; it auto-installs the package if not cached locally.
- `env` block is per-server. Tokens / credential paths go here.
- File must be valid JSON. `_comment` keys are ignored by Claude's parser but useful for humans.

Permissions: `chmod 600 config/mcp-config.json`. Never commit. The repo's `.gitignore` blocks it by default.

---

## Troubleshooting

### `MCP <name> not responding`

The most common cause is `npx` failing to install the package (network, npm cache lock, registry timeout). Try:

```bash
npx -y <package> --version   # forces fresh install
```

If that hangs, check `~/.npm/_logs/` for the latest log.

### `Token expired` / `401 Unauthorized`

Notion: regenerate the integration token in Notion → Integrations → your integration → Regenerate token. Update `config/mcp-config.json` and re-run `./setup.sh --mcp` or hand-edit.

Google services: delete the relevant `token.json` and re-OAuth on next run:

```bash
rm ~/.config/gcal-mcp/token.json     # or gmail-mcp/token.json
./calendar-plan.sh --dry-run         # triggers re-OAuth
```

### `Scope errors` (Google services)

OAuth scopes are immutable per token. If you change scopes in the OAuth consent screen, you MUST delete the existing `token.json` and re-consent. The MCP server can't elevate scopes silently.

### `npx: command not found` under cron / launchd

cron and launchd run with a minimal `PATH`. Add Node's bin dir to the launchd plist:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>PATH</key>
  <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
</dict>
```

Apple Silicon: `/opt/homebrew/bin`. Intel: `/usr/local/bin`. `nvm`-installed Node: see "Scheduling" in [`INSTALL.md`](INSTALL.md#scheduling).

---

## Token revocation

If you want to fully tear down an integration:

| Service | Revocation |
|---|---|
| **Notion** | Notion → Settings & Members → My Connections → Disconnect the integration. Or delete the integration entirely at https://www.notion.so/profile/integrations. |
| **Google Calendar** | https://myaccount.google.com/permissions → revoke your OAuth app. Then delete `~/.config/gcal-mcp/`. |
| **Gmail** | Same as Calendar — single revocation point at https://myaccount.google.com/permissions. Then delete `~/.config/gmail-mcp/`. |
| **Filesystem** | No tokens. Just remove the entry from `mcp-config.json`. |

After revoking, also delete the entry from `config/mcp-config.json` so the planner stops trying to spawn the MCP subprocess on each run.

---

## Security checklist

Run through this once after setup, and any time you change tokens:

- [ ] `config/mcp-config.json` permissions are `600` (`stat -f '%Lp'`)
- [ ] `config/mcp-config.json` is NOT tracked by git (`git check-ignore -v config/mcp-config.json` should show `.gitignore:...`)
- [ ] OAuth `credentials.json` and `token.json` files are NOT inside the repo (they should live in `~/.config/<svc>-mcp/`)
- [ ] No tokens appear in `logs/` (`grep -r 'ntn_\|ya29\|1//' logs/` should return nothing — tokens never logged)
- [ ] The verify-isolation probe (above) returns ONLY tools from servers configured in this skill, not from your daily Claude Code MCP set
- [ ] Notion integration is shared only with the pages the planner needs
- [ ] Google OAuth client is type **Desktop app**, not Web (Web exposes a redirect URI)
