# Identity and gateway setup

Do these steps once per tenant, in order. Every Graph call needs the header `OData-Version: 4.0`. Examples use `az rest` (signed in as an admin with the roles listed in [Create an agent identity blueprint](https://learn.microsoft.com/entra/agent-id/create-blueprint)). Write the IDs you get back into `.env`.

## Objects you end up with

| Object | Type | Purpose |
|---|---|---|
| Agent blueprint | Entra Agent ID blueprint + blueprint principal | Single token audience for every channel; parent of every agent identity. Exposes delegated scope `agent.invoke`. |
| Agent identity (one per agent) | Agent identity (child of the blueprint) | Holds the user's Graph token. Downstream audit logs show this identity acting for the user. |
| Blueprint credential | User-assigned managed identity, attached to APIM | The blueprint's only credential (federated). No secret. |
| APIM system identity | System-assigned managed identity | Calls Foundry. Role **Foundry User** on each Foundry account. |
| Bot app | App registration (single tenant) + Azure Bot | Teams bot. Credential = a second user-assigned managed identity (federated). |
| Cowork SSO registration | Teams Developer Portal OAuth registration (Entra SSO) | Lets Copilot Cowork get the user's token for the blueprint. No secret. |

## 1. Blueprint

```bash
G=https://graph.microsoft.com
az rest -m POST -u "$G/v1.0/applications" --headers "OData-Version=4.0" "Content-Type=application/json" --body '{
  "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
  "displayName": "agent-platform-blueprint",
  "sponsors@odata.bind": ["https://graph.microsoft.com/v1.0/users/<sponsor-object-id>"],
  "owners@odata.bind":   ["https://graph.microsoft.com/v1.0/users/<owner-object-id>"]
}'
# record id (blueprint object id) and appId (AGENT_BLUEPRINT_APP_ID)
```

## 2. Blueprint credential: managed identity (federated)

```bash
az identity create -g <rg> -n uami-agent-blueprint      # record principalId and clientId
az rest -m POST -u "$G/v1.0/applications/<blueprint-object-id>/federatedIdentityCredentials" \
  --headers "OData-Version=4.0" "Content-Type=application/json" --body '{
  "name": "uami-agent-blueprint",
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "subject": "<uami-principal-id>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

## 3. Identifier URI and the `agent.invoke` scope

```bash
az rest -m PATCH -u "$G/v1.0/applications/<blueprint-object-id>" --headers "OData-Version=4.0" "Content-Type=application/json" --body '{
  "identifierUris": ["api://<blueprint-app-id>"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [{
      "id": "<new-guid>", "value": "agent.invoke", "type": "User", "isEnabled": true,
      "adminConsentDisplayName": "Invoke agents", "adminConsentDescription": "Call the platform's agents as the signed-in user.",
      "userConsentDisplayName": "Invoke agents", "userConsentDescription": "Call the platform's agents as you."
    }]
  }
}'
```
`identifierUris` and `oauth2PermissionScopes` are replaced, not appended. Read them first when you change them later (steps 7 and 8 add more URIs).

## 4. Blueprint principal and inheritable permissions

```bash
az rest -m POST -u "$G/v1.0/serviceprincipals/microsoft.graph.agentIdentityBlueprintPrincipal" \
  --headers "OData-Version=4.0" "Content-Type=application/json" --body '{"appId":"<blueprint-app-id>"}'
# record id (AGENT_BLUEPRINT_SP_OBJECT_ID)

# Agent identities inherit the blueprint's delegated Graph grants. Use enumeratedScopes to narrow.
az rest -m POST -u "$G/beta/applications/<blueprint-object-id>/microsoft.graph.agentIdentityBlueprint/inheritablePermissions" \
  --headers "Content-Type=application/json" --body '{
  "resourceAppId": "00000003-0000-0000-c000-000000000000",
  "inheritableScopes": {"@odata.type": "microsoft.graph.enumeratedScopes", "scopes": ["User.Read","Calendars.Read","Mail.Send"]}
}'
```

## 5. Agent identity per agent

`factory/scripts/deploy-agent.sh` does this on publish. Manually:
```bash
az rest -m POST -u "$G/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" --headers "OData-Version=4.0" "Content-Type=application/json" --body '{
  "displayName": "graph-profile-agent",
  "agentIdentityBlueprintId": "<blueprint-app-id>",
  "sponsors@odata.bind": ["https://graph.microsoft.com/v1.0/users/<sponsor-object-id>"]
}'
# record appId and add it to the APIM named value agent-child-ids
```
Agent identities have no credential and no consent of their own. A consent attempt on one fails with `AADSTS82014` by design.

## 6. Teams bot

1. App registration `bot-agent-platform`, single tenant. Record its appId (`BOT_APP_ID`).
2. User-assigned managed identity `uami-bot-agents`, attached to the bot's Container App. Add a federated credential on the bot app trusting it (same body as step 2).
3. Teams SSO on the bot app: identifier URI `api://botid-<bot-app-id>`, scope `access_as_user`, and pre-authorize the Teams clients `1fec8e78-bce4-4aaf-ab1b-5451cc387264` (desktop/mobile) and `5e3ce6c0-2b1f-4285-8d4b-75ee78787346` (web).
4. Azure Bot: single tenant, app ID = bot app, messaging endpoint `https://<front-door-host>/api/messages`, Teams channel on, **public network access on**.
5. OAuth connection `teams-sso` on the Azure Bot: Microsoft Entra ID v2 with federated credentials, client ID = bot app, token exchange URL `api://botid-<bot-app-id>`, scopes `api://<blueprint-app-id>/agent.invoke`. The connection page shows the federated credential subject it expects; add that federated credential to the bot app.
6. Run `scripts/grant-admin-consent.sh` (blueprint → Graph scopes; bot → `agent.invoke` and Graph sign-in scopes).

## 7. Copilot Cowork SSO

On the blueprint (keep the existing values):
- Add the web redirect URI `https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect`.
- `api.preAuthorizedApplications`: Microsoft token store `ab3be6b7-f5df-413d-ac2d-abf1e3fd9c0b` for the `agent.invoke` scope ID.
- After `atk provision` (see `m365-cowork-plugin/README.md`), add the generated `SSO_APPLICATION_ID_URI` to `identifierUris`.

## 8. APIM

**Identities**
- Attach `uami-agent-blueprint` to APIM as a user-assigned identity.
- Grant APIM's system identity **Foundry User** on each Foundry account (works across subscriptions in one tenant).

**Named values**

| Name | Value |
|---|---|
| `tenant-id` | Tenant ID |
| `blueprint-client-id` | Blueprint appId |
| `blueprint-uami-client-id` | Client ID of `uami-agent-blueprint` |
| `agent-child-ids` | `graph-profile-agent=<agent identity appId>;<name>=<appId>` |
| `mcp-resource` | `https://<front-door-host>/agents-mcp/mcp` (also add it to the blueprint's `identifierUris`) |
| `apim-gateway-url` | `https://<front-door-host>` (used in the MCP 401 `resource_metadata` link) |
| `front-door-id` | Your Front Door profile ID (`X-Azure-FDID`) |
| `bot-app-id` | Bot appId |
| `bot-internal-url` | `https://<bot-app>.internal.<container-apps-env-domain>` |

**APIs** (policies in `apiops/`)

| API | Path | Operations | Backend |
|---|---|---|---|
| Global policy | all | Front Door-only check | |
| `bot-messages` | `/api` | `POST /messages` (no subscription key) | Teams bot (`bot-internal-url`) |
| `agents` | `/agents` | `GET/POST/DELETE /{agentName}/{*rest}` → `/agents/{agentName}/endpoint/protocols/{rest}`, `GET /health` | Foundry project endpoint |
| `agents-tools` | `/agents-tools` | `POST /ask` (`{agent, input}`) | Foundry project endpoint |
| `agents-mcp` | `/agents-mcp` | MCP server, tool `ask_agent` → `agents-tools` `ask_agent` | |
| `oauth-prm` | `/.well-known/oauth-protected-resource` | `GET /agents-mcp/mcp` (anonymous) | |

Policy fragment `agent-obo` is included by `agents` and `agents-tools`.

**Network** (classic Premium, external VNet mode): NSG on the APIM subnet allows inbound 443 only from `AzureFrontDoor.Backend` (plus `ApiManagement` 3443 for management). Outbound: Entra ID (`AzureActiveDirectory`), Azure Monitor, and peering to the Foundry private endpoints. Link the private DNS zones `privatelink.services.ai.azure.com`, `privatelink.cognitiveservices.azure.com` and `privatelink.openai.azure.com` to the APIM VNet.

## Token chain (what to expect in a trace)

| # | Token | Requested by | aud | Represents |
|---|---|---|---|---|
| 1 | Tc | Channel SSO | blueprint appId | user, `scp agent.invoke` |
| 2 | T<sub>UAMI</sub> | APIM, `authentication-managed-identity` | token exchange | `uami-agent-blueprint` |
| 3 | T1 | `client_credentials` as blueprint, `fmi_path` = agent identity, assertion = #2 | token exchange | blueprint acting for the agent identity |
| 4 | TR | `jwt-bearer`, `requested_token_use=on_behalf_of`, client = agent identity, client_assertion = #3, assertion = #1 | `https://graph.microsoft.com` | the user (oid), issued to the agent identity; `scp` = consented Graph scopes |
| 5 | APIM → Foundry | APIM system identity | `https://ai.azure.com` | APIM |

`scripts/trace-obo.sh` reproduces this from a real call.

Common errors: `AADSTS50013` = the user token was issued for Graph instead of the blueprint; `AADSTS82014` = consent attempted on an agent identity (grant on the blueprint instead); `AADSTS700231` = OBO attempted inside the Foundry hosted-agent sandbox (run it in APIM).
