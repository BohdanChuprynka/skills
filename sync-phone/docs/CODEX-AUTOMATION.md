# Codex automation (optional)

By default, sync-phone is invoked on demand:

- Claude Code: `/sync-phone`
- Codex CLI: *"drain my phone inbox"* (or whatever phrase the `agents/openai.yaml` interface declares)

If you want sync-phone to run on a schedule from Codex, `setup.sh` already rendered a Codex automation template for you. It's installed at:

```
~/.codex/automations/sync-phone/automation.toml
```

And it's **inactive by default**. Codex will not run it until you explicitly opt in.

## Why off by default

Sync-phone touches your knowledge base. A scheduled run that fires while your iCloud sync is mid-flight could see a half-flushed `iphone-raw.md` and write an incomplete summary. On-demand keeps you in the loop. Only flip the cron on once you've used the skill enough to trust its routing on your specific vault shape.

## Turning it on

1. Open the file:

   ```bash
   $EDITOR ~/.codex/automations/sync-phone/automation.toml
   ```

2. Flip:

   ```
   status = "INACTIVE"
   ```

   to:

   ```
   status = "ACTIVE"
   ```

3. (Optional) Adjust `rrule`, `cwds`, `model`, or `reasoning_effort` to match your preferences. The defaults Run weekly at the local `CRON_HOUR` from `local.env` across every day of the week — effectively a daily drain in Codex's weekly-rule format.

4. Restart Codex so it re-scans automations.

## Turning it off

Flip `status` back to `"INACTIVE"` (or delete the file outright). Codex won't fire it the next time it scans.

## Safety knobs

- The cron prompt explicitly tells Codex to **truncate, never delete** and to **never exfiltrate dictated content to the network**. Re-read the `prompt = """..."""` block before activating — it's the contract Codex follows on every run.
- The `execution_environment = "worktree"` line keeps Codex inside an ephemeral worktree, so a misbehaving run can't pollute the host filesystem outside the configured `cwds`.
- If you change `VAULTS_DIR` in `local.env`, re-run `bash setup.sh` so the automation's `cwds` line stays in sync. Forgetting this is the most likely way a scheduled run would silently fail.

## Troubleshooting

Run the Codex doctor:

```bash
bash codex/doctor.sh
```

It checks that the skill files, settings, and (if present) automation.toml are all wired up correctly. Common failures and fixes are listed in [docs/SHORTCUT-SETUP.md](SHORTCUT-SETUP.md) and the top-level `README.md`.
