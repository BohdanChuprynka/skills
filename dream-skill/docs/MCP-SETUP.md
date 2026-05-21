# MCP Setup

dream-skill is **fully functional with zero MCPs**. Everything in this document
is opt-in. Add an integration only when you want that signal stream in your
reconciliation cycles.

All MCPs run as **local stdio servers via `npx`**, with credentials in a single
config file (`config/mcp-config.json`). When `dream.sh` invokes Claude, it
passes `--strict-mcp-config` — meaning **only** the servers in that file load,
and only for the duration of the dream cycle. Your daily Claude sessions are
unaffected.

---

## Tier model

| Tier | What's added | What it gives you |
|------|--------------|-------------------|
| **0** | Nothing — just sessions + vault snapshot | Stale-fact detection, missing-fact flags, contradictions visible in chat history |
| **1** | + Filesystem MCP | LLM can read individual vault pages on demand during reconcile, and write the report directly (instead of stdout capture) |
| **2** | + Notion / Calendar / Gmail (each independently) | External-world signals: schedule changes, comms with key people, async notes from other tools |

The tiers compose. Tier 2 implies Tier 1. You can adopt them in any order, or
mix-and-match within Tier 2 (e.g., Filesystem + Notion only, no Google).

---

## The recommended path: setup wizard

```bash
cd ~/.claude/skills/dream-skill
./setup.sh --mcp
```

The wizard asks one question per MCP, runs the OAuth dance where needed, and
writes `config/mcp-config.json` for you. **You can stop at any point** — partial
configs are valid; only the MCPs you finish setting up will be active.

The rest of this document is for users who skip the wizard, want to understand
what it's doing, or are debugging a setup that went sideways.

---

## After any change: verify isolation

After editing `config/mcp-config.json`, always confirm:

1. **Only the intended MCPs load for dream cycles:**

   ```bash
   claude --mcp-config ~/.claude/skills/dream-skill/config/mcp-config.json \
          --strict-mcp-config \
          --print "list mcp tools you have access to (names only)"
   ```

   The output should list exactly the servers in your config — nothing else.

2. **Your daily Claude session is untouched:**

   ```bash
   claude mcp list
   ```

   This should NOT include any dream-skill MCPs. They only activate when
   `dream.sh` runs.

3. **Lock down the config file:**

   ```bash
   chmod 600 ~/.claude/skills/dream-skill/config/mcp-config.json
   ```

   The file contains tokens. Owner-read-only is the right default. Also confirm
   it's gitignored (it is, in the shipped `.gitignore`, but verify if you fork).

---

## Tier 1: Filesystem MCP

**Package:** `@modelcontextprotocol/server-filesystem` (official Anthropic).

### What it adds to the dream cycle

Lets the LLM (a) write the dream report directly into your vault inbox using
the MCP's `write_file` tool instead of stdout capture, and (b) read individual
vault pages on demand during reconciliation — so if the snapshot summary
flagged a stale page, the LLM can pull the full content and reason about
specifics rather than the summary line.

### Prerequisites

- An Obsidian vault (or any markdown directory) on disk
- Decide on an "inbox" directory inside your vault where reports will land
  (e.g., `<vault-root>/dream-reports/` — that's the default)

### Setup

No OAuth, no account, no token. Just paths.

`config/mcp-config.json`:

```json
"filesystem": {
  "command": "npx",
  "args": [
    "-y",
    "@modelcontextprotocol/server-filesystem",
    "${VAULT_INBOX_PATH}"
  ]
}
```

Replace `${VAULT_INBOX_PATH}` with the absolute path to your dream-reports
directory (e.g., `/Users/you/Documents/Obsidian/dream-reports`).

**Important security note.** Every positional argument after the package name
is an allowed directory. The MCP enforces the sandbox with `realpath`
resolution, so symlinks can't escape — but inside the listed dirs, the LLM has
**full read+write** access. Files can be overwritten, edited, deleted.

The recommended default is to list **only your inbox/dream-reports directory**.
That's where reports land; reads of vault content come from the local
`scripts/load_vault_state.py` snapshot, which the LLM gets as part of its
prompt — no MCP read needed.

If you decide you want the LLM to read specific vault pages on demand during
reconcile, you can add the vault root as a second allowed dir:

```json
"args": [
  "-y",
  "@modelcontextprotocol/server-filesystem",
  "${VAULT_INBOX_PATH}",
  "${VAULT_ROOT}"
]
```

But understand the trade-off: write access to the vault root means the LLM can
edit any page if it decides to. The current recommendation is to keep the
filesystem MCP scoped to the inbox until a v0.3 auto-apply flow with rollback
log ships.

### Verify

```bash
npx -y @modelcontextprotocol/server-filesystem ${VAULT_INBOX_PATH}
```

The MCP starts as a stdio server (sits waiting for JSON-RPC). Ctrl+C to exit —
the fact that it started without an error means the path is valid and
accessible.

### Common gotchas

- **Path with spaces.** Quote it in the JSON, and make sure your vault path
  expansion doesn't trip on the space.
- **Symlinks.** The MCP resolves them. A symlink inside an allowed dir
  pointing outside it still won't let you escape — the realpath of the target
  is what's checked against the sandbox.
- **Tilde expansion.** JSON doesn't expand `~`. Use absolute paths or
  `$HOME/...` substitution at setup time.

---

## Tier 2: Notion MCP

**Package:** `@notionhq/notion-mcp-server` (official, maintained by Notion).

### What it adds to the dream cycle

If you use Notion for goals, OKRs, project trackers, or "current focus"
documents that your vault wiki references, the dream cycle can read those
pages during reconcile. Catches drift between vault assertions ("currently
focused on Project Phoenix") and Notion reality (Project Phoenix archived two
weeks ago).

### Prerequisites

- A Notion account
- A workspace you can add an internal integration to
- The pages or databases you want dream-skill to see

### Setup

1. Open **https://www.notion.so/profile/integrations**.
2. Click **"+ New integration"**.
3. Name it `dream-skill`. Workspace = your personal workspace.
   Type = **Internal**.
4. **Capabilities:** Read content. (Update + comments are optional. For
   reconciliation, read-only is enough.)
5. Submit. Copy the **Internal Integration Token** — starts with `ntn_...` or
   `secret_...`.
6. **Share the pages you want dream-skill to access.** Open each Notion page
   or database, click "..." (top-right) → **Connections** → add `dream-skill`.
   The integration sees **only** what's explicitly shared with it — there's no
   workspace-wide read by default.

### Where the token goes

`config/mcp-config.json`:

```json
"notion": {
  "command": "npx",
  "args": ["-y", "@notionhq/notion-mcp-server"],
  "env": {
    "OPENAPI_MCP_HEADERS": "{\"Authorization\":\"Bearer ${NOTION_TOKEN}\",\"Notion-Version\":\"2022-06-28\"}"
  }
}
```

Replace `${NOTION_TOKEN}` with the secret from step 5. The escaped quotes are
load-bearing — the value of `OPENAPI_MCP_HEADERS` is a JSON string that itself
contains JSON.

### Verify

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  OPENAPI_MCP_HEADERS='{"Authorization":"Bearer ntn_YOUR_TOKEN","Notion-Version":"2022-06-28"}' \
  npx -y @notionhq/notion-mcp-server | head -20
```

Should output ~20 tools (search, retrieve_page, query_database, etc.). If you
see auth errors, double-check the token has no stray whitespace and the
integration has at least one page shared with it.

### Common gotchas

- **"Page not found" errors.** The integration only sees pages explicitly
  shared with it via Connections. Sharing a parent page does NOT
  automatically share children — share each one you care about.
- **Token rotation.** Notion lets you regenerate the token from the integration
  page. Old token revokes immediately. Update `config/mcp-config.json`.
- **Workspace permissions.** If you're on a team workspace, you may need the
  workspace owner's approval to create an integration.

---

## Tier 2: Google Calendar MCP

**Package:** `@cocal/google-calendar-mcp` (community).

### What it adds to the dream cycle

Calendar event titles, attendees, and patterns over the scan window. Catches
"vault says my Friday is for deep work, calendar says you've taken eight
meetings the last four Fridays" — exactly the staleness the dream cycle is for.

### Prerequisites

- A Google account
- Access to Google Cloud Console (free)
- Willingness to do a one-time OAuth setup

### Setup

1. Open **https://console.cloud.google.com/**.
2. Create a project named `dream-skill` (or reuse an existing project).
3. **APIs & Services → Library** → search "Google Calendar API" → **Enable**.
4. **APIs & Services → OAuth consent screen** → choose **External** →
   fill in:
   - App name: `dream-skill`
   - User support email: your address
   - Save and continue
5. **Add yourself as a Test User** (under "Test users"). Without this, OAuth
   will fail with "app not verified" errors for your own account.
6. **APIs & Services → Credentials** → **"+ Create Credentials"** → **OAuth
   client ID** → Application type **Desktop app** → name `dream-skill`.
   Create.
7. **Download the JSON.** Save it to a known path:

   ```bash
   mkdir -p ~/.config/dream-skill
   mv ~/Downloads/client_secret_*.json ~/.config/dream-skill/gcal-credentials.json
   chmod 600 ~/.config/dream-skill/gcal-credentials.json
   ```

8. Run the package's `auth` subcommand to complete the OAuth dance. This
   opens a browser, you grant access, and the package caches the refresh
   token:

   ```bash
   GOOGLE_OAUTH_CREDENTIALS=~/.config/dream-skill/gcal-credentials.json \
     npx @cocal/google-calendar-mcp auth
   ```

   **Important:** the `auth` subcommand is required for the first run. Running
   the package WITHOUT `auth` (`npx -y @cocal/google-calendar-mcp`) starts the
   MCP server in stdio mode. If no token exists yet, it exits with
   `No authenticated accounts found` — that's not the auth flow, that's the
   server complaining about missing credentials.

   After consent, the package writes the token to its hardcoded default
   location:

   ```
   ~/.config/google-calendar-mcp/tokens.json
   ```

   Note the directory name and the plural `tokens.json`. This is the package's
   default; don't try to relocate it.

9. **Publish the consent screen** (recommended — see next section). Without this,
   refresh tokens expire every 7 days and the dream cycle starts failing with
   `invalid_grant` weekly.

### Publishing the consent screen (avoid weekly token expiry — applies to all Google MCPs)

By default the OAuth consent screen sits in **Testing** mode. Refresh tokens
issued to Testing-mode apps **expire every 7 days**, which is the root cause of
recurring `invalid_grant` errors. This applies to *every* Google MCP using your
OAuth client — Calendar, Gmail, Drive, etc. — and is a one-time fix at the
Cloud project level.

Google Cloud Console → **APIs & Services** → **OAuth consent screen** →
**Publishing status** → click **Publish app**. Status flips to *In production*.
That's the entire fix — refresh tokens minted afterward last indefinitely under
normal use.

**What "In production" does NOT change:**

- **Verification status.** The app is still unverified. Anyone authenticating
  still sees Google's "Google hasn't verified this app" warning. For solo
  personal use this is fine and expected.
- **Discoverability.** Publishing does not list the app in any Google directory.
  The only way someone can authenticate against your app is if they already
  have your `client_id`. Without the matching `client_secret` they can't start
  the OAuth flow at all.
- **Scopes.** Whatever scopes the OAuth client requests are still controlled
  entirely by you. Publishing doesn't broaden access.

**User isolation — what happens if someone else authenticates against your client:**

- Each Google user who completes OAuth gets a token **issued to themselves**,
  stored on **their machine**. Your account is never exposed to them. Theirs
  is never exposed to you. There is no shared store.
- Unverified apps are capped at **100 distinct users for sensitive scopes**
  (Calendar, Gmail). For solo use you will never hit this.
- The `client_secret` for "Desktop / Installed" app type is officially not
  meaningfully secret per Google's docs — installed apps can't actually keep
  secrets, since the binary contains them. Treat it as low-sensitivity, not
  as a password.

**Do not put yourself or others at risk:**

- **Do not** publish `client_id` + `client_secret` + redirect URI together in
  any public place (gist, README, screenshot, video). That combo lets a
  phisher craft a convincing consent URL in your app's name and harvest other
  users' tokens — those tokens authorize *their* Google account, not yours,
  but you're now the named operator of a phishing front.
- **Do not** apply for Google "App Verification" (the formal review).
  Verification requires domain ownership, a privacy policy, and a security
  review. Pointless for a solo personal client, and permanently attaches your
  real-name app to Google's verified-apps directory.
- **Do not** add other users under *Test users* after publishing. Leave that
  field empty — the field is meaningless for published apps and adds confusion.
- **Keep scopes minimal.** Stick to read-only for Gmail. Calendar needs the
  scopes the package requests by default; don't grant Drive, Photos, or other
  unrelated scopes.

### Where the credentials go

`config/mcp-config.json`:

```json
"google-calendar": {
  "command": "npx",
  "args": ["-y", "@cocal/google-calendar-mcp"],
  "env": {
    "GOOGLE_OAUTH_CREDENTIALS": "${GCAL_CREDS_PATH}"
  }
}
```

Replace `${GCAL_CREDS_PATH}` with the absolute path from step 7
(e.g., `/Users/you/.config/dream-skill/gcal-credentials.json`).

### Required OAuth scopes

The package handles scopes automatically during the `auth` flow. For
reference, it requests:

- `https://www.googleapis.com/auth/calendar.events.readonly`
- `https://www.googleapis.com/auth/calendar.readonly`

If you ever need to re-do OAuth with different scopes, delete
`~/.config/google-calendar-mcp/tokens.json` and re-run the `auth` command.

### Verify

```bash
claude --mcp-config ~/.claude/skills/dream-skill/config/mcp-config.json \
       --strict-mcp-config --tools "" --permission-mode bypassPermissions \
       --print "List my next 3 google calendar events. Titles + dates only."
```

If real events return, the integration is working. If you see "No authenticated
accounts found" or empty output, re-run the `auth` step.

### Common gotchas

- **Test users.** External-mode OAuth apps require you to add yourself as a
  test user explicitly. Forgetting this is the #1 setup failure.
- **Token expiry / `invalid_grant`.** Refresh tokens from Testing-mode OAuth
  clients **expire every 7 days**. If the integration suddenly fails after
  about a week with `invalid_grant`, that's the cause —
  [publish the consent screen](#publishing-the-consent-screen-avoid-weekly-token-expiry-applies-to-all-google-mcps)
  once and the problem stops recurring. Tokens from published clients don't
  expire under normal use, though Google will still invalidate them if you
  change your password or revoke the app from
  https://myaccount.google.com/permissions.
- **Multiple Google accounts.** OAuth will let you pick which account during
  the browser flow. Make sure you pick the one whose calendar you want
  dream-skill to see.

---

## Tier 2: Gmail MCP

**Package:** `@gongrzhe/server-gmail-autoauth-mcp` (community).

### What it adds to the dream cycle

Recent email subjects, senders, and metadata. Surfaces "you're still subscribed
to onboarding emails from the company you left two months ago" — life-state
signals from comms you can't easily see in chat history.

### Prerequisites

Same as Calendar. **You can reuse the same Google Cloud project**, just enable
the Gmail API in it.

### Setup

1. **Reuse the Google Cloud project** from Calendar (or create new).
2. **APIs & Services → Library** → search "Gmail API" → **Enable**.
3. **APIs & Services → Credentials** → **"+ Create Credentials"** → **OAuth
   client ID** → Desktop app → name `dream-skill-gmail`. Create.
4. Download the JSON:

   ```bash
   mkdir -p ~/.config/dream-skill
   mv ~/Downloads/client_secret_*.json ~/.config/dream-skill/gmail-credentials.json
   chmod 600 ~/.config/dream-skill/gmail-credentials.json
   ```

5. The `autoauth` package variant runs the OAuth flow on first invocation:

   ```bash
   GMAIL_OAUTH_PATH=~/.config/dream-skill/gmail-credentials.json \
   GMAIL_CREDENTIALS_PATH=~/.config/dream-skill/gmail-token.json \
     npx -y @gongrzhe/server-gmail-autoauth-mcp auth
   ```

   Browser opens, you grant access, token is written to `GMAIL_CREDENTIALS_PATH`.
6. If the underlying Google Cloud project is still in *Testing* mode, refresh
   tokens will expire every 7 days. The publishing step from the Calendar setup
   covers this for the whole project —
   [Publishing the consent screen](#publishing-the-consent-screen-avoid-weekly-token-expiry-applies-to-all-google-mcps).
   One publish, both MCPs stop expiring weekly.

### Where the credentials go

`config/mcp-config.json`:

```json
"gmail": {
  "command": "npx",
  "args": ["-y", "@gongrzhe/server-gmail-autoauth-mcp"],
  "env": {
    "GMAIL_OAUTH_PATH": "${GMAIL_CREDS_PATH}",
    "GMAIL_CREDENTIALS_PATH": "${GMAIL_TOKEN_PATH}"
  }
}
```

### Required OAuth scopes

- `https://www.googleapis.com/auth/gmail.readonly`
- `https://www.googleapis.com/auth/gmail.metadata`

Read-only is sufficient. Don't grant write/send scopes — dream-skill never
needs to send mail.

### Verify

```bash
GMAIL_OAUTH_PATH=~/.config/dream-skill/gmail-credentials.json \
GMAIL_CREDENTIALS_PATH=~/.config/dream-skill/gmail-token.json \
  npx -y @gongrzhe/server-gmail-autoauth-mcp --help
```

If the command runs without auth errors, the credentials are wired. For an
end-to-end test, run a dream cycle in dry-run mode and confirm the cycle
preview shows recent inbox metadata in the gathered signals.

### Common gotchas

- **Sharing OAuth client with Calendar.** You can use the same OAuth client ID
  for both Calendar and Gmail. They issue separate access tokens scoped to
  each API. This is the recommended setup — one consent flow, two integrations.
- **Scopes too narrow.** If you only granted `gmail.metadata` and want subject
  lines, you'll need `gmail.readonly`. Re-run auth.
- **Token store path collisions.** Don't reuse `gmail-token.json` for
  Calendar; the packages assume single-purpose token files.

---

## Manual `mcp-config.json` reference

If you skipped the wizard and are building the config by hand, here's the
schema. See [`config/mcp-config.example.json`](../skills/dream-skill/config/mcp-config.example.json)
for a copy-paste starting point.

```json
{
  "mcpServers": {
    "filesystem": { ... },
    "notion":     { ... },
    "google-calendar": { ... },
    "gmail":      { ... }
  }
}
```

Every server entry has:

- `command`: always `"npx"` for this skill.
- `args`: `["-y", "<package-name>", ...positional-args]`.
- `env`: object of env vars passed to the spawned MCP process. **This is
  where tokens live.** They never enter your shell environment, never get
  exported to `~/.zshrc`, and never load into any Claude session except
  the dream cycle.

You can include any subset. Missing servers just won't load.

---

## Troubleshooting

### `MCP <name> not responding`

The `npx` package may not be installed, or the token may be wrong. Check:

```bash
# Confirm the package can fetch + run
npx -y <package-name> --help

# Confirm Claude sees the right config
claude --mcp-config ~/.claude/skills/dream-skill/config/mcp-config.json \
       --strict-mcp-config \
       --print "list mcp servers you can see"
```

Note that `claude mcp list` does NOT show dream-skill MCPs — that command lists
globally installed servers, and dream-skill uses `--strict-mcp-config` so its
servers are session-scoped only.

### `Token expired` / `401 Unauthorized`

Rotate the token at the source service (Notion integration page; Google
account security panel), then update `config/mcp-config.json`.

### `Scope errors` (Google services)

Delete the token JSON file (`~/.config/google-calendar-mcp/tokens.json` for
Calendar; whatever you set `GMAIL_CREDENTIALS_PATH` to for Gmail), then re-run
the `auth` command. The auth flow will request the latest scope set required
by the package.

### `npx: command not found` under cron

Cron's PATH is minimal. The shipped `dream.sh` prepends `/opt/homebrew/bin`
and `/usr/local/bin`, which covers most macOS Node installs. If you use
`nvm` or a non-standard install, add that bin directory to the PATH line in
the crontab entry.

---

## Token revocation

| MCP | How to revoke |
|---|---|
| Notion | https://www.notion.so/profile/integrations → delete the integration |
| Google Calendar / Gmail | https://myaccount.google.com/permissions → revoke the OAuth app |
| Filesystem | No token; just remove it from `config/mcp-config.json` |

After revoking, also delete any local token JSON files and clear the relevant
entries from `config/mcp-config.json`.

---

## Security checklist

Once a quarter, or whenever the config changes:

- [ ] `config/mcp-config.json` is mode `600` (`chmod 600`)
- [ ] `config/mcp-config.json` is gitignored (default in the shipped repo;
      double-check if you forked)
- [ ] Token JSON files (`gcal-credentials.json`, `gmail-credentials.json`,
      `gmail-token.json`, `tokens.json`) are mode `600`
- [ ] No tokens accidentally committed to git history (`git log -p` over the
      config dir, or use `git-secrets` / `trufflehog`)
- [ ] Notion integration is scoped to only the pages dream-skill needs
- [ ] Google OAuth scopes are read-only
