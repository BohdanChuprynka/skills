#!/usr/bin/env bash
set -euo pipefail

source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
codex_root="${CODEX_HOME:-${HOME}/.codex}"
target="${codex_root}/skills/parallel-workstreams"

mkdir -p -- "$(dirname -- "$target")"

if [[ -L "$target" ]] && [[ "$(readlink "$target")" == "$source_dir" ]]; then
  printf 'Parallel Workstreams is already installed at %s\n' "$target"
  exit 0
fi

if [[ -e "$target" || -L "$target" ]]; then
  printf 'Refusing to replace existing path: %s\n' "$target" >&2
  exit 1
fi

ln -s -- "$source_dir" "$target"
printf 'Installed Parallel Workstreams at %s\n' "$target"
