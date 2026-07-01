# Clean-Wiki Codex Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add production-ready Codex support to Clean-Wiki while preserving the existing Claude Code workflow.

**Architecture:** Keep one inner skill folder at `skills/clean-wiki/` as the source of truth. Add Codex metadata and setup automation around it, then make the skill prompt platform-aware without changing the Flask review server contract. Codex receives a sanitized copy plus its own local config and venv, so repo-private runtime files are not copied by accident; reruns preserve Codex-local config and runtime data.

**Tech Stack:** Bash setup script, Python/Flask review UI, pytest, Codex skill metadata, optional Codex plugin manifest.

---

## File Structure

- Modify `README.md`: document recommended setup, Claude usage, Codex usage, and development verification.
- Modify `../README.md`: move Clean-Wiki into the setup-script install bucket.
- Modify `skills/clean-wiki/SKILL.md`: make orchestration instructions work in Claude Code and Codex.
- Modify `skills/clean-wiki/clean-wiki.sh`: select `skills/clean-wiki/.venv/bin/python` before all Python checks when present.
- Create `setup.sh`: idempotent local setup for Claude Code, Codex, config, and Python dependencies.
- Create `.codex-plugin/plugin.json`: optional Codex plugin packaging metadata.
- Create `skills/clean-wiki/agents/openai.yaml`: Codex UI metadata.
- Create `skills/clean-wiki/tests/test_codex_support.py`: static and temp-HOME setup tests for new support artifacts.

## Task 1: Add Failing Codex Artifact Tests

**Files:**
- Create: `skills/clean-wiki/tests/test_codex_support.py`

- [ ] **Step 1: Write the failing tests**

```python
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


OUTER_DIR = Path(__file__).resolve().parents[3]
INNER_DIR = OUTER_DIR / "skills" / "clean-wiki"


def test_setup_script_contains_codex_runtime_guards():
    setup = OUTER_DIR / "setup.sh"
    text = setup.read_text()

    assert os.access(setup, os.X_OK)
    assert "CODEX_SKILLS" in text
    assert ".codex/skills" in text
    assert "copy_sanitized_skill_dir" in text
    assert "install_runtime" in text
    assert "ensure_config" in text
    assert "vault-paths.example.toml" in text
    assert "vault-paths.toml" in text
    assert "python3 -m venv" in text
    assert "pip install -r" in text
    assert "CLEAN_WIKI_SETUP_SKIP_DEPS" in text
    assert "restart Codex" in text
    assert '"logs"' in text
    assert 'endswith(".log")' in text


def test_setup_script_copies_sanitized_codex_skill_and_preserves_config(tmp_path):
    repo_copy = tmp_path / "clean-wiki"
    ignore = shutil.ignore_patterns(".venv", "data", ".pytest_cache", "reports")
    shutil.copytree(OUTER_DIR, repo_copy, ignore=ignore)

    inner_copy = repo_copy / "skills" / "clean-wiki"
    (inner_copy / "config" / "vault-paths.toml").write_text("repo-config\n")
    (inner_copy / "data").mkdir()
    (inner_copy / "data" / "cleanup-queue.json").write_text('{"private": true}\n')
    (inner_copy / ".venv").mkdir()
    (inner_copy / ".venv" / "private.txt").write_text("private\n")
    (inner_copy / "logs").mkdir()
    (inner_copy / "logs" / "private.log").write_text("private log\n")
    (inner_copy / "debug.log").write_text("debug log\n")

    home = tmp_path / "home"
    (home / ".codex").mkdir(parents=True)

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["CLEAN_WIKI_SETUP_SKIP_DEPS"] = "1"

    result = subprocess.run(
        ["bash", str(repo_copy / "setup.sh")],
        cwd=repo_copy,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    codex_skill = home / ".codex" / "skills" / "clean-wiki"
    assert (codex_skill / "SKILL.md").is_file()
    assert (codex_skill / "agents" / "openai.yaml").is_file()
    assert (codex_skill / "config" / "vault-paths.toml").read_text() == "repo-config\n"
    assert not (codex_skill / "data").exists()
    assert not (codex_skill / ".venv" / "private.txt").exists()
    assert not (codex_skill / "logs").exists()
    assert not (codex_skill / "debug.log").exists()

    (codex_skill / "config" / "vault-paths.toml").write_text("codex-local-config\n")
    (codex_skill / "data").mkdir()
    (codex_skill / "data" / "undo-log.jsonl").write_text("codex-runtime-data\n")
    (inner_copy / "config" / "vault-paths.toml").write_text("changed-repo-config\n")

    result = subprocess.run(
        ["bash", str(repo_copy / "setup.sh")],
        cwd=repo_copy,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (codex_skill / "config" / "vault-paths.toml").read_text() == "codex-local-config\n"
    assert (codex_skill / "data" / "undo-log.jsonl").read_text() == "codex-runtime-data\n"


def test_setup_script_installs_codex_skill_for_fresh_home_without_codex_on_path(tmp_path):
    repo_copy = tmp_path / "clean-wiki"
    ignore = shutil.ignore_patterns(".venv", "data", ".pytest_cache", "reports")
    shutil.copytree(OUTER_DIR, repo_copy, ignore=ignore)

    home = tmp_path / "home"
    home.mkdir()

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PYTHON"] = sys.executable
    env["PATH"] = "/usr/bin:/bin"
    env["CLEAN_WIKI_SETUP_SKIP_DEPS"] = "1"

    result = subprocess.run(
        ["bash", str(repo_copy / "setup.sh")],
        cwd=repo_copy,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    codex_skill = home / ".codex" / "skills" / "clean-wiki"
    assert (codex_skill / "SKILL.md").is_file()
    assert (codex_skill / "config" / "vault-paths.toml").is_file()


def test_codex_metadata_exists_and_has_default_prompt():
    metadata = INNER_DIR / "agents" / "openai.yaml"
    text = metadata.read_text()

    assert 'display_name: "Clean Wiki"' in text
    assert "short_description:" in text
    assert "default_prompt:" in text
    assert "$clean-wiki" in text
    assert "allow_implicit_invocation: false" in text


def test_codex_plugin_manifest_packages_skill_directory():
    manifest = json.loads((OUTER_DIR / ".codex-plugin" / "plugin.json").read_text())

    assert manifest["name"] == "clean-wiki"
    assert manifest["skills"] == "./skills"
    assert manifest["version"]
    assert "Obsidian" in manifest["description"]
    assert manifest["interface"]["displayName"] == "Clean Wiki"


def test_skill_prompt_documents_claude_and_codex_orchestration():
    text = (INNER_DIR / "SKILL.md").read_text()

    assert "Claude Code" in text
    assert "Codex" in text
    assert "subagent" in text.lower()
    assert "sequential" in text.lower()
    assert "index_drift" in text
    assert "Resolve `skill_dir` before reading or writing any config, queue, decision, or undo files." in text
    assert "`$skill_dir/config/vault-paths.toml`" in text
    assert "`$skill_dir/data/cleanup-queue.json`" in text
    assert "`$skill_dir/data/decisions.json`" in text
    assert "`$skill_dir/data/undo-log.jsonl`" in text
    assert "Locate the skill directory" in text
    assert "skills/clean-wiki/clean-wiki.sh" in text
    assert "${CODEX_HOME:-$HOME/.codex}/skills/clean-wiki/clean-wiki.sh" in text
    assert "data/cleanup-queue.json" in text
    assert "data/decisions.json" in text
    assert "data/undo-log.jsonl" in text


def test_gitignore_excludes_generic_runtime_logs():
    text = (OUTER_DIR / ".gitignore").read_text()

    assert "skills/clean-wiki/logs/" in text
    assert "skills/clean-wiki/*.log" in text


def test_readme_documents_codex_install_and_usage():
    text = (OUTER_DIR / "README.md").read_text()

    assert "./setup.sh" in text
    assert "~/.codex/skills/clean-wiki" in text
    assert "$clean-wiki" in text
    assert "restart Codex" in text
```

Also add a setup regression test that creates an existing non-symlink
`~/.claude/skills/clean-wiki` directory under a temporary `HOME`, runs `setup.sh`,
and verifies the old directory is moved to `clean-wiki.backup-*` before the new
symlink is created.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest -q skills/clean-wiki/tests/test_codex_support.py`

Expected: FAIL because `setup.sh`, `agents/openai.yaml`, `.codex-plugin/plugin.json`, and Codex README content do not exist yet.

## Task 2: Add Codex Setup And Metadata

**Files:**
- Create: `setup.sh`
- Create: `.codex-plugin/plugin.json`
- Create: `skills/clean-wiki/agents/openai.yaml`
- Modify: `skills/clean-wiki/clean-wiki.sh`

- [ ] **Step 1: Implement `setup.sh`**

Create an idempotent Bash installer that:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="clean-wiki"
SKILL_DIR="$SCRIPT_DIR/skills/$SKILL_NAME"
CONFIG_EXAMPLE="$SKILL_DIR/config/vault-paths.example.toml"
CONFIG_FILE="$SKILL_DIR/config/vault-paths.toml"
REQUIREMENTS_FILE="$SKILL_DIR/requirements.txt"
PYTHON_BIN="${PYTHON:-python3}"

copy_sanitized_skill_dir() {
  local src="$1"
  local dst="$2"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  "$PYTHON_BIN" - "$src" "$dst" <<'PY'
from pathlib import Path
import shutil
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
ignored_names = {
    ".venv",
    ".pytest_cache",
    "__pycache__",
    "data",
    "logs",
    "reports",
    ".usage-log.jsonl",
    ".apply-log.jsonl",
}

def ignore(directory, names):
    current = Path(directory)
    ignored = {name for name in names if name in ignored_names or name.endswith(".pyc") or name.endswith(".log")}
    if current == src / "config":
        ignored.add("vault-paths.toml")
    return ignored

shutil.copytree(src, dst, ignore=ignore)
PY
}
```

Then:
- validate Python 3.11+ once at startup;
- define `install_runtime <skill_dir>` to create `<skill_dir>/.venv` and run `<venv>/bin/python -m pip install -r <skill_dir>/requirements.txt`, unless `CLEAN_WIKI_SETUP_SKIP_DEPS=1`;
- define `ensure_config <skill_dir> [source_config]` to create `<skill_dir>/config/vault-paths.toml` from the source config when provided, otherwise from the example, without overwriting an existing config;
- warn when a config contains `/ABSOLUTE/PATH/`;
- symlink Claude Code to the repo skill when `claude` or `~/.claude` exists, replacing old symlinks directly but moving pre-existing real files/directories to `clean-wiki.backup-*` before creating the symlink;
- always copy a sanitized skill into `~/.codex/skills/clean-wiki`, preserving an existing Codex-local config and runtime `data/`, `logs/`, and `reports/` across reruns, then create the Codex-local config and venv inside that copied skill;
- exclude `data/`, `.venv/`, caches, `reports/`, `logs/`, `*.log`, and the repo-local real config from the copied skill.

- [ ] **Step 2: Add Codex metadata**

Create `skills/clean-wiki/agents/openai.yaml`:

```yaml
interface:
  display_name: "Clean Wiki"
  short_description: "Audit Obsidian vaults, review cleanup findings locally, and apply only approved wiki changes."
  default_prompt: "Use $clean-wiki to audit my Obsidian vaults, launch the local review UI, and apply only the cleanup changes I approve."

policy:
  allow_implicit_invocation: false
```

- [ ] **Step 3: Add Codex plugin manifest**

Create `.codex-plugin/plugin.json`:

```json
{
  "name": "clean-wiki",
  "version": "0.1.0",
  "description": "Monthly Obsidian vault cleanup skill with local review UI and approval-gated edits.",
  "skills": "./skills",
  "author": {
    "name": "Bohdan Chuprynka",
    "url": "https://github.com/BohdanChuprynka"
  },
  "homepage": "https://github.com/BohdanChuprynka/skills/tree/main/clean-wiki",
  "repository": "https://github.com/BohdanChuprynka/skills",
  "license": "MIT",
  "interface": {
    "displayName": "Clean Wiki",
    "shortDescription": "Audit Obsidian vaults with a local approval UI.",
    "longDescription": "Clean-Wiki scans configured Obsidian vaults through the active agent, queues cleanup findings, opens a local review UI, and applies only explicitly approved changes with an undo log.",
    "developerName": "Bohdan Chuprynka",
    "category": "Productivity",
    "capabilities": ["Local files", "Review", "Write"],
    "websiteURL": "https://github.com/BohdanChuprynka/skills/tree/main/clean-wiki",
    "defaultPrompt": [
      "Use $clean-wiki to audit my Obsidian vaults."
    ]
  },
  "keywords": [
    "codex",
    "claude-code",
    "skill",
    "obsidian",
    "knowledge-base",
    "personal-wiki",
    "cleanup",
    "review-ui"
  ]
}
```

- [ ] **Step 4: Prefer the venv in `clean-wiki.sh`**

Use the local venv Python when present:

```bash
PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON:-python3}"
fi
cd "$SCRIPT_DIR"

exec "$PYTHON_BIN" "$SCRIPT_DIR/scripts/serve.py" "$@"
```

- [ ] **Step 5: Run the Codex artifact tests**

Run: `python3 -m pytest -q skills/clean-wiki/tests/test_codex_support.py`

Expected: PASS.

## Task 3: Update Skill Instructions And Docs

**Files:**
- Modify: `skills/clean-wiki/SKILL.md`
- Modify: `README.md`
- Modify: `../README.md`

- [ ] **Step 1: Update `SKILL.md`**

Replace Claude-only phrasing with a shared flow:

```markdown
## Runtime surfaces

- Claude Code: invoke as `/clean-wiki`; use Claude sub-agents when available.
- Codex: invoke explicitly with `$clean-wiki` or select the skill; use Codex subagent tooling when available.
```

Keep the existing scan, queue, UI, decision, apply, undo, and safety sections. Also:
- replace `AskUserQuestion` with a platform-neutral prompt;
- remove Sonnet-specific subagent pinning;
- include `index_drift` in the finding enum;
- define Codex fallback scanning as sequential when no subagent tool is exposed;
- resolve `skill_dir` before any config/data access and use explicit `$skill_dir/config/vault-paths.toml`, `$skill_dir/data/cleanup-queue.json`, `$skill_dir/data/decisions.json`, and `$skill_dir/data/undo-log.jsonl` paths;
- define undo as an agent-orchestrated request: Claude users ask `/clean-wiki --undo`; Codex users ask `Use $clean-wiki --undo`.

- [ ] **Step 2: Update `README.md`**

Make `./setup.sh` the recommended install. Include:

```markdown
### Codex

Run `./setup.sh`, restart Codex, then ask:

```
Use $clean-wiki to audit my vaults.
```
```

Also update the privacy section to distinguish local files/UI from model-provider context: the active Claude/Codex agent reads vault content while scanning.

- [ ] **Step 3: Update `../README.md`**

Move Clean-Wiki into "Setup-script install" and explain that setup wires both Claude Code and Codex.

- [ ] **Step 4: Run full Clean-Wiki tests**

Run: `python3 -m pytest -q skills/clean-wiki/tests`

Expected: all tests pass.

## Task 4: Local Codex Setup

**Files:**
- Runtime only: `skills/clean-wiki/.venv/`
- Runtime only: `skills/clean-wiki/config/vault-paths.toml`
- Runtime only: `~/.codex/skills/clean-wiki/`

- [ ] **Step 1: Run setup**

Run: `./setup.sh`

Expected:
- Python dependencies installed into `skills/clean-wiki/.venv`.
- Real config created if missing.
- Clean-Wiki copied to `~/.codex/skills/clean-wiki` for Codex local use.
- Codex-local Python dependencies installed into `~/.codex/skills/clean-wiki/.venv`.
- Codex-local config created without copying `data/`, logs, reports, caches, or repo-local `.venv`.

- [ ] **Step 2: Verify local install**

Run:

```bash
test -f ~/.codex/skills/clean-wiki/SKILL.md
test -f ~/.codex/skills/clean-wiki/agents/openai.yaml
test -x skills/clean-wiki/.venv/bin/python
test -x ~/.codex/skills/clean-wiki/.venv/bin/python
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify review server help path**

Run: `skills/clean-wiki/.venv/bin/python skills/clean-wiki/scripts/serve.py --help`

Expected: command exits 0 and shows `--config`, `--data-dir`, `--port`, and `--no-browser`.

## Self-Review Checklist

- Spec coverage: setup, Codex metadata, plugin packaging, skill behavior, docs, tests, and local install are covered.
- Placeholder scan: no forbidden placeholder requirements remain.
- Type/path consistency: all paths use the existing outer `clean-wiki/` plus inner `skills/clean-wiki/` layout.
