#!/bin/bash
# Test A2A Relay endpoints
# Usage: ./test-relay.sh [dev|prod]

set -e

ENV="${1:-dev}"
SECRET="${RELAY_JWT_SECRET:?Set RELAY_JWT_SECRET environment variable}"

if [[ "$ENV" == "prod" ]]; then
  URL="https://a2a-relay-prod-442090395636.us-central1.run.app"
  # Note: prod secret is different, must be set via env var
else
  URL="https://a2a-relay-dev-442090395636.us-central1.run.app"
fi

echo "Testing A2A Relay at: $URL"
echo ""

# Generate test JWTs
generate_jwt() {
  local payload="$1"
  local header='{"alg":"HS256","typ":"JWT"}'
  
  local h=$(echo -n "$header" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  local p=$(echo -n "$payload" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  local sig=$(echo -n "${h}.${p}" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')
  
  echo "${h}.${p}.${sig}"
}

# Client token for test-tenant
CLIENT_JWT=$(generate_jwt '{"sub":"client:test-tenant:alan","tenant":"test-tenant","user_id":"alan","role":"client","scopes":["message:send","tasks:read"],"iat":1739581200,"exp":1839581200}')

# Agent token for test-tenant
AGENT_JWT=$(generate_jwt '{"sub":"agent:test-tenant:test-agent","tenant":"test-tenant","agent_id":"test-agent","role":"agent","iat":1739581200,"exp":1839581200}')

echo "=== Test 1: Health Check (no auth needed) ==="
curl -s "$URL/health"
echo ""

echo ""
echo "=== Test 2: Root Endpoint ==="
curl -s "$URL/"
echo ""

echo ""
echo "=== Test 3: List Agents (empty tenant) ==="
RESULT=$(curl -s -H "Authorization: Bearer $CLIENT_JWT" "$URL/t/test-tenant/agents")
echo "$RESULT"
if [[ "$RESULT" == "[]" || "$RESULT" == "null" ]]; then
  echo "✅ Correct: no agents connected"
else
  echo "⚠️  Unexpected response"
fi

echo ""
echo "=== Test 4: Send to offline agent ==="
RESULT=$(curl -s -X POST \
  -H "Authorization: Bearer $CLIENT_JWT" \
  -H "Content-Type: application/json" \
  -d '{"message":{"role":"user","parts":[{"text":"hello"}]}}' \
  "$URL/t/test-tenant/a2a/fake-agent/message/send")
echo "$RESULT"
if echo "$RESULT" | grep -q "agent_offline"; then
  echo "✅ Correct: agent offline error"
else
  echo "⚠️  Unexpected response"
fi

echo ""
echo "=== Test 5: Tenant mismatch (should fail) ==="
WRONG_TENANT_JWT=$(generate_jwt '{"sub":"client:other-tenant:bob","tenant":"other-tenant","user_id":"bob","role":"client","iat":1739581200,"exp":1839581200}')
RESULT=$(curl -s -H "Authorization: Bearer $WRONG_TENANT_JWT" "$URL/t/test-tenant/agents")
echo "$RESULT"
if echo "$RESULT" | grep -q "tenant mismatch\|forbidden"; then
  echo "✅ Correct: tenant mismatch rejected"
else
  echo "⚠️  Unexpected response"
fi

echo ""
echo "=== Test 6: Invalid token ==="
RESULT=$(curl -s -H "Authorization: Bearer invalid.token.here" "$URL/t/test-tenant/agents")
echo "$RESULT"
if echo "$RESULT" | grep -q "invalid token"; then
  echo "✅ Correct: invalid token rejected"
else
  echo "⚠️  Unexpected response"
fi

echo ""
echo "=== Summary ==="
echo "JWT tokens generated with secret: ${SECRET:0:10}..."
echo "Client JWT: ${CLIENT_JWT:0:50}..."
echo "Agent JWT: ${AGENT_JWT:0:50}..."
echo ""
echo "To test WebSocket agent connection, you'll need a client that can:"
echo "1. Connect to wss://$URL/agent"
echo "2. Send auth message with agent JWT and agent_card"
echo "3. Handle incoming a2a.request messages"
