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
    env["PYTHON"] = sys.executable
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
    repo_config = repo_copy / "skills" / "clean-wiki" / "config" / "vault-paths.toml"
    if repo_config.exists():
        repo_config.unlink()

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
    assert "/ABSOLUTE/PATH/" in (codex_skill / "config" / "vault-paths.toml").read_text()

    repo_config.write_text(
        '[[vaults]]\nname = "notes"\npath = "/Users/example/Obsidian/notes"\n'
    )

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
    assert (codex_skill / "config" / "vault-paths.toml").read_text() == repo_config.read_text()


def test_setup_script_backs_up_existing_claude_directory(tmp_path):
    repo_copy = tmp_path / "clean-wiki"
    ignore = shutil.ignore_patterns(".venv", "data", ".pytest_cache", "reports")
    shutil.copytree(OUTER_DIR, repo_copy, ignore=ignore)

    home = tmp_path / "home"
    existing = home / ".claude" / "skills" / "clean-wiki"
    existing.mkdir(parents=True)
    (existing / "config").mkdir()
    (existing / "config" / "vault-paths.toml").write_text("claude-local-config\n")

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PYTHON"] = sys.executable
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
    assert existing.is_symlink()
    backups = list((home / ".claude" / "skills").glob("clean-wiki.backup-*"))
    assert len(backups) == 1
    assert (backups[0] / "config" / "vault-paths.toml").read_text() == "claude-local-config\n"


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
    assert "mentions wiki entropy" not in text
    assert "too much info accumulated" not in text
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
