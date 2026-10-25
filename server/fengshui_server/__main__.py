"""`python -m fengshui_server [--port 8765] [--no-bonjour]` (scripts/run_server.sh wraps this)."""

import argparse

import uvicorn

from .app import create_app


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")      # LAN; ATS on the phone allows local networking only
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-bonjour", action="store_true")
    a = ap.parse_args()
    uvicorn.run(create_app(bonjour=not a.no_bonjour, port=a.port), host=a.host, port=a.port, log_level="info")


if __name__ == "__main__":
    main()
