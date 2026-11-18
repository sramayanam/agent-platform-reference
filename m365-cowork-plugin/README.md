# Copilot Cowork plugin

Packages the platform's MCP server (`https://<front-door-host>/agents-mcp/mcp`, tool `ask_agent`) as a Microsoft 365 Copilot Cowork plugin (`agentConnectors` → `remoteMcpServer`). Sign-in uses Entra SSO against the agent blueprint, so there is no client secret.

## Provision
1. `cp env/.env.dev.example env/.env.dev` and fill in the values.
2. Prepare the blueprint for Cowork SSO (see `docs/identity-setup.md`, step 7): web redirect `https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect`, and pre-authorize the Microsoft token store `ab3be6b7-f5df-413d-ac2d-abf1e3fd9c0b` for `agent.invoke`.
3. Run the Microsoft 365 Agents Toolkit:
   ```bash
   npx @microsoft/m365agentstoolkit-cli auth login m365
   npx @microsoft/m365agentstoolkit-cli provision --env dev --interactive false
   ```
   This creates the app, registers SSO (`oauth/register`, writes `SSO_CONFIGURATION_ID` and `SSO_APPLICATION_ID_URI`), validates and uploads the package, and installs it for you.
4. Add the generated `SSO_APPLICATION_ID_URI` to the blueprint's `identifierUris` (keep the existing ones).

## Packaging notes
- Use manifest **1.28**; later versions may install but not appear in Cowork.
- `mcpToolDescription.file` and `agentSkills[].folder` must have no `./` prefix, and the zip must have no directory entries (`zip -D`).
- Org rollout: Microsoft 365 admin center → Agents → Tools → the plugin → Installed for.

## Test
| Prompt in Cowork | Expected |
|---|---|
| "Using Hosted agents, who am I?" | Sign-in prompt the first time, then your Graph profile |
| "Ask graph-profile-agent who my manager is" | Your manager, or "No manager is set" |
| "Ask graph-profile-agent for my calendar this week" | Next events |

From a terminal: `scripts/test-mcp.sh graph-profile-agent me`.
