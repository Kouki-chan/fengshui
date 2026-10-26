"""The monitor's Claude agent (DECISIONS D-19): called only when a rule flags something.

It sees processed readings through tools (never raw watch data), and must finish with
`send_alert` or `no_alert`. Hard-rule flags notify whatever it decides (monitor.ALWAYS_NOTIFY).

API key: ANTHROPIC_API_KEY in the server's environment, or the macOS Keychain item
`fengshui-anthropic` (add it with `security add-generic-password -a "$USER" -s fengshui-anthropic -w`,
which prompts for the key so it never lands in a file or the shell history).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from .monitor import Flag, readings_window

MODEL = "claude-sonnet-5-5"
FALLBACK_MODELS = {"claude-sonnet-5-5", "claude-opus-5-5"}
FALLBACK_BETA = "server-side-fallback-2026-07-01"
MAX_ROUNDS = 5
LABELS = ["heart_rate", "resting_heart_rate", "heart_rate_variability_sdnn", "oxygen_saturation",
          "respiratory_rate", "step_count", "high_heart_rate_event", "low_heart_rate_event",
          "irregular_heart_rhythm_event"]

SYSTEM = """You are the monitoring agent of Fengshui, a personal health app. During a monitoring session you \
are called only when a fixed rule has flagged one of the user's readings. Look at the flags and, through the \
tools, at the recent readings and the user's own baselines. Then decide whether the user should get a push \
notification, and finish by calling exactly one of send_alert or no_alert.

Notify when the pattern is plausibly real and worth the user's attention. Don't notify for things explained by \
the context, such as a high heart rate during or right after activity, a single isolated reading, or a value that \
is normal for this user's baseline. You are not a clinician and must not diagnose. Write plainly and calmly. The \
title is at most 50 characters and the body at most 180, and the body says what was seen and what to do. For \
urgent findings (very low blood oxygen, a very high heart rate at rest), tell the user to seek medical help or \
call emergency services if they feel unwell. Readings come from consumer devices and can be wrong; say so when \
it matters."""


def _tool(name: str, desc: str, props: dict, required: list[str]) -> dict:
    return {"name": name, "description": desc, "strict": True,
            "input_schema": {"type": "object", "properties": props, "required": required,
                             "additionalProperties": False}}


TOOLS = [
    _tool("get_flags", "The rule flags raised in this check (code, severity, message, value, time).", {}, []),
    _tool("get_recent_readings", "Processed readings of one label received in this monitoring session over the last "
          "N minutes, oldest first, as [iso_time, value or text].",
          {"label": {"type": "string", "enum": LABELS}, "minutes": {"type": "integer", "minimum": 5, "maximum": 720}},
          ["label", "minutes"]),
    _tool("get_baselines", "The user's usual values (30-day medians) and the monitoring session's settings.", {}, []),
    _tool("send_alert", "Send the user a push notification. Call once, as the final step.",
          {"severity": {"type": "string", "enum": ["info", "warning", "urgent"]},
           "title": {"type": "string"}, "body": {"type": "string"}}, ["severity", "title", "body"]),
    _tool("no_alert", "Decide not to notify. Call once, as the final step.",
          {"reason": {"type": "string"}}, ["reason"]),
]


def api_key() -> str | None:
    if key := os.environ.get("ANTHROPIC_API_KEY"):
        return key
    if sys.platform != "darwin":
        return None
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", "fengshui-anthropic", "-w"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


def _iso(ts: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds")


class MonitorAgent:
    def __init__(self, client, model: str = MODEL):
        self.client, self.model = client, model
        self.last_calls: list[dict] = []          # for tests and the server log

    @classmethod
    def from_environment(cls, model: str | None = None) -> "MonitorAgent | None":
        key = api_key()
        if not key:
            return None
        import anthropic
        return cls(anthropic.Anthropic(api_key=key), model or os.environ.get("FENGSHUI_MONITOR_MODEL") or MODEL)

    def _run_tool(self, name: str, args: dict, ctx: dict) -> str:
        if name == "get_flags":
            return json.dumps([f.as_dict() | {"at": _iso(f.at) if f.at else None} for f in ctx["flags"]])
        if name == "get_baselines":
            s = ctx["session"]
            return json.dumps({"baselines": ctx["baselines"], "interval_min": s["interval_s"] / 60,
                               "session_started": _iso(s["start_ts"]), "now": _iso(ctx["now"])})
        if name == "get_recent_readings":
            since = ctx["now"] - int(args["minutes"]) * 60
            rows = [[_iso(x["ts"]), x.get("value") if x.get("value") is not None else x.get("text")]
                    for x in ctx["samples"] if x["label"] == args["label"] and x["ts"] >= since]
            return json.dumps({"label": args["label"], "readings": rows[-300:]})
        raise ValueError(f"unknown tool {name}")

    def decide(self, conn, session: dict, flags: list[Flag], now: float) -> dict:
        samples, baselines = readings_window(conn, session["id"], now - 12 * 3600)
        ctx = {"flags": flags, "session": session, "samples": samples, "baselines": baselines, "now": now}
        messages = [{"role": "user", "content": f"Now: {_iso(now)}. A rule flagged {len(flags)} finding(s) in this "
                                                "check. Decide whether to notify the user."}]
        extra: dict = {}
        if self.model in FALLBACK_MODELS:
            extra = {"extra_body": {"fallbacks": "default"}, "extra_headers": {"anthropic-beta": FALLBACK_BETA}}
        self.last_calls = []
        for _ in range(MAX_ROUNDS):
            resp = self.client.messages.create(model=self.model, max_tokens=4000, system=SYSTEM, tools=TOOLS,
                                               tool_choice={"type": "auto"}, messages=messages, **extra)
            uses = [b for b in resp.content if b.type == "tool_use"]
            if resp.stop_reason != "tool_use" or not uses:
                break
            results = []
            for u in uses:
                self.last_calls.append({"name": u.name, "input": u.input})
                if u.name == "send_alert":
                    return {"notify": True, "severity": u.input["severity"], "title": u.input["title"],
                            "body": u.input["body"]}
                if u.name == "no_alert":
                    return {"notify": False, "reason": u.input.get("reason", "")}
                try:
                    out, err = self._run_tool(u.name, u.input, ctx), False
                except Exception as e:
                    out, err = f"Error: {e}", True
                results.append({"type": "tool_result", "tool_use_id": u.id, "content": out, **({"is_error": True} if err else {})})
            messages.append({"role": "assistant", "content": resp.content})
            messages.append({"role": "user", "content": results})
        raise RuntimeError("agent finished without send_alert / no_alert")
