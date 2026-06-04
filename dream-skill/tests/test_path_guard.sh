#!/usr/bin/env bash
# Test: path-guard.sh assert_within_vault — confines vault writes to the root.
# This is the security-critical guard: .target.page is LLM-generated and untrusted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/../scripts/path-guard.sh"
[ -f "$GUARD" ] || { echo "FAIL: path-guard.sh missing"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

VAULT=$(mktemp -d "/tmp/dream-guard-vault-XXXXXX")
trap 'rm -rf "$VAULT"' EXIT
mkdir -p "$VAULT/wiki"

# Run the guard in a subshell so its `exit 1` on escape is catchable here.
guard() { ( . "$GUARD"; assert_within_vault "$VAULT" "$1" ) 2>/dev/null; }

# 1. normal relative path → allowed
guard "wiki/experience.md" || fail "rejected a legitimate relative page"
echo "PASS: allows a normal relative page"

# 2. leading '..' traversal → rejected
if guard "../escape.md"; then fail "allowed '../escape.md'"; fi
echo "PASS: rejects leading '..' traversal"

# 3. embedded '..' traversal → rejected
if guard "wiki/../../escape.md"; then fail "allowed embedded '..' traversal"; fi
echo "PASS: rejects embedded '..' traversal"

# 4. absolute path → rejected
if guard "/etc/passwd"; then fail "allowed an absolute path"; fi
echo "PASS: rejects absolute page path"

# 5. '..' inside a filename (not a path segment) → allowed
guard "wiki/v1..2-notes.md" || fail "rejected a legit filename containing '..'"
echo "PASS: allows '..' inside a filename (not a segment)"

# 6. escape into an EXISTING outside directory → rejected (realpath belt + '..' check)
OUTSIDE=$(mktemp -d "/tmp/dream-guard-outside-XXXXXX")
if guard "../$(basename "$OUTSIDE")/x.md"; then rm -rf "$OUTSIDE"; fail "allowed escape to an existing outside dir"; fi
rm -rf "$OUTSIDE"
echo "PASS: rejects escape into an existing outside directory"

# 7. in-vault directory symlink pointing OUT + a NOT-YET-CREATED subdir → rejected.
#    This is the bypass the first fix missed: mkdir -p would follow the symlink out
#    of the vault, and the immediate parent ("linkdir/newsub") doesn't exist yet so a
#    naive parent-only check is skipped. The guard must walk up to the symlink.
OUTSIDE2=$(mktemp -d "/tmp/dream-guard-symout-XXXXXX")
ln -s "$OUTSIDE2" "$VAULT/linkdir"
if guard "linkdir/newsub/escape.md"; then rm -rf "$OUTSIDE2"; fail "allowed escape via in-vault symlink + new subdir"; fi
echo "PASS: rejects escape via in-vault symlink + not-yet-created subdir"

# 8. a file directly under the symlinked dir → rejected too
if guard "linkdir/escape.md"; then rm -rf "$OUTSIDE2"; fail "allowed escape via in-vault symlink (direct file)"; fi
rm -f "$VAULT/linkdir"; rm -rf "$OUTSIDE2"
echo "PASS: rejects escape via in-vault symlink (direct file)"

# 9. legit deep NEW subdir (no symlink) → still allowed (mkdir -p stays in-vault)
guard "wiki/a/b/c/deep.md" || fail "rejected a legit deep new subdir"
echo "PASS: allows a legit not-yet-created deep subdir"

# 10. LEAF symlink — the page path itself is a symlink pointing OUT → rejected.
#     (dirname strips the leaf, so this evades a parent-only check.)
OUT3=$(mktemp -d "/tmp/dream-guard-leaf-XXXXXX")
ln -s "$OUT3/escaped.md" "$VAULT/leaf-link.md"
if guard "leaf-link.md"; then rm -f "$VAULT/leaf-link.md"; rm -rf "$OUT3"; fail "allowed a symlinked leaf page target"; fi
rm -f "$VAULT/leaf-link.md"; rm -rf "$OUT3"
echo "PASS: rejects a symlinked leaf page target"

# 11. DANGLING middle symlink (target does not exist) + deeper new file → rejected.
#     The walk must stop at the symlink (not climb past it as a non-dir).
OUT4=$(mktemp -d "/tmp/dream-guard-dangle-XXXXXX"); rmdir "$OUT4"   # now dangling
ln -s "$OUT4" "$VAULT/dangle"
if guard "dangle/sub/x.md"; then rm -f "$VAULT/dangle"; fail "allowed a dangling middle symlink escape"; fi
rm -f "$VAULT/dangle"
echo "PASS: rejects a dangling middle symlink in the path"

echo
echo "All path-guard.sh tests passed."
