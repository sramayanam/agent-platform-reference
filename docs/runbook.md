# Runbook

Your account needs **Foundry Project Manager** (project) and **Foundry User** (account) for agent operations; Owner alone has no Foundry data permissions.

## Onboard a new agent
1. Copy `agents/graph-profile-agent/` to `agents/<name>/` and change the code. The container must serve the Responses protocol on port 8088. Read the user's Graph token from the `x-client-graph-token` header.
2. Copy `factory/agents/graph-profile-agent.yaml` to `factory/agents/<name>.yaml`; set `name`, `source`, `authPattern`, `owners`. The file name must equal `name`.
3. Review and merge, then publish:
   ```bash
   set -a; source .env; set +a
   python3 factory/scripts/validate.py
   ./factory/scripts/deploy-agent.sh factory/agents/<name>.yaml
   ```
   The script builds the image, creates an agent version, waits for `active`, creates the agent identity under the blueprint, and smoke-tests (APIM must reject an unauthenticated call).
4. Add `<name>=<agent identity appId>` to the APIM named value `agent-child-ids`. No other APIM, bot or plugin change is needed: routes and the `ask_agent` tool select agents by name. In Teams, users switch with `/agent <name>`.

## Rotate the blueprint credential
1. Create a new user-assigned managed identity.
2. Add a second federated credential on the blueprint for it (subject = new principal ID, audience `api://AzureADTokenExchange`).
3. Attach it to APIM and update the named value `blueprint-uami-client-id`.
4. Verify a call, then remove the old federated credential and identity.
The blueprint, agent identities and consents are unaffected. The bot's identity rotates the same way (update `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__FEDERATEDCLIENTID`); leave the Bot Service token store federated credential in place.

## Decommission an agent
1. Remove `factory/agents/<name>.yaml` and `agents/<name>/`.
2. Delete the Foundry agent: `DELETE {project endpoint}/agents/<name>?api-version=v1`.
3. Delete its agent identity: `DELETE https://graph.microsoft.com/beta/servicePrincipals/<id>/microsoft.graph.agentIdentity`.
4. Remove it from `agent-child-ids` and remove any role assignments it held.

## Monitoring
Queries in `docs/queries.kql`: traffic per agent, callers per agent (`emit-metric agent-requests` with agent, caller oid, auth pattern), auth failures, model tokens. Suggested alerts: more than 20 responses with status 401/403 in 5 minutes; more than 5 responses with status 5xx in 15 minutes.

## Troubleshooting
| Symptom | Likely cause | Fix |
|---|---|---|
| 403 from APIM on a public call | Missing or wrong `X-Azure-FDID` | Call through Front Door; check named value `front-door-id` |
| 401 from APIM | Token not issued for the blueprint, or missing `agent.invoke` | Request scope `api://<blueprint>/agent.invoke` |
| 401 on `/api/messages` | Bot Service token audience is not the bot app | Check named value `bot-app-id` |
| Teams message arrives but no reply | Bot can't reach Bot Service outbound | Allow the `AzureBotService` service tag on egress |
| Agent says no Graph token | Agent missing from `agent-child-ids`, or OBO failed | Check the APIM trace (`scripts/trace-obo.sh`) |
| OBO fails with `AADSTS50013` | User token audience is not the blueprint | Fix the requesting scope |
| 403 from Foundry via APIM | APIM identity lacks Foundry User | Grant it on the Foundry account |
| `image_pull_failed` | Project identity can't pull from ACR | AcrPull for the project's managed identity |
