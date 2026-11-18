#!/usr/bin/env bash
# Deploy one agent definition end to end. Idempotent; safe to re-run.
#   build image (ACR Tasks) -> Foundry hosted agent version -> wait active
#   -> child agent identity under the blueprint -> smoke test.
# APIM onboarding needs no per-agent change: /agents/{name}/* is a wildcard route, and APIM's managed
# identity holds Foundry User at the Foundry account scope, which covers every agent endpoint.
# Inputs (env, see .env.example): AZURE_TENANT_ID AGENT_BLUEPRINT_APP_ID ACR_NAME AZURE_AI_PROJECT_ENDPOINT APIM_GATEWAY_URL SPONSOR_OBJECT_ID
set -euo pipefail
F=${1:?usage: deploy-agent.sh factory/agents/<name>.yaml}
y() { yq -r "$1" "$F"; }
NAME=$(y .name); SRC=$(y .source); CPU=$(y '.cpu // "0.5"'); MEM=$(y '.memory // "1Gi"'); PATTERN=$(y .authPattern)
TAG=${IMAGE_TAG:-${GITHUB_SHA:-local-$(date +%Y%m%d%H%M%S)}}; TAG=${TAG:0:20}
IMAGE="$ACR_NAME.azurecr.io/agents/$NAME:$TAG"
step() { echo "::group::$1"; START=$(date +%s); }
done_() { echo "::endgroup::"; echo "| $1 | $(( $(date +%s) - START ))s |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
echo "| Stage | Duration |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; echo "|---|---|" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

step "c1. build image $IMAGE"
if az acr manifest show -r "$ACR_NAME" -n "agents/$NAME:$TAG" -o none 2>/dev/null; then echo "image exists, skipping build"
else
  # --no-wait + poll for the pushed tag: `az acr build` can hang client-side after the run finishes,
  # and runs only report their output image once complete.
  az acr build -r "$ACR_NAME" -t "agents/$NAME:$TAG" --platform linux/amd64 "$SRC" --no-wait --only-show-errors -o none
  for i in $(seq 1 60); do az acr manifest show -r "$ACR_NAME" -n "agents/$NAME:$TAG" -o none 2>/dev/null && break; echo "waiting for image ($i)"; sleep 10; done
  az acr manifest show -r "$ACR_NAME" -n "agents/$NAME:$TAG" -o none 2>/dev/null || { echo "image build failed or timed out; see: az acr task list-runs -r $ACR_NAME --top 3"; exit 1; }
fi
done_ "build image"

step "c2. create hosted agent version"
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
BASE="$AZURE_AI_PROJECT_ENDPOINT"; AV=v1
ENVJSON=$(yq -o=json '(.env // {}) + {"PYTHONNOUSERSITE":"1","AUTH_PATTERN":"'"$PATTERN"'"}' "$F")
DEF=$(jq -n --arg img "$IMAGE" --arg cpu "$CPU" --arg mem "$MEM" --argjson env "$ENVJSON" \
  '{kind:"hosted",container_configuration:{image:$img},cpu:$cpu,memory:$mem,protocol_versions:[{protocol:"responses",version:"2.0.0"}],environment_variables:$env}')
code=$(curl -sS -o /tmp/agent.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/agents/$NAME?api-version=$AV")
if [ "$code" = 200 ]; then
  curl -sS --fail-with-body -X POST "$BASE/agents/$NAME/versions?api-version=$AV" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"definition\":$DEF}" -o /tmp/ver.json
  VER=$(jq -r .version /tmp/ver.json)
else
  curl -sS --fail-with-body -X POST "$BASE/agents?api-version=$AV" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"name\":\"$NAME\",\"definition\":$DEF}" -o /tmp/ver.json
  VER=$(jq -r '.versions.latest.version // .version // "1"' /tmp/ver.json)
fi
echo "version=$VER"
for i in $(seq 1 60); do
  ST=$(curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/agents/$NAME/versions/$VER?api-version=$AV" | jq -r '.status')
  echo "status=$ST"; [ "$ST" = active ] && break
  [ "$ST" = failed ] && { curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/agents/$NAME/versions/$VER?api-version=$AV" | jq '.error'; exit 1; }
  sleep 10
done
[ "$ST" = active ] || { echo "timed out waiting for active"; exit 1; }
done_ "deploy agent version $VER"

step "e. child agent identity under the blueprint"
G=https://graph.microsoft.com
CHILD=$(az rest --resource $G --url "$G/beta/servicePrincipals?\$filter=displayName eq '$NAME'&\$select=appId,agentIdentityBlueprintId" -o json | jq -r --arg bp "$AGENT_BLUEPRINT_APP_ID" '[.value[] | select(.agentIdentityBlueprintId==$bp)][0].appId // empty')
if [ -z "$CHILD" ]; then
  # App-only creation needs Graph application permission AgentIdentity.Create.All on the deployer (admin grant).
  CHILD=$(az rest --method post --resource $G --url "$G/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" --headers "Content-Type=application/json" "OData-Version=4.0" \
    --body "{\"displayName\":\"$NAME\",\"agentIdentityBlueprintId\":\"$AGENT_BLUEPRINT_APP_ID\",\"sponsors@odata.bind\":[\"$G/v1.0/users/$SPONSOR_OBJECT_ID\"]}" --query appId -o tsv 2>/tmp/child.err) || {
    echo "::warning title=Child identity not minted::$(head -c 300 /tmp/child.err). Grant AgentIdentity.Create.All to the deployer or mint it manually."; CHILD="(not minted)"; }
fi
echo "child agent identity appId=$CHILD"; echo "| child identity | $CHILD |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
done_ "mint child identity"

step "h. smoke test"
OUT=$(curl -sS --fail-with-body -X POST "$BASE/agents/$NAME/endpoint/protocols/openai/responses?api-version=$AV" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"input":"factory smoke test","stream":false}' | jq -r '.output_text // ([.output[]?.content[]?.text] | join(" "))')
echo "direct: $OUT"
APIM_NOAUTH=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$APIM_GATEWAY_URL/agents/$NAME/openai/responses" || echo timeout)
echo "apim without token: $APIM_NOAUTH (expect 401)"
[ "$APIM_NOAUTH" = 401 ] || { echo "APIM did not reject an unauthenticated call"; exit 1; }
{ echo "### $NAME v$VER"; echo "- image: \`$IMAGE\`"; echo "- direct invoke: ${OUT:0:300}"; echo "- APIM unauthenticated: $APIM_NOAUTH"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "SMOKE_RESULT=$NAME v$VER ok: ${OUT:0:200}" >> "${GITHUB_OUTPUT:-/dev/null}"
done_ "smoke test"
