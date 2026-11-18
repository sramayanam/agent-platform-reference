#!/usr/bin/env bash
# Call the plugin's MCP server the way Copilot Cowork does, from your terminal.
# Signs you in with device code using a public client app registration that is consented for
# api://<blueprint>/agent.invoke (a test client; no secret), then runs MCP initialize -> tools/list -> tools/call ask_agent.
#
# Usage: scripts/test-mcp.sh [agent] [input]       (reads .env: AZURE_TENANT_ID, TEST_CLIENT_ID, AGENT_BLUEPRINT_APP_ID, MCP_SERVER_URL)
#   scripts/test-mcp.sh graph-profile-agent me
# The token is kept in memory only and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; source .env; set +a

TENANT=$AZURE_TENANT_ID
CLIENT=$TEST_CLIENT_ID
SCOPE="api://$AGENT_BLUEPRINT_APP_ID/agent.invoke"
MCP=$MCP_SERVER_URL
AGENT=${1:-graph-profile-agent}
INPUT=${2:-me}
AUTH=https://login.microsoftonline.com/$TENANT/oauth2/v2.0

json() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

# 1. Device code sign-in
dc=$(curl -s "$AUTH/devicecode" -d "client_id=$CLIENT" --data-urlencode "scope=$SCOPE")
echo "$dc" | json "['message']"
device_code=$(echo "$dc" | json "['device_code']")
interval=$(echo "$dc" | json "['interval']")
while :; do
  sleep "$interval"
  tok=$(curl -s "$AUTH/token" -d "client_id=$CLIENT" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "device_code=$device_code")
  err=$(echo "$tok" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))")
  [ -z "$err" ] && break
  [ "$err" = "authorization_pending" ] || { echo "sign-in failed: $err"; exit 1; }
done
TOKEN=$(echo "$tok" | json "['access_token']")
echo "Signed in. Token claims:"
echo "$TOKEN" | cut -d. -f2 | python3 -c "
import sys,json,base64; p=sys.stdin.read().strip(); p+='='*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p)); print({k:c.get(k) for k in ('aud','azp','scp','upn')})"

# 2. MCP calls. Responses may come back as JSON or as server-sent events ("data: {...}").
SESSION=""
mcp() {
  local hdrs; hdrs=$(mktemp)
  local body
  body=$(curl -s -D "$hdrs" "$MCP" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${SESSION:+-H "Mcp-Session-Id: $SESSION"} \
    -d "$1")
  local status; status=$(head -1 "$hdrs" | awk '{print $2}')
  local sid; sid=$(grep -i '^mcp-session-id:' "$hdrs" | awk '{print $2}' | tr -d '\r' || true)
  [ -n "$sid" ] && SESSION=$sid
  rm -f "$hdrs"
  echo "HTTP $status"
  echo "$body" | sed -n 's/^data: //p' | grep . || echo "$body"
}

echo; echo "== initialize"
mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}'
mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

echo; echo "== tools/list"
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

echo; echo "== tools/call ask_agent agent=$AGENT input=$INPUT"
args=$(python3 -c "import json,sys; print(json.dumps({'agent':sys.argv[1],'input':sys.argv[2]}))" "$AGENT" "$INPUT")
mcp "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask_agent\",\"arguments\":$args}}"
