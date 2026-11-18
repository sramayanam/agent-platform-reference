"""Shared Teams bot for all hosted agents (Microsoft 365 Agents SDK, Python).

Flow per message:
  Teams SSO -> Azure Bot OAuth connection `teams-sso` (AAD v2 with federated credentials) returns a user
  token whose audience is the agent identity blueprint (scope api://<blueprint>/agent.invoke).
  The bot calls APIM  POST {APIM}/agents/{agent}/openai/responses  with that token (inside the VNet); APIM validates
  it, runs the OBO exchange as the agent's identity, and calls Foundry with APIM's managed identity.
Inbound: Bot Service -> Front Door -> APIM /api/messages -> this container (internal ingress only).
Outbound: replies and SSO token calls go from this container to Bot Service (allow the AzureBotService service tag).
No secrets: the bot authenticates to Bot Service with a managed identity used as a federated credential.
"""

from __future__ import annotations

import logging
import os
import re

import aiohttp
from aiohttp.web import Application, Request, Response, json_response, run_app
from dotenv import load_dotenv
from microsoft_agents.activity import ActivityTypes, load_configuration_from_env
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware, start_agent_process
from microsoft_agents.hosting.core import (AgentApplication, Authorization, MemoryStorage, MessageFactory,
                                           TurnContext, TurnState)

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
log = logging.getLogger("agents-bot")

CONFIG = load_configuration_from_env(os.environ)
STORAGE = MemoryStorage()
CONNECTIONS = MsalConnectionManager(**CONFIG)
ADAPTER = CloudAdapter(connection_manager=CONNECTIONS)
AUTH = Authorization(STORAGE, CONNECTIONS, **CONFIG)
APP = AgentApplication[TurnState](storage=STORAGE, adapter=ADAPTER, authorization=AUTH, **CONFIG)

APIM_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
APIM_KEY = os.environ.get("APIM_SUBSCRIPTION_KEY")          # Container App secret; optional if APIM drops keys
DEFAULT_AGENT = os.environ.get("DEFAULT_AGENT_NAME", "graph-profile-agent")
API_VERSION = os.environ.get("FOUNDRY_API_VERSION", "v1")
HANDLER = "SSO"

# Per-conversation routing + Responses threading. In-memory here; use durable storage before running more than one replica.
_route: dict[str, str] = {}
_prev_response: dict[str, str] = {}
_session: aiohttp.ClientSession | None = None


def _claims_summary(token: str) -> str:
    import base64, json
    try:
        p = token.split(".")[1]; p += "=" * (-len(p) % 4)
        c = json.loads(base64.urlsafe_b64decode(p))
        return f"aud={c.get('aud')} scp={c.get('scp')} oid={c.get('oid')}"
    except Exception:  # noqa: BLE001
        return "unparseable"


async def call_agent(agent: str, user_token: str, text: str, conv_id: str) -> str:
    global _session
    _session = _session or aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120))
    headers = {"Authorization": f"Bearer {user_token}", "Content-Type": "application/json"}
    if APIM_KEY:
        headers["Ocp-Apim-Subscription-Key"] = APIM_KEY
    body: dict = {"input": text, "stream": False}
    if conv_id in _prev_response:
        body["previous_response_id"] = _prev_response[conv_id]
    url = f"{APIM_URL}/agents/{agent}/openai/responses?api-version={API_VERSION}"
    log.info("[route] agent=%s token(%s)", agent, _claims_summary(user_token))   # never the token itself
    async with _session.post(url, json=body, headers=headers) as r:
        data = await r.json(content_type=None)
        if r.status >= 400:
            log.warning("[route] agent=%s status=%s err=%s", agent, r.status, str(data)[:300])
            return f"The agent '{agent}' returned an error ({r.status})."
    if data.get("id"):
        _prev_response[conv_id] = data["id"]
    if data.get("output_text"):
        return data["output_text"]
    parts = [c.get("text", "") for item in data.get("output", []) if item.get("type") == "message"
             for c in item.get("content", []) if c.get("type") == "output_text"]
    return "\n".join(p for p in parts if p) or "(no text in agent response)"


@APP.conversation_update("membersAdded")
async def on_members_added(context: TurnContext, state: TurnState) -> None:
    for m in context.activity.members_added or []:
        if m.id != context.activity.recipient.id:
            await context.send_activity(f"Hi! You're talking to agent '{DEFAULT_AGENT}'. Type /agent followed by an agent name to switch.")


@APP.message(re.compile(r"^/agent\s+(\S+)\s*$", re.IGNORECASE))
async def switch_agent(context: TurnContext, state: TurnState) -> None:
    name = context.activity.text.split()[1]
    _route[context.activity.conversation.id] = name
    _prev_response.pop(context.activity.conversation.id, None)
    await context.send_activity(f"Now routing to agent '{name}'.")


@APP.message(re.compile(r"^/logout$", re.IGNORECASE))
async def logout(context: TurnContext, state: TurnState) -> None:
    await APP.auth.sign_out(context, HANDLER)
    await context.send_activity("Signed out.")


@APP.activity(ActivityTypes.message, auth_handlers=[HANDLER])
async def on_message(context: TurnContext, state: TurnState) -> None:
    token = await APP.auth.get_token(context, HANDLER)
    if not token or not token.token:
        await context.send_activity("Sign-in is required before I can reach the agent.")
        return
    conv = context.activity.conversation.id
    agent = _route.get(conv, DEFAULT_AGENT)
    await context.send_activity(MessageFactory.text(await call_agent(agent, token.token, context.activity.text or "", conv)))


async def messages(req: Request) -> Response:
    return await start_agent_process(req, req.app["agent_app"], req.app["adapter"])


async def health(_: Request) -> Response:
    return json_response({"status": "ok"})


def main() -> None:
    web = Application(middlewares=[jwt_authorization_middleware])
    web.router.add_post("/api/messages", messages)
    web.router.add_get("/healthz", health)
    web["agent_configuration"] = CONNECTIONS.get_default_connection_configuration()
    web["agent_app"] = APP
    web["adapter"] = APP.adapter
    run_app(web, host="0.0.0.0", port=int(os.environ.get("PORT", "3978")))


if __name__ == "__main__":
    main()
