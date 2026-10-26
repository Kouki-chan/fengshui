#!/usr/bin/env python3
"""Inspect (and optionally prepare) the owner's Managed Agent for Fengshui (DECISIONS D-22).

    .venv/bin/python scripts/managed_agent_setup.py               # read-only report
    .venv/bin/python scripts/managed_agent_setup.py --add-tools   # add Fengshui's custom tools to the agent

Reads FENGSHUI_AGENT_ID / FENGSHUI_AGENT_SESSION_ID / FENGSHUI_DEPLOYMENT_ID from server/.env and the
API key from ANTHROPIC_API_KEY or the Keychain item `fengshui-anthropic`. Prints IDs, names and
tool names only, never the key.

`--add-tools` creates a new agent version that keeps every existing tool and adds the ones the
scheduled deployment needs (its sessions can only use tools defined on the agent). The phone and
the monitor don't need this: they add their tools per session.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "server"), str(ROOT / "engine")]

from fengshui_server.app import _read_env  # noqa: E402
from fengshui_server.deployment import TOOLS  # noqa: E402
from fengshui_server.monitor_agent import api_key  # noqa: E402


def dump(o):
    return o.model_dump(exclude_none=True) if hasattr(o, "model_dump") else dict(o)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--add-tools", action="store_true", help="add Fengshui's custom tools to the agent (new version)")
    a = ap.parse_args()
    env = _read_env(ROOT / "server" / ".env")
    key = api_key()
    if not key:
        print("No API key. Add one without it landing in a file or your history:\n"
              '  security add-generic-password -a "$USER" -s fengshui-anthropic -w')
        return 1
    import anthropic
    c = anthropic.Anthropic(api_key=key)
    agent_id = env.get("FENGSHUI_AGENT_ID")
    if not agent_id:
        print("FENGSHUI_AGENT_ID missing from server/.env")
        return 1
    agent = c.beta.agents.retrieve(agent_id)
    tools = [dump(t) for t in (agent.tools or [])]
    names = {t.get("name") for t in tools if t.get("name")}
    print(f"agent   {agent.id}  v{agent.version}  {agent.name!r}  model={dump(agent.model) if hasattr(agent.model, 'model_dump') else agent.model}")
    print(f"        tools: {[t.get('name') or t.get('type') for t in tools]}")
    print(f"        skills: {[dump(s).get('skill_id') for s in (agent.skills or [])]}  mcp: {[dump(m).get('name') for m in (agent.mcp_servers or [])]}")
    toolset = next((t for t in tools if t.get("type", "").startswith("agent_toolset")), None)
    if agent.skills and not toolset:
        print("        ! skills need the agent toolset with `read` enabled (the error you saw earlier)")
    if toolset:
        web = [cfg.get("name") for cfg in toolset.get("configs", []) if cfg.get("name") in ("web_fetch", "web_search")
               and cfg.get("enabled", toolset.get("default_config", {}).get("enabled", True))]
        if web or not toolset.get("configs"):
            print("        ! web tools look enabled: tool results include your health data; consider turning web_fetch off")
    if sid := env.get("FENGSHUI_AGENT_SESSION_ID"):
        s = c.beta.sessions.retrieve(sid)
        print(f"session {s.id}  status={s.status}  environment={s.environment_id}")
    if did := env.get("FENGSHUI_DEPLOYMENT_ID"):
        d = c.beta.deployments.retrieve(did)
        dd = dump(d)
        print(f"deploy  {d.id}  schedule={dd.get('schedule', {}).get('cron') or dd.get('schedule')}  "
              f"next={dd.get('schedule', {}).get('upcoming_runs_at', [])[:2]}  paused={dd.get('paused_reason')}")
    missing = [t for t in TOOLS if t["name"] not in names]
    print(f"\nFengshui tools on the agent: {len(TOOLS) - len(missing)}/{len(TOOLS)}"
          + (f"  missing: {[t['name'] for t in missing]}" if missing else ""))
    if missing and not a.add_tools:
        print("Run again with --add-tools to add them (needed only for the scheduled deployment).")
    if missing and a.add_tools:
        updated = c.beta.agents.update(agent.id, version=agent.version, tools=tools + missing)
        print(f"Updated: agent is now v{updated.version} with {len(updated.tools)} tools. Existing sessions keep their version.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
