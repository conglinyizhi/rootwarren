#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PORT=${PORT:-18001}
ADMIN_TOKEN=${ADMIN_TOKEN:-mbt-mdwiki-demo-admin-token}
BASE_URL="http://127.0.0.1:${PORT}"
COOKIE_JAR=$(mktemp)
LOG_FILE=$(mktemp)
DOC_SLUG="demo/session-$$"
KEY_NAME="demo-$$"
SERVER_PID=""
KEY_ID=""

cleanup() {
  if [[ -n "$KEY_ID" ]]; then
    curl -fsS -b "$COOKIE_JAR" -d "id=$KEY_ID" "$BASE_URL/admin/keys/revoke" >/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$COOKIE_JAR" "$LOG_FILE"
  rm -f "$ROOT/content/$DOC_SLUG.md"
}
trap cleanup EXIT

cd "$ROOT"
ADMIN_TOKEN="$ADMIN_TOKEN" PORT="$PORT" make run >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS "$BASE_URL/health" >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS "$BASE_URL/health" >/dev/null

curl -fsS -c "$COOKIE_JAR" \
  -d "token=$ADMIN_TOKEN" \
  "$BASE_URL/admin/login" >/dev/null

created=$(curl -fsS -b "$COOKIE_JAR" \
  -d "name=$KEY_NAME&scopes=read,write" \
  "$BASE_URL/admin/keys")
API_KEY=$(printf '%s' "$created" | sed -n 's/.*created key: \(mk_[A-Za-z0-9]*\).*/\1/p')
if [[ -z "$API_KEY" ]]; then
  echo "Could not extract demo API key; server log follows:" >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

keys_page=$(curl -fsS -b "$COOKIE_JAR" "$BASE_URL/admin/keys")
KEY_ID=$(printf '%s' "$keys_page" | sed -n "s/.*<li>#\([0-9][0-9]*\) $KEY_NAME .*/\1/p")
if [[ -z "$KEY_ID" ]]; then
  echo "Could not find the demo key id" >&2
  exit 1
fi

auth=(-H "Authorization: Bearer $API_KEY")

echo "== Health =="
curl -fsS "$BASE_URL/health"
echo

echo "== Create document =="
curl -fsS -X PUT "${auth[@]}" \
  --data-binary $'# Demo\n\nCreated by scripts/demo.sh.\n' \
  "$BASE_URL/api/v1/docs/$DOC_SLUG"
echo

echo "== Search =="
curl -fsS "$BASE_URL/api/v1/search?q=Created" "${auth[@]}"
echo

echo "== Read document =="
curl -fsS "${auth[@]}" "$BASE_URL/api/v1/docs/$DOC_SLUG"
echo

echo "== Delete document =="
curl -fsS -X DELETE "${auth[@]}" "$BASE_URL/api/v1/docs/$DOC_SLUG"
echo

echo "Demo complete. The temporary document and API key will be cleaned up."
