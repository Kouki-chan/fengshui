"""Apple Push Notification service client (token auth, HTTP/2), for the health monitor (DECISIONS D-19).

Needs the paid Apple Developer Program: an APNs auth key (.p8) and the `aps-environment`
entitlement in the app. Until then `APNs.from_settings` returns None and the monitor runs in
pull mode (the phone sends readings while Fengshui is open and fetches alerts itself).

Config (server/.env, gitignored): FENGSHUI_APNS_KEY_PATH (path to the .p8, kept outside the
repo), FENGSHUI_APNS_KEY_ID, optional FENGSHUI_APNS_ENV (sandbox | production). The Team ID is
read from apple/Config/Local.xcconfig (the only place it is stored).
"""

from __future__ import annotations

import re
import time
from pathlib import Path

import httpx
import jwt

TOPIC = "com.chevin.fengshui"
HOSTS = {"sandbox": "https://api.sandbox.push.apple.com", "production": "https://api.push.apple.com"}
TOKEN_TTL = 50 * 60          # Apple rejects provider tokens older than 1 h and refreshes faster than 20 min


def team_id_from_xcconfig(path: Path) -> str | None:
    if not path.exists():
        return None
    m = re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$", path.read_text(), re.M)
    return m.group(1) if m else None


class APNs:
    def __init__(self, key_pem: str, key_id: str, team_id: str, *, env: str = "sandbox", topic: str = TOPIC,
                 client: httpx.Client | None = None, clock=time.time):
        self.key_pem, self.key_id, self.team_id, self.topic = key_pem, key_id, team_id, topic
        self.env = env if env in HOSTS else "sandbox"
        self.clock = clock
        self.client = client or httpx.Client(http2=True, timeout=10)
        self._token: tuple[float, str] | None = None

    @classmethod
    def from_settings(cls, env: dict, xcconfig: Path) -> "APNs | None":
        key_path, key_id = env.get("FENGSHUI_APNS_KEY_PATH"), env.get("FENGSHUI_APNS_KEY_ID")
        team = env.get("FENGSHUI_APNS_TEAM_ID") or team_id_from_xcconfig(xcconfig)
        if not (key_path and key_id and team) or not Path(key_path).expanduser().exists():
            return None
        return cls(Path(key_path).expanduser().read_text(), key_id, team, env=env.get("FENGSHUI_APNS_ENV", "sandbox"))

    def provider_token(self) -> str:
        now = self.clock()
        if self._token is None or now - self._token[0] > TOKEN_TTL:
            tok = jwt.encode({"iss": self.team_id, "iat": int(now)}, self.key_pem, algorithm="ES256",
                             headers={"kid": self.key_id})
            self._token = (now, tok)
        return self._token[1]

    def send(self, device_token: str, payload: dict, *, background: bool, env: str | None = None,
             collapse_id: str | None = None) -> tuple[int, str]:
        """Returns (HTTP status, reason). Background pushes must use priority 5 (Apple's rule)."""
        headers = {
            "authorization": f"bearer {self.provider_token()}",
            "apns-topic": self.topic,
            "apns-push-type": "background" if background else "alert",
            "apns-priority": "5" if background else "10",
            "apns-expiration": str(int(self.clock()) + (300 if background else 3600)),
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id
        url = f"{HOSTS.get(env or self.env, HOSTS[self.env])}/3/device/{device_token}"
        try:
            r = self.client.post(url, json=payload, headers=headers)
        except httpx.HTTPError as e:
            return 0, f"network: {e}"
        reason = ""
        if r.status_code != 200:
            try:
                reason = r.json().get("reason", "")
            except ValueError:
                reason = r.text[:200]
        return r.status_code, reason


def request_payload(session_id: int) -> dict:
    """Silent push asking the app for readings (content-available, no alert)."""
    return {"aps": {"content-available": 1}, "fs": "monitor_request", "session_id": session_id}


def alert_payload(alert: dict) -> dict:
    return {"aps": {"alert": {"title": alert["title"], "body": alert["body"]}, "sound": "default",
                    "thread-id": "monitor"},
            "fs": "monitor_alert", "alert_id": alert["id"], "severity": alert["severity"]}
