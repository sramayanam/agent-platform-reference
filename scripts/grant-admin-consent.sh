#!/usr/bin/env bash
# Tenant-wide (AllPrincipals) delegated consent grants. Needs Privileged Role Administrator + Cloud Application
# Administrator, or Global Administrator. Idempotent: an existing grant is updated to the given scopes.
#   1. Blueprint principal -> Microsoft Graph: $GRAPH_DELEGATED_SCOPES   (inherited by every agent identity for OBO)
#   2. Bot app             -> blueprint: agent.invoke                    (Teams SSO token for the blueprint)
#   3. Bot app             -> Microsoft Graph: openid profile offline_access User.Read
#   4. Test client (optional, TEST_CLIENT_ID) -> blueprint: agent.invoke
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; source .env; set +a
G=https://graph.microsoft.com
sp() { az ad sp show --id "$1" --query id -o tsv; }
GSP=$(sp 00000003-0000-0000-c000-000000000000)
grant() { # client-sp resource-sp scopes
  local ex; ex=$(az rest --resource $G --url "$G/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$1' and resourceId eq '$2'" --query "value[0].id" -o tsv)
  if [ -n "$ex" ]; then
    az rest --method patch --resource $G --url "$G/v1.0/oauth2PermissionGrants/$ex" --headers "Content-Type=application/json" --body "{\"scope\":\"$3\"}" && echo "updated: $3"
  else
    az rest --method post --resource $G --url "$G/v1.0/oauth2PermissionGrants" --headers "Content-Type=application/json" \
      --body "{\"clientId\":\"$1\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$2\",\"scope\":\"$3\"}" --query scope -o tsv
  fi; }
grant "$AGENT_BLUEPRINT_SP_OBJECT_ID" "$GSP" "$GRAPH_DELEGATED_SCOPES"
BOT_SP=$(sp "$BOT_APP_ID")
grant "$BOT_SP" "$AGENT_BLUEPRINT_SP_OBJECT_ID" "agent.invoke"
grant "$BOT_SP" "$GSP" "openid profile offline_access User.Read"
if [ -n "${TEST_CLIENT_ID:-}" ] && [[ "$TEST_CLIENT_ID" != \<* ]]; then grant "$(sp "$TEST_CLIENT_ID")" "$AGENT_BLUEPRINT_SP_OBJECT_ID" "agent.invoke"; fi
echo "done"
