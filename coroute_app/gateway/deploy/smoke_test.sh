#!/usr/bin/env bash
# Quick end-to-end check against a running gateway. Usage: ./smoke_test.sh https://api.example.com
set -euo pipefail
BASE="${1:-http://127.0.0.1:3000}"
echo "health:";  curl -fsS "$BASE/api/health"; echo
EMAIL="smoke_$(date +%s)@coroute.test"
echo "register:"; TOKEN=$(curl -fsS -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Smoke Rider\",\"email\":\"$EMAIL\",\"password\":\"Password#123\",\"phone\":\"9999999999\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "token ok (${#TOKEN} chars)"
echo "create convoy:"; curl -fsS -X POST "$BASE/api/convoys" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Smoke convoy"}'; echo
echo "active:"; curl -fsS "$BASE/api/convoys/active" -H "Authorization: Bearer $TOKEN"; echo
echo "OK"
