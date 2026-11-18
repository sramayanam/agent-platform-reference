#!/usr/bin/env bash
# Watch the agent-obo fragment run, step by step, with APIM request tracing.
#   1. Device-code sign-in with a test public client (TEST_CLIENT_ID, consented for agent.invoke).
#   2. Short-lived APIM debug credential (gateways/managed/listDebugCredentials, 1 hour). Needs ARM access to APIM.
#   3. One call to /agents/<agent>/openai/responses with Apim-Debug-Authorization.
#   4. Fetch the trace; print the policy steps; save every JWT seen in the flow to OUT_DIR as *.jwt
#      (user token, managed identity token, T1, Graph token) so you can inspect them at https://jwt.ms.
# Tokens are not printed. They are short-lived; delete .trace-obo/ when done.
# Every run skips the OBO cache (x-obo-nocache: 1, honoured only on traced requests). NOCACHE=0 shows the cache-hit path.
# Token names follow https://learn.microsoft.com/entra/agent-id/agent-on-behalf-of-oauth-flow :
#   Tc (user token, aud = blueprint) -> TUAMI (managed identity token) -> T1 (blueprint + fmi_path) -> TR (resource token)
# Usage: scripts/trace-obo.sh [agent] [input]
# Reads .env: AZURE_TENANT_ID TEST_CLIENT_ID AGENT_BLUEPRINT_APP_ID APIM_RESOURCE_ID APIM_DIRECT_URL APIM_SUBSCRIPTION_NAME
#   APIM_DIRECT_URL: run from a machine that can reach APIM directly (inside the VNet), since the debug call bypasses Front Door.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; source .env; set +a

MODE=byo
AGENT=${1:-graph-profile-agent}
INPUT=${2:-me}
TENANT=$AZURE_TENANT_ID
CLIENT=$TEST_CLIENT_ID
SCOPE="api://$AGENT_BLUEPRINT_APP_ID/agent.invoke"
APIM=$APIM_DIRECT_URL
SVC="https://management.azure.com$APIM_RESOURCE_ID"
PV=api-version=2023-05-01-preview
SVC_ID=$APIM_RESOURCE_ID
OUT_DIR=${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.trace-obo/$MODE-$AGENT}; umask 077; mkdir -p "$OUT_DIR"   # .trace-obo is gitignored
AUTH=https://login.microsoftonline.com/$TENANT/oauth2/v2.0
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }

# 1. Sign in (reuses a still-valid token in OUT_DIR for the same audience)
valid() { [ -s "$OUT_DIR/0-user-token.jwt" ] && python3 - "$OUT_DIR/0-user-token.jwt" "$SCOPE" <<'PY'
import sys,json,base64,time
p=open(sys.argv[1]).read().strip().split(".")[1]; p+="="*(-len(p)%4); c=json.loads(base64.urlsafe_b64decode(p))
aud=sys.argv[2].split("/")[2]
sys.exit(0 if c.get("exp",0)-time.time()>300 and str(c.get("aud","")).endswith(aud) else 1)
PY
}
if valid; then echo "Reusing signed-in token from $OUT_DIR"; else
dc=$(curl -s "$AUTH/devicecode" -d "client_id=$CLIENT" --data-urlencode "scope=$SCOPE")
echo "$dc" | jget message
device_code=$(echo "$dc" | jget device_code); interval=$(echo "$dc" | jget interval)
while :; do
  sleep "$interval"
  tok=$(curl -s "$AUTH/token" -d "client_id=$CLIENT" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "device_code=$device_code")
  err=$(echo "$tok" | jget error)
  [ -z "$err" ] && break
  [ "$err" = "authorization_pending" ] || { echo "sign-in failed: $err"; exit 1; }
done
echo "$tok" | jget access_token > "$OUT_DIR/0-user-token.jwt"; cp "$OUT_DIR/0-user-token.jwt" "$OUT_DIR/1-Tc-user-token.jwt"
echo "Signed in."
fi
python3 - "$OUT_DIR/0-user-token.jwt" "$CLIENT" <<'PY'
import sys,json,base64; p=open(sys.argv[1]).read().strip().split(".")[1]; p+="="*(-len(p)%4); c=json.loads(base64.urlsafe_b64decode(p))
print(f"\nSTEP 0  Client {sys.argv[2]} signed you in and got token #1 = Tc (user token)")
for k in ("aud","azp","scp","oid","name"): print(f"        {k:6} = {c.get(k)}")
PY

find "$OUT_DIR" -name '[2-9]-*.jwt' -delete   # drop tokens from earlier runs; keep the user token
cp "$OUT_DIR/0-user-token.jwt" "$OUT_DIR/1-Tc-user-token.jwt"

# 2. Debug credential for the agents API, 3. traced call
DBG=$(az rest -m POST -u "$SVC/gateways/managed/listDebugCredentials?$PV" \
  --body "{\"credentialsExpireAfter\":\"PT1H\",\"apiId\":\"$SVC_ID/apis/agents\",\"purposes\":[\"tracing\"]}" --query token -o tsv)
KEY=$(az rest -m POST -u "$SVC/subscriptions/${APIM_SUBSCRIPTION_NAME:-agents-bot}/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv)
BODY=$(INPUT_TEXT="$INPUT" python3 -c 'import json,os; print(json.dumps(dict(input=os.environ["INPUT_TEXT"], stream=False)))')
curl -s -D "$OUT_DIR/resp-headers.txt" -o "$OUT_DIR/resp-body.json" -X POST "$APIM/agents/$AGENT/openai/responses?api-version=v1" \
  -H "Authorization: Bearer $(cat "$OUT_DIR/0-user-token.jwt")" -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "Apim-Debug-Authorization: $DBG" -H "x-obo-nocache: ${NOCACHE:-1}" -H "Content-Type: application/json" -d "$BODY"
STATUS=$(head -1 "$OUT_DIR/resp-headers.txt" | awk '{print $2}')
TRACE_ID=$(grep -i '^apim-trace-id:' "$OUT_DIR/resp-headers.txt" | awk '{print $2}' | tr -d '\r')
echo "HTTP $STATUS   trace id: ${TRACE_ID:-<none>}"
[ -n "$TRACE_ID" ] || { echo "no trace id returned"; exit 1; }

# 4. Fetch trace and tell the story
az rest -m POST -u "$SVC/gateways/managed/listTrace?$PV" --body "{\"traceId\":\"$TRACE_ID\"}" -o json > "$OUT_DIR/trace.json"
python3 - "$OUT_DIR" "$STATUS" <<'EOF' | tee "$OUT_DIR/report.md"
import json, re, sys, base64, os, urllib.parse
out, status = sys.argv[1], sys.argv[2]
entries = json.load(open(os.path.join(out, "trace.json"))).get("traceEntries", {})
jwt_re = re.compile(r"eyJ[\w-]+\.eyJ[\w-]+\.[\w-]*")
def claims(t):
    p = t.split(".")[1]; p += "=" * (-len(p) % 4); return json.loads(base64.urlsafe_b64decode(p))

tokens = {}                                     # token -> number
user = open(os.path.join(out, "0-user-token.jwt")).read().strip(); tokens[user] = 1
names = {1: "Tc-user-token"}
def name_for(c):
    aud = str(c.get("aud", ""))
    if c.get("xms_mirid"): return "TUAMI-uami-token"
    if c.get("idtyp") == "app" and c.get("azp") and "graph" not in aud and "ai.azure.com" not in aud: return "T1-blueprint-exchange-token"
    if "graph.microsoft.com" in aud or aud == "00000003-0000-0000-c000-000000000000": return "TR-resource-graph-token"
    if "ai.azure.com" in aud: return "apim-sami-to-foundry-token"
    return "other-token"
def ref(t):
    if t not in tokens:
        n = len(tokens) + 1; tokens[t] = n; names[n] = name_for(claims(t))
        open(os.path.join(out, f"{n}-{names[n]}.jwt"), "w").write(t)
        c = claims(t)
        print(f"        -> token #{n} ({names[n]}): " + ", ".join(f"{k}={c[k]}" for k in ("aud","azp","appid","sub","oid","idtyp","scp","upn") if k in c))
    return f"<token #{tokens[t]}>"
def tok(s): return jwt_re.sub(lambda m: ref(m.group(0)), s)

step = 0
def say(msg): print(msg)
print(f"\n# APIM trace  (HTTP {status})\n")
for section in ("inbound", "backend", "outbound", "on-error"):
    items = entries.get(section) or []
    if not items: continue
    print(f"\n## {section}")
    for e in items:
        src, d = e.get("source", ""), e.get("data", "")
        t = e.get("elapsed", "")[3:11]
        if src == "include-fragment": say(f"[{t}] ---- {d} ----"); continue
        if not isinstance(d, dict):
            if src in ("validate-jwt",): say(f"[{t}] {src}: {d}")
            continue
        if src == "validate-jwt" and "message" in d: say(f"[{t}] validate-jwt: {d['message']}")
        elif src == "set-variable" and "name" in d:
            v = d.get("value"); v = json.dumps(v) if isinstance(v, (dict, list)) else str(v)
            say(f"[{t}] set-variable  {d['name']} = {tok(v)[:140]}")
        elif src == "choose": say(f"[{t}] choose  when {d.get('expression','').strip()}  =>  {d.get('value')}")
        elif src == "cache-lookup-value" and "key" in d: say(f"[{t}] cache-lookup  {d['key']}  =>  {'HIT' if 'hit' in d.get('message','') else 'MISS'}")
        elif src == "cache-store-value" and "key" in d: say(f"[{t}] cache-store   {d['key']}  for {d.get('timeout')}")
        elif src == "authentication-managed-identity" and "added" in d.get("message", ""):
            say(f"[{t}] authentication-managed-identity: {d['message']}")
        elif src == "set-body" and "value" in d and "client_id=" in str(d["value"]):
            form = urllib.parse.parse_qs(str(d["value"]))
            say(f"[{t}] send-request  POST login.microsoftonline.com/.../token  form:")
            for k in ("client_id", "scope", "grant_type", "fmi_path", "requested_token_use", "client_assertion", "assertion"):
                if k in form: say(f"          {k:20} = {tok(form[k][0])}")
        elif src == "send-request" and "response" in d:
            r = d["response"]; b = r.get("body") or ""
            b = b if isinstance(b, str) else json.dumps(b)
            say(f"[{t}] send-request  response {r.get('status', {}).get('code', '')}")
            for m in jwt_re.findall(b): ref(m)
        elif src == "set-header" and "header" in d:
            h = d["header"]; say(f"[{t}] set-header  {h['name']}: {tok(str(h['value']))[:100]}")
        elif src == "request-forwarder" and section == "backend":
            r = d.get("request", {}); say(f"[{t}] forward to {r.get('url','')[:110]}")
            for h in r.get("headers", []):
                if h["name"].lower() in ("authorization", "x-client-graph-token", "x-client-user-assertion"):
                    say(f"          {h['name']}: {tok(str(h['value']).replace('Bearer ', 'Bearer '))[:100]}")
        elif src == "forward-request" and "response" in d: say(f"[{t}] Foundry responded {d['response'].get('status', {}).get('code', '')}")
        elif src == "return-response": say(f"[{t}] return-response {json.dumps(d)[:120]}")

print("\n## tokens (paste into https://jwt.ms with:  pbcopy < <file>)")
for n in sorted(names): print(f"  {out}/{n}-{names[n]}.jwt")
EOF
echo; echo "Response body: $OUT_DIR/resp-body.json"
echo "Copy a token:  pbcopy < <file>.jwt   then paste into https://jwt.ms"
