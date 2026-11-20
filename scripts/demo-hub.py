#!/usr/bin/env python3
"""A stand-in CLIProxyAPI hub with made-up accounts, for trying the widget without a real one.

    python3 scripts/demo-hub.py          # serves http://127.0.0.1:8399, management key "demo"

It answers GET /v0/management/auth-files the way a hub does, including the 401 for a wrong key.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = "demo"
HOUR = 3600
DAY = 24 * HOUR


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def claude(name, five_hour=None, weekly=None, seen_ago=60, opus=None, **extra):
    """five_hour, weekly and the model-scoped opus are (used fraction, seconds until reset)."""
    now = time.time()
    signals = {}
    for window, reading in (("5h", five_hour), ("7d", weekly), ("7d_opus", opus)):
        if reading is None:
            continue
        used, resets_in = reading
        prefix = f"Anthropic-Ratelimit-Unified-{window}-"
        signals[prefix + "Utilization"] = str(used)
        signals[prefix + "Status"] = "rejected" if used >= 1 else "allowed"
        signals[prefix + "Reset"] = str(int(now + resets_in))
    return {
        "id": f"claude-{name}.json",
        "name": f"claude-{name}.json",
        "provider": "claude",
        "email": name,
        "disabled": False,
        "unavailable": False,
        "quota": {"observed_at": iso(now - seen_ago), "signals": signals},
        **extra,
    }


def codex(name, plan, five_hour, weekly, seen_ago=120):
    now = time.time()
    signals = {"X-Codex-Plan-Type": plan}
    for slot, minutes, (used, resets_in) in (("Primary", 300, five_hour), ("Secondary", 10080, weekly)):
        signals[f"X-Codex-{slot}-Used-Percent"] = str(used)
        signals[f"X-Codex-{slot}-Window-Minutes"] = str(minutes)
        signals[f"X-Codex-{slot}-Reset-At"] = str(int(now + resets_in))
    return {
        "id": f"codex-{name}.json",
        "name": f"codex-{name}.json",
        "provider": "codex",
        "email": name,
        "disabled": False,
        "unavailable": False,
        "quota": {"observed_at": iso(now - seen_ago), "signals": signals},
    }


def accounts():
    now = time.time()
    return [
        claude("ada@example.com", (0.34, 2.2 * HOUR), (0.27, 2.6 * DAY), seen_ago=20, opus=(0.12, 2.6 * DAY)),
        claude("grace@example.com", None, (0.61, 4.1 * DAY), seen_ago=95 * 60),
        claude(
            "linus@example.com",
            (1.0, 1.4 * HOUR),
            (0.88, 0.9 * DAY),
            seen_ago=6 * 60,
            unavailable=True,
            next_retry_after=iso(now + 1.4 * HOUR),
        ),
        claude("benched@example.com", None, (0.99, 5.5 * DAY), seen_ago=2 * DAY, disabled=True),
        codex("ada@example.com", "pro", (51, 3.1 * HOUR), (17, 5.2 * DAY)),
        codex("grace@example.com", "plus", (8, 4.4 * HOUR), (72, 1.3 * DAY), seen_ago=40 * 60),
    ]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v0/management/auth-files":
            return self.reply(404, {"error": "not found"})
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            return self.reply(401, {"error": "invalid management key"})
        self.reply(200, {"files": accounts()})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8399
    print(f'Demo hub on http://127.0.0.1:{port}, management key "{KEY}"')
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
