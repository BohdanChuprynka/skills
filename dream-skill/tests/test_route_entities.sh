#!/usr/bin/env bash
# test_route_entities.sh — deterministic person pre-routing (route-entities.py).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/personal/wiki" "$TMP/professional/wiki/people"

# Alex appears on both rosters to exercise the configurable preferred-vault
# tie-break. Riley is present only on the personal roster.
cat > "$TMP/personal/wiki/People.md" <<'MD'
# People

## Community

- **Alex Morgan** — collaborator.
- **Riley Quinn** — advisor.
MD

cat > "$TMP/professional/wiki/people/people.md" <<'MD'
# People

| Name | Role |
|---|---|
| **Alex Morgan** | collaborator |
MD

# A non-roster page inside people/ must never be indexed.
cat > "$TMP/professional/wiki/people/prep-notes.md" <<'MD'
# Call prep notes

- **Jordan Draft** — prep-only note.
MD

cat > "$TMP/config.toml" <<EOF
[vaults.personal]
root = "$TMP/personal"
description = "Identity and relationships"

[vaults.professional]
root = "$TMP/professional"
description = "Professional context"

[entity_routing]
preferred_vault = "personal"
stop_terms = ["Example Platform"]
EOF

cat > "$TMP/candidates.json" <<'JSON'
[
  {"content":"Alex Morgan, a collaborator, contributes to the work.","confidence":"high","source_chat":"chat-a","source_date":"2026-07-01","memory_tier":"stable"},
  {"content":"Riley Quinn: experienced advisor for the project.","confidence":"high","source_chat":"chat-b","source_date":"2026-07-02","memory_tier":"stable"},
  {"content":"Next project: Riley Quinn may assign a task.","confidence":"high","source_chat":"chat-c","source_date":"2026-07-03","memory_tier":"stable"},
  {"content":"Jordan Draft leads the call prep.","confidence":"high","source_chat":"chat-d","source_date":"2026-07-04","memory_tier":"stable"},
  {"content":"Taylor Park mentioned a new project idea.","confidence":"high","source_chat":"chat-e","source_date":"2026-07-05","memory_tier":"stable"},
  {"content":"Implementing Example Platform connector for notes.","confidence":"high","source_chat":"chat-f","source_date":"2026-07-06","memory_tier":"stable"},
  {"content":"Riley Quinn's team uses a data warehouse.","confidence":"high","source_chat":"chat-g","source_date":"2026-07-07","memory_tier":"stable"},
  {"content":"The user prefers concise written reports.","confidence":"high","source_chat":"chat-h","source_date":"2026-07-08","memory_tier":"stable"}
]
JSON

"$SCRIPTS/route-entities.py" --config "$TMP/config.toml" --report \
  < "$TMP/candidates.json" > "$TMP/out.json" 2> "$TMP/report.txt"

pr_for() { jq -c --arg c "$1" '.pre_routed[] | select(.candidate.content == $c)' "$TMP/out.json"; }
np_for() { jq -c --arg c "$1" '.new_person[] | select(.candidate.content == $c)' "$TMP/out.json"; }
rm_for() { jq -c --arg c "$1" '.remaining[] | select(.content == $c)' "$TMP/out.json"; }

# Configured tie-break: Alex is in both rosters, so personal wins.
A="Alex Morgan, a collaborator, contributes to the work."
pr_for "$A" | jq -e '.route.vault == "personal" and .route.page == "wiki/People.md" and .route.section == "Community"' >/dev/null

# A subject fact about a known person pre-routes to that person's roster.
R="Riley Quinn: experienced advisor for the project."
pr_for "$R" | jq -e '.route.vault == "personal" and .route.page == "wiki/People.md"' >/dev/null

# Mid-sentence mention must not hijack a non-person fact.
N="Next project: Riley Quinn may assign a task."
[ -z "$(pr_for "$N")" ] && [ -z "$(np_for "$N")" ] && [ -n "$(rm_for "$N")" ]

# A name found only in a non-roster file remains an unknown-person review item.
J="Jordan Draft leads the call prep."
[ -z "$(pr_for "$J")" ]
np_for "$J" | jq -e '.detected_names | index("Jordan Draft") != null' >/dev/null

# A genuine unknown person is retained for review.
T="Taylor Park mentioned a new project idea."
np_for "$T" | jq -e '.detected_names | index("Taylor Park") != null' >/dev/null

# Gerunds, possessives, and ordinary preferences stay with normal routing.
I="Implementing Example Platform connector for notes."
P="Riley Quinn's team uses a data warehouse."
U="The user prefers concise written reports."
for value in "$I" "$P" "$U"; do
  [ -z "$(pr_for "$value")" ] && [ -z "$(np_for "$value")" ] && [ -n "$(rm_for "$value")" ]
done

[ "$(jq '.pre_routed | length' "$TMP/out.json")" = "2" ]
[ "$(jq '.new_person | length' "$TMP/out.json")" = "2" ]
[ "$(jq '.remaining | length' "$TMP/out.json")" = "4" ]
grep -q '^route-entities: in=8 pre_routed=2 new_person=2 remaining=4$' "$TMP/report.txt"

# Pre-routed records remain compatible with reconciliation.
pr_for "$R" | jq -s '.' > "$TMP/pre_routed_record.json"
"$SCRIPTS/build-reconcile-batches.py" --config "$TMP/config.toml" --run-date 2026-07-10 \
  < "$TMP/pre_routed_record.json" > "$TMP/reconcile-batches.json"
jq -e 'length == 1 and .[0].target.vault == "personal" and .[0].target.page == "wiki/People.md"' \
  "$TMP/reconcile-batches.json" >/dev/null

echo "test_route_entities: ok"
