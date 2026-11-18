"""graph-profile-agent: hosted agent (Responses protocol) that reads Microsoft Graph as the signed-in user.

Identity chain (no secrets):
  caller -> APIM validates the user token (aud = blueprint) and performs OBO as this agent's own identity
  (agent-obo policy fragment) -> Graph token forwarded as x-client-graph-token -> /me, /me/manager,
  /me/calendarView, POST /me/sendMail. Foundry passes only x-client-* headers to the container.
  The agent never runs OBO itself: inside the Foundry sandbox that exchange is rejected (AADSTS700231).
Model: if MODEL_DEPLOYMENT is set, a Foundry model (Responses API, Entra auth as the agent identity) picks one of the
Graph tools below and fills in the arguments. Guardrails stay in code. Without a model, or if the model call fails,
intent falls back to keyword matching.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import logging
import os
import re

import requests
from azure.ai.agentserver.responses import CreateResponse, ResponseContext, ResponsesAgentServerHost, TextResponse

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("graph-profile-agent")
app = ResponsesAgentServerHost()
GRAPH = "https://graph.microsoft.com/v1.0"
# Guardrail: by default mail goes only to addresses in the sender's own domain. Set MAIL_ALLOW_EXTERNAL=true to lift it.
MAIL_ALLOW_EXTERNAL = os.environ.get("MAIL_ALLOW_EXTERNAL", "false").lower() == "true"

HELP = ("I can read Microsoft Graph as you. Try:\n"
        "- **me** / **profile**: your profile\n- **manager**: your manager\n- **calendar**: your next 5 events (7 days)\n"
        "- **send email to** <address | me> **subject:** <text> **body:** <text>\n"
        "  (or: **email** <address | me> **about** <subject>)")


def decode_claims(token: str) -> dict:
    """Read JWT claims for logging only. The signature was already checked by APIM."""
    try:
        p = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:  # noqa: BLE001
        return {}


def graph(token: str, path: str, **params) -> dict:
    r = requests.get(f"{GRAPH}{path}", headers={"Authorization": f"Bearer {token}", "Prefer": 'outlook.timezone="UTC"'},
                     params=params, timeout=20)
    if r.status_code == 404:
        return {}
    r.raise_for_status()
    return r.json()


def profile(t: str) -> str:
    me = graph(t, "/me", **{"$select": "displayName,userPrincipalName,mail,jobTitle,department,officeLocation"})
    rows = [("Name", me.get("displayName")), ("UPN", me.get("userPrincipalName")), ("Mail", me.get("mail")),
            ("Title", me.get("jobTitle")), ("Department", me.get("department")), ("Office", me.get("officeLocation"))]
    return "**Your profile**\n" + "\n".join(f"- {k}: {v}" for k, v in rows if v)


def manager(t: str) -> str:
    m = graph(t, "/me/manager", **{"$select": "displayName,userPrincipalName,jobTitle"})
    return f"**Your manager**: {m.get('displayName')} ({m.get('userPrincipalName')}), {m.get('jobTitle') or 'no title'}" if m else "No manager is set for you in Entra ID."


def calendar(t: str) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    ev = graph(t, "/me/calendarView", startDateTime=now.isoformat(), endDateTime=(now + dt.timedelta(days=7)).isoformat(),
               **{"$top": "5", "$orderby": "start/dateTime", "$select": "subject,start,end,location,isOnlineMeeting"}).get("value", [])
    if not ev:
        return "No events in the next 7 days."
    lines = [f"- {e['start']['dateTime'][:16].replace('T', ' ')} UTC: {e.get('subject') or '(no subject)'}"
             + (f" @ {e['location']['displayName']}" if e.get("location", {}).get("displayName") else "") for e in ev]
    return "**Your next events**\n" + "\n".join(lines)


# "send email to bob@contoso.com, me subject: Q3 plan body: See you at 10"   |   "email me about the demo"
MAIL_RE = re.compile(
    r"^\s*(?:please\s+)?(?:send\s+(?:an?\s+)?)?e-?mail\s+(?:to\s+)?(?P<to>.+?)\s+"
    r"(?:subject\s*:\s*(?P<subject>.+?)(?:\s+body\s*:\s*(?P<body>.+))?|about\s+(?P<about>.+))\s*$",
    re.IGNORECASE | re.DOTALL)


def send_mail(t: str, raw: str) -> str:
    """Keyword path: parse 'send email to … subject: … body: …'."""
    m = MAIL_RE.match(raw)
    if not m:
        return ("To send an email say, for example:\n"
                "- send email to me subject: Demo body: Sent by the hosted agent\n"
                "- email colleague@yourdomain.com about tomorrow's review")
    to = [p for p in re.split(r"[,;]|\s+and\s+", m["to"]) if p.strip()]
    subject = (m["subject"] or m["about"]).strip()
    return send_mail_to(t, to, subject, (m["body"] or f"(Sent by graph-profile-agent: {subject})").strip())


def send_mail_to(t: str, recipients: list[str], subject: str, body: str) -> str:
    """Guardrails live here, whoever calls it (keyword path or model tool call)."""
    me = graph(t, "/me", **{"$select": "displayName,mail,userPrincipalName"})
    sender = me.get("mail") or me.get("userPrincipalName")
    domain = sender.split("@")[-1].lower()
    to = []
    for part in recipients:
        a = part.strip().strip("<>").rstrip(".")
        if a.lower() in ("me", "myself"):
            a = sender
        if a:
            to.append(a)
    bad = [a for a in to if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", a)]
    if bad or not to:
        return f"Not sent: I need full email addresses (or 'me'); couldn't use: {', '.join(bad) or '(none)'}."
    external = [a for a in to if a.split("@")[-1].lower() != domain]
    if external and not MAIL_ALLOW_EXTERNAL:
        return f"Not sent: {', '.join(external)} is outside {domain}. This agent only sends inside your organization."
    subject = (subject or "").strip() or "(no subject)"
    footer = f"\n\n--\nSent by graph-profile-agent on behalf of {me.get('displayName') or sender}."
    msg = {"message": {"subject": subject, "body": {"contentType": "Text", "content": (body or "").strip() + footer},
                       "toRecipients": [{"emailAddress": {"address": a}} for a in to]}, "saveToSentItems": True}
    r = requests.post(f"{GRAPH}/me/sendMail", headers={"Authorization": f"Bearer {t}"}, json=msg, timeout=20)
    if r.status_code == 403:
        return "Graph refused to send (403). The agent's token lacks Mail.Send: an admin must consent Mail.Send on the blueprint."
    r.raise_for_status()
    log.info("[mail] sent subject=%r to=%d recipient(s)", subject, len(to))
    return f"**Email sent** as {sender}\n- To: {', '.join(to)}\n- Subject: {subject}\n- A copy is in your Sent Items."


# ---------------------------------------------------------------- model (optional)
MODEL_ENDPOINT = os.environ.get("MODEL_ENDPOINT", "").rstrip("/")          # https://<account>.services.ai.azure.com/openai/v1
MODEL_DEPLOYMENT = os.environ.get("MODEL_DEPLOYMENT", "")
_model_cred = None

TOOLS = [
    {"type": "function", "name": "get_profile", "description": "Get the signed-in user's Microsoft 365 profile.",
     "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "get_manager", "description": "Get the signed-in user's manager.",
     "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "get_calendar", "description": "List the signed-in user's next 5 calendar events in the next 7 days.",
     "parameters": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"type": "function", "name": "send_mail",
     "description": "Send an email as the signed-in user. Only call when the user clearly asked to send an email and gave every "
                    "recipient as a full email address or 'me'.",
     "parameters": {"type": "object", "additionalProperties": False, "required": ["to", "subject", "body"],
                    "properties": {"to": {"type": "array", "items": {"type": "string"},
                                          "description": "Full email addresses, or 'me' for the user themself."},
                                   "subject": {"type": "string"},
                                   "body": {"type": "string", "description": "Plain-text body written for the recipient."}}}},
]

INSTRUCTIONS = (
    "You are graph-profile-agent. You act on behalf of the signed-in user through Microsoft Graph, using only the tools "
    "provided. Answer briefly in Markdown. "
    "Email rules: call send_mail only when the user explicitly asks to send an email. Never guess or invent an address: "
    "if a recipient is given only by name, ask for the email address instead of sending. If the user gives a topic but no "
    "body, write a short, polite, professional body yourself. After a tool runs, report its result faithfully — if it says "
    "'Not sent', say so. Today's date (UTC) is {today}.")


def model_token() -> str:
    global _model_cred
    if _model_cred is None:
        cid = os.environ.get("FOUNDRY_AGENT_INSTANCE_CLIENT_ID")
        _model_cred = ManagedIdentityCredential(client_id=cid) if cid else DefaultAzureCredential()
    return _model_cred.get_token("https://ai.azure.com/.default").token


def model_call(body: dict) -> dict:
    r = requests.post(f"{MODEL_ENDPOINT}/responses", json=body, timeout=60,
                      headers={"Authorization": f"Bearer {model_token()}", "Content-Type": "application/json"})
    if r.status_code >= 400:
        raise RuntimeError(f"model {r.status_code}: {r.text[:300]}")
    return r.json()


def run_with_model(graph_token: str | None, raw: str) -> str:
    """Tool-calling loop on the Responses API. Graph calls always use the APIM-supplied user token."""
    tools = {"get_profile": lambda a: profile(graph_token), "get_manager": lambda a: manager(graph_token),
             "get_calendar": lambda a: calendar(graph_token),
             "send_mail": lambda a: send_mail_to(graph_token, a.get("to", []), a.get("subject", ""), a.get("body", ""))}
    base = {"model": MODEL_DEPLOYMENT, "tools": TOOLS if graph_token else [],
            "instructions": INSTRUCTIONS.format(today=dt.date.today().isoformat())}
    resp = model_call({**base, "input": raw})
    for _ in range(5):
        calls = [o for o in resp.get("output", []) if o.get("type") == "function_call"]
        if not calls:
            break
        outputs = []
        for c in calls:
            try:
                args = json.loads(c.get("arguments") or "{}")
                log.info("[model] tool %s", c["name"])
                result = tools[c["name"]](args)
            except Exception as e:  # noqa: BLE001
                result = f"Tool error: {str(e)[:300]}"
            outputs.append({"type": "function_call_output", "call_id": c["call_id"], "output": result})
        resp = model_call({**base, "previous_response_id": resp["id"], "input": outputs})
    text = resp.get("output_text") or " ".join(
        p.get("text", "") for o in resp.get("output", []) if o.get("type") == "message"
        for p in o.get("content", []) if p.get("type") == "output_text")
    return text.strip() or "(no answer from the model)"


def run_keywords(token: str, raw: str, text: str) -> str:
    if re.search(r"\be-?mail\b", text):
        return send_mail(token, raw)
    if re.search(r"\bmanager\b", text):
        return manager(token)
    if re.search(r"calendar|event|meeting|schedule", text):
        return calendar(token)
    if re.search(r"\b(me|profile|who am i)\b", text):
        return profile(token)
    return profile(token) + "\n\n" + HELP

@app.response_handler
async def handler(request: CreateResponse, context: ResponseContext, _cancel):
    raw = (await context.get_input_text() or "").strip()
    text = raw.lower()
    tc = (context.client_headers or {}).get("x-client-user-assertion")
    if not tc and text.strip() == "selftest model":
        # Proves the agent identity can call the model (no user, no Graph tools).
        try:
            msg = "model ok: " + run_with_model(None, "Reply with exactly: pong")
        except Exception as e:  # noqa: BLE001
            msg = f"model failed: {str(e)[:400]}"
        return TextResponse(context, request, text=msg)
    if not tc:
        return TextResponse(context, request, text="I need your identity to read Graph. Call me through the platform (Teams or Copilot Cowork), not directly.")
    c = decode_claims(tc)
    log.info("[obo] caller oid=%s aud=%s scp=%s", c.get("oid"), c.get("aud"), c.get("scp"))
    try:
        token = (context.client_headers or {}).get("x-client-graph-token")
        if not token:
            raise RuntimeError("no Graph token from the gateway (check the agent-obo policy and agent-child-ids)")
        out = None
        if MODEL_ENDPOINT and MODEL_DEPLOYMENT:
            try:
                out = run_with_model(token, raw)
            except Exception as e:  # noqa: BLE001
                log.warning("[model] failed, using keywords: %s", e)
        if out is None:
            out = run_keywords(token, raw, text)
    except Exception as e:  # noqa: BLE001
        log.warning("[obo] failed: %s", e)
        out = f"I couldn't read Graph on your behalf: {str(e)[:300]}"
    return TextResponse(context, request, text=out)


if __name__ == "__main__":
    app.run()
