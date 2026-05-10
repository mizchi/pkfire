#!/usr/bin/env bash
# Smoke-test the remote cache protocol against a locally running worker.
# Assumes `pnpm dev` is already running on http://localhost:8787.

set -euo pipefail

BASE="${BASE:-http://localhost:8787}"
# Random hex64 so repeated smoke runs against a persistent dev R2 do not
# collide on a previous PUT.
KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
PAYLOAD="hello pkfire remote cache"

echo "==> HEAD before upload (expect 404)"
status=$(curl -s -o /dev/null -w '%{http_code}' -X HEAD "$BASE/v1/cas/$KEY")
[[ "$status" == "404" ]] || { echo "expected 404, got $status"; exit 1; }

echo "==> PUT (expect 201)"
status=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary "$PAYLOAD" "$BASE/v1/cas/$KEY")
[[ "$status" == "201" ]] || { echo "expected 201, got $status"; exit 1; }

echo "==> HEAD after upload (expect 200)"
status=$(curl -s -o /dev/null -w '%{http_code}' -X HEAD "$BASE/v1/cas/$KEY")
[[ "$status" == "200" ]] || { echo "expected 200, got $status"; exit 1; }

echo "==> GET (expect body match)"
got=$(curl -sf "$BASE/v1/cas/$KEY")
[[ "$got" == "$PAYLOAD" ]] || { echo "body mismatch: got=$got want=$PAYLOAD"; exit 1; }

echo "==> PUT again (expect 200, already present)"
status=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary "$PAYLOAD" "$BASE/v1/cas/$KEY")
[[ "$status" == "200" ]] || { echo "expected 200, got $status"; exit 1; }

echo "==> bad path (expect 404)"
status=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/cas/short")
[[ "$status" == "404" ]] || { echo "expected 404, got $status"; exit 1; }

echo "==> bad method (expect 405)"
status=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/v1/cas/$KEY")
[[ "$status" == "405" ]] || { echo "expected 405, got $status"; exit 1; }

# Scheduled GC (only available when wrangler dev was started with
# --test-scheduled). Skip if the dev server does not serve it.
echo "==> scheduled GC (best effort)"
status=$(curl -s -o /tmp/pkfire-gc.out -w '%{http_code}' "$BASE/__scheduled?cron=0+3+*+*+*")
if [[ "$status" == "200" ]]; then
  echo "    GC trigger succeeded"
else
  echo "    skipped (dev server returned $status; pass --test-scheduled to enable)"
fi

echo "all smoke checks passed"
