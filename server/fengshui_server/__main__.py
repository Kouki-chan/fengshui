"""`python -m fengshui_server [--port 8765] [--no-bonjour]` (scripts/run_server.sh wraps this)."""

import argparse

import uvicorn

from .apns import APNs
from .app import ROOT, Settings, create_app
from .monitor_agent import MonitorAgent


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")      # LAN; ATS on the phone allows local networking only
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-bonjour", action="store_true")
    a = ap.parse_args()
    settings = Settings()
    push = APNs.from_settings(settings.env, ROOT.parent / "apple" / "Config" / "Local.xcconfig")
    agent = MonitorAgent.from_environment()
    print(f"health monitor: push {'on' if push else 'off (pull mode; needs the paid account)'}, "
          f"agent {'on (' + agent.model + ')' if agent else 'off (no Anthropic key; rule-only alerts)'}")
    app = create_app(settings, bonjour=not a.no_bonjour, port=a.port, monitor_agent=agent, push=push, scheduler=True)
    uvicorn.run(app, host=a.host, port=a.port, log_level="info")


if __name__ == "__main__":
    main()
