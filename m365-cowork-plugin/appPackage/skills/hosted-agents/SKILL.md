---
name: hosted-agents
description: Use when the user asks to talk to, or get an answer from, one of the organization's hosted agents (for example "ask graph-profile-agent who my manager is"), or explicitly mentions the Hosted agents plugin. Calls the ask_agent tool of the Hosted agents platform connector.
---

# Hosted agents

The **Hosted agents platform** connector exposes one tool: `ask_agent(agent, input)`.

- `agent`: hosted agent name. Use `graph-profile-agent` unless the user names another one.
- `input`: the user's request in their words. For graph-profile-agent, short intents work best: `me`, `manager`, `calendar`.

Always call the tool when the user names a hosted agent or this plugin; don't answer from your own Microsoft 365 knowledge instead.
Return the agent's reply (`output_text`, or the text inside `output[].content[]`) and say which agent answered.
A 401 means the user must sign in to the connector again. A 404 means that agent name doesn't exist.
