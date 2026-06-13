# Security & bug-fix review — 2026-06-12

A multi-agent review of this monorepo surfaced bugs, vulnerabilities, and
inconsistencies. Each finding below was re-verified against the live code before
fixing, and each fix is covered by a test (TDD: failing test witnessed first)
unless noted. Nothing was committed — review with `git diff`.

## Fixes applied

### transcribe-audio
- **Test isolation broke + leaked the real API key (HIGH).** `CONFIG_DIR`/`CONFIG_FILE`
  were bound at import, so the test fixture's `HOME`/`XDG_CONFIG_HOME` patch was
  ignored — tests wrote to the real `~/.config`, and one test dumped the live
  `OPENAI_API_KEY` into output. Made config-dir resolution lazy (`get_config_dir()`/
  `get_config_file()`), so isolation works and the real config is never touched.
- **`.env` credential-substitution vector (LOW→removed).** `load_config` auto-loaded
  `./.env` from the CWD and a repo-relative `.env`, letting a planted file swap the
  key or redirect the vault. Now loads only an explicit `env_file` or the canonical
  `~/.config/transcribe-audio/.env`. `setup.sh` no longer creates an in-repo `.env`,
  and the orphaned repo `.env` was `chmod 600`'d (you can delete it).
- **gpt-4o transcribe models always 400'd (MEDIUM).** `verbose_json` + timestamps are
  whisper-1-only. `_build_transcribe_kwargs` now sends `json` for `gpt-4o*` models.
- **`default_summary_style` was dead (MEDIUM).** CLI hardcoded `"brief"`. Added
  `_resolve_summary_style` so the flag falls back to the configured default.
- **Chunking broke on `%`/glob filenames (MEDIUM).** ffmpeg segment template + `glob`
  reused the input stem. Now uses a fixed `chunk_%03d.mp3` basename in the per-run dir.
- **Obsidian writes could traverse + silently overwrite (LOW).** Added a vault-containment
  check on `subdir`, a path-separator check on the filename pattern, and `-1/-2`
  collision suffixing.
- **CI never ran (HIGH process).** `ci.yml` sat at `transcribe-audio/.github/workflows/`
  where GitHub doesn't look; moved to repo-root `.github/workflows/transcribe-audio-ci.yml`.
- **Unused deps removed:** `pydub` (breaks on 3.13), `pydantic-settings`, `httpx`, `respx`.
- **setup.sh:** `rm -f` → `rm -rf` so re-install doesn't abort on a real skill dir.
- Tests: 31 pass (7 new).

### clean-wiki (review server)
- **CSRF on the localhost decision API (HIGH).** `get_json(force=True)` accepted
  cross-site `text/plain` POSTs with no token/Origin check, so any page open during a
  review could forge "approve" (and Claude then applies it). Added a per-run token
  required on every `/api/*` call (issued in the URL, echoed via `X-CSRF-Token`) plus a
  loopback `Host` check (DNS-rebinding defense).
- **Stored XSS (HIGH).** `signal_label`, `confidence`, `vault`, `target_file` were
  interpolated into `innerHTML` unescaped (one into a `class="…"` attribute). Wrapped all
  sinks (incl. a second `vault` render the finding missed) in `escapeHtml`, which now also
  escapes quotes and tolerates `undefined`.
- **Decision file races/corruption (MEDIUM).** `decisions.json` read-modify-write was
  unlocked and non-atomic. Added a lock + temp-file `os.replace`.
- **Silent mock-data trap (LOW).** A backend error (incl. a tokenless 403) fell through to
  fake data. Now only a thrown fetch (file:// preview) shows mock; an error status renders
  an explicit message.
- Tests: 3 new server tests pass (`tests/test_serve.py`).

### dream-skill
- **awk `-v` corrupted any fact with a backslash + broke idempotency (MEDIUM).**
  `awk -v` interprets C escapes (`\n \t \\ \d …`), mangling Windows paths / regex / LaTeX,
  and because the `grep -Fxq` idempotency check used the raw text, the mangled line
  re-appended every run. Switched content passing to `ENVIRON[]` (not escape-processed) in
  `vault-writer.sh`, `apply-undo.sh`, and `queue.sh`. New regression test (append + replace
  + undo round-trip with backslashes).
- **Review server: same CSRF + atomicity fixes as clean-wiki** in `serve-review.py`, plus
  token plumbing + quote-safe `escHtml` in `dream-review.html`.
- **Flask dependency was undeclared (MEDIUM, ship blocker).** Added `requirements.txt` and a
  preflight install in SKILL.md Step 6b, so the review step doesn't `ModuleNotFoundError`
  on a clean install.
- **Prompt-injection guard (HIGH surface).** Transcript text is fed to write-capable MAP/
  ROUTE/RECONCILE agents with no "this is data, not instructions" guard. Added explicit
  untrusted-input guards to all three prompts.
- **Unstable fallback id (LOW).** `build-review-queue.py` used builtin `hash()`
  (per-process randomized) for entries missing an id, breaking resume. Switched to a stable
  sha1 digest.
- **Version skew (LOW).** plugin.json/marketplace.json said 0.2.0 vs SKILL.md 0.3.1; bumped
  manifests to 0.3.1.
- Tests: 20 shell suites + 3 new server tests pass.

### voice-check
- **`eval` default was broken (MEDIUM).** `_DEFAULT_NEGATIVES` pointed at
  `src/examples/contrast` (one level too shallow); a bare `eval` loaded zero negatives and
  always reported AUC 0.5. Fixed the path (`parents[2]`) and made an empty negatives set
  raise loudly instead of degrading silently.
- **`--profile` default was repo-relative (LOW).** A bare `voice-check check` outside the
  repo failed. Defaults to the canonical `~/.config/voice-check/profile` when present.
- Tests: 80 pass (2 new).

### sync-phone
- Added the missing "do not exfiltrate dictated content to the network" rule to the Claude
  SKILL.md (the Codex copy already had it).

## Second pass — remaining items implemented

The items previously deferred have now been implemented, except two that are
deliberate decisions (below).

- **calendar-plan reconciled toward the SKILL.md contract.** The cron runner
  `calendar-plan.sh` now defaults to `draft` (report-only) instead of `auto`, so
  unattended writes are an explicit `--mode auto` opt-in (matching "draft first, write on
  approval"). `setup.sh` now seeds the canonical `~/.config/calendar-plan/{preferences,
  observed-patterns}.md` the interactive skill actually reads (with the in-repo `config/`
  and Codex install symlinked to the same file), so the skill works on a fresh install and
  `doctor.sh` passes. Added the missing `observed-patterns.example.md`. `apply_log.py` now
  records the real event context instead of a `?` placeholder (extracted + unit-tested via
  `build_action_lines`). Fixed the SKILL.md time-resolution gap (`00:00–15:59 → today`).
- **clean-wiki onclick injection fixed properly.** Added `jsAttr()` (escapes for the
  JS-string-in-HTML-attribute context, preserving the raw id the handler looks up) and
  applied it to all three dynamic `onclick` sites. `escapeHtml`/`escHtml` quote-escaping
  was already done in pass 1.
- **clean-wiki getCounts fixed.** Now counts over decision-units (group cards contribute
  one key per sub-finding), clamped ≥0, so the Finish-modal stats can't go negative.
- **Dead code removed:** `reviewAutoOneByOne` (clean-wiki) and `count_tokens.py` (dream-skill).
- **slugify** preserves both scripts in a mixed Latin+Cyrillic title (was dropping the Cyrillic).
- **dream-skill vault lock hardened:** user-scoped lock dir (uid suffix, off the world-shared
  `/tmp/dream-vault-locks`) + stale-lock reclaim via holder-PID liveness (survives a SIGKILL
  that bypasses the EXIT trap). Concurrent-write test still green.
- **Privacy:** root `.gitignore` now has monorepo-wide secret catch-alls (covers
  `session-continue/`, which had none) keeping `*.example` templates tracked; the real-org
  example/fixture strings were renamed to a fictional org consistently (tests stay green).
- **Docs:** clean-wiki `DESIGN.md` Source-A section now flags `scan.py`/`apply.py`/`/apply` as
  removed v1; sync-phone no-exfiltrate rule (pass 1).

## Deliberate decisions (NOT changed, with reasoning)

1. **dream-skill keeps auto-writing high-confidence `new` facts.** This is the skill's core
   design — its own description is *"Confident facts written on session close; uncertain or
   destructive edits queued for manual review."* Forcing every new fact through review would
   contradict that and add large review burden without being more secure than the fix that
   actually matters: the **prompt-injection guards** added to MAP/ROUTE/RECONCILE (pass 1),
   which stop injected transcript text from becoming a high-confidence fact in the first
   place. Kept auto-write; relying on the guards.
2. **git history rewrite is prepared, not executed.** The deleted `PLAN-*.md` / spec docs
   (14 paths, personal profile data) are still in public history. A `git filter-repo` +
   `git push --force` is irreversible, invalidates all clones/forks, and needs a GitHub
   Support ticket to purge cached views — too destructive to run autonomously. `scrub-history.sh`
   (repo root) is ready: it previews by default, only rewrites with `--confirm`, and never
   pushes (it prints the force-push commands for you). No live secrets were ever committed,
   so this is a privacy decision, not an emergency.

Not pursued (genuinely low value / would need your product direction): the deeper
calendar-plan split between the interactive Claude skill (calendar-only) and the Codex cron
automation (multi-source) — both are real entry points; I made the default safe rather than
delete the Codex subsystem.

## Verification pass (issues the review caught in the fixes, then fixed)

A fresh-eyes review of the second pass found and I corrected:
- **[HIGH] calendar-plan data loss on in-place upgrade** — the rewired `setup.sh` would
  overwrite an already-edited prefs file with a fresh template when migrating from the old
  Codex-canonical layout. Fixed: it now `mv`-migrates an existing real prefs file into the
  canonical path, and the symlink loop backs up (never `rm`s) a real file.
- **[MEDIUM] vault-writer stale-lock reclaim race** — two waiters reacting to the same dead
  holder PID could both delete a just-reacquired lock and double-acquire. Fixed: the
  destructive reclaim is now serialized behind its own `mkdir` guard. Added a regression test
  (stale lock with a dead holder PID is reclaimed).
- **[MEDIUM] transcribe-audio docs drift** — README/SKILL still told users to put the key in a
  repo `.env` (no longer read). Updated to the canonical `~/.config` path.
- **[LOW] hardening** — `compare_digest` now byte-encodes (non-ASCII token → clean 403, not
  500) in both servers; both review UIs strip `?token` from the URL after capture
  (`history.replaceState`); calendar-plan `doctor.sh`/runner honor `XDG_CONFIG_HOME` and
  `doctor.sh` placeholder check broadened; the review doc no longer names the real org.

## Caveats on the fixes themselves
- **ruff/pyright were not run locally** (not installed). Code follows existing style, but the
  CI lint step is the authority — run it before merge.
- The two web UIs can't be browser-run in this environment; JS was validated with `node --check`
  and the servers with Flask test-client unit tests. The onclick/getCounts changes are reasoned,
  not click-tested.
- New Python tests aren't wired into CI (clean-wiki/calendar-plan have no CI; dream-skill's CI is
  the shell `run-all.sh`). Run them manually (commands below).
- The pre-existing uncommitted change to `voice-check/skills/voice-check/SKILL.md` is yours,
  untouched.

## Validation
```
transcribe-audio   PYTHONPATH=src      pytest         → 32 passed
voice-check        PYTHONPATH=src      pytest         → 80 passed
clean-wiki         PYTHONPATH=scripts  pytest tests/  → 3 passed
dream-skill        bash tests/run-all.sh              → 20 suites green
dream-skill        PYTHONPATH=scripts  pytest tests/test_serve_review.py → 3 passed
calendar-plan      python3 -m pytest tests/           → 3 passed
```
