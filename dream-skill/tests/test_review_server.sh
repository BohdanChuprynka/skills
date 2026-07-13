#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/queue.json" <<'JSON'
{"entries":[{"id":"c-test","context":"A fact"}]}
JSON
PORT=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)

python3 "$SKILL_DIR/scripts/serve-review.py" \
  --queue "$TMP/queue.json" --decisions "$TMP/decisions.json" \
  --feedback "$TMP/feedback.json" \
  --port "$PORT" --no-browser > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  rg -q 'token=' "$TMP/server.log" && break
  sleep 0.05
done
TOKEN=$(sed -n 's/^.*token=\([^ ]*\)$/\1/p' "$TMP/server.log" | head -n 1)
[ -n "$TOKEN" ]

BASE="http://localhost:$PORT"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/api/queue")" = "403" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: attacker.invalid' "$BASE/api/queue?token=$TOKEN")" = "403" ]
curl -fsS "$BASE/api/queue?token=$TOKEN" | jq -e '.entries[0].id == "c-test"' >/dev/null
curl -fsS -X POST -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"c-test","decision":"approve"}' "$BASE/api/decide" | jq -e '.ok' >/dev/null
jq -e '."c-test" == "approve"' "$TMP/decisions.json" >/dev/null
jq -e '."c-test".decision == "approve" and ."c-test".reason == "accepted"' "$TMP/feedback.json" >/dev/null
[ "$(stat -c '%a' "$TMP/decisions.json" 2>/dev/null || stat -f '%Lp' "$TMP/decisions.json")" = "600" ]
[ "$(stat -c '%a' "$TMP/feedback.json" 2>/dev/null || stat -f '%Lp' "$TMP/feedback.json")" = "600" ]
curl -fsS -X POST -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"c-reject","decision":"reject","reason":"not_durable"}' "$BASE/api/decide" | jq -e '.ok' >/dev/null
jq -e '."c-reject".decision == "reject" and ."c-reject".reason == "not_durable"' "$TMP/feedback.json" >/dev/null
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"id":"bad","decision":"reject","reason":"invented"}' "$BASE/api/decide")" = "400" ]

# A persistence failure is an explicit 500 contract, and cannot mutate the
# authoritative decisions file. The UI relies on this response to keep the card.
rm "$TMP/feedback.json"
mkdir "$TMP/feedback.json"
FAIL_STATUS=$(curl -sS -o "$TMP/failure.json" -w '%{http_code}' -X POST \
  -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"c-persist-fail","decision":"approve","reason":"accepted"}' "$BASE/api/decide")
[ "$FAIL_STATUS" = "500" ]
jq -e '.ok == false and .error == "review decision could not be persisted"' "$TMP/failure.json" >/dev/null
jq -e 'has("c-persist-fail") | not' "$TMP/decisions.json" >/dev/null

curl -fsS -X POST -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{}' "$BASE/api/shutdown" | jq -e '.ok' >/dev/null
wait "$SERVER_PID"
SERVER_PID=""

echo "test_review_server: ok"
