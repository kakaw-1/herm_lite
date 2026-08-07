#!/usr/bin/env python3
"""Minimal ModelScope-facing status/health server for Hermes Lite.

Only this server binds to 0.0.0.0:7860. Internal admin services remain on
127.0.0.1 and are intended to be reached through Cloudflare Tunnel + Access.

Auth: the HTML status page "/" is protected by a password (HEALTH_PASSWORD).
JSON health probes (/healthz etc.) stay OPEN so ModelScope keeps seeing a live
service. Login creates a 7-day session cookie; /logout clears it.
"""
from __future__ import annotations

import base64
import hmac
import html
import json
import os
import socket
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

HOST = os.getenv("HEALTH_HOST", "0.0.0.0")
PORT = int(os.getenv("HEALTH_PORT", "7860"))
SSH_PORT = int(os.getenv("SSH_PORT", "2222"))
GATEWAY_PORT = int(os.getenv("API_SERVER_PORT", "8642"))
DASHBOARD_PORT = int(os.getenv("HERMES_DASHBOARD_PORT", "9119"))

# --- auth config -------------------------------------------------------
AUTH_PASSWORD = os.getenv("HEALTH_PASSWORD", "")
AUTH_ENABLED = bool(AUTH_PASSWORD)
SESSION_MAX_AGE = int(os.getenv("HEALTH_SESSION_MAX_AGE", str(7 * 24 * 3600)))
COOKIE_NAME = "hermes_health_session"


def _session_token() -> str:
    """Stateless session token: signed expiry, 7 days from now."""
    expiry_secs = int(time.time()) + SESSION_MAX_AGE
    sig = hmac.new(AUTH_PASSWORD.encode(), str(expiry_secs).encode(), "sha256").hexdigest()
    return base64.urlsafe_b64encode(f"{expiry_secs}|{sig}".encode()).decode()


def _session_valid(token: str | None) -> bool:
    if not token or not AUTH_ENABLED:
        return False
    try:
        payload = base64.urlsafe_b64decode(token.encode()).decode()
        expiry_s, _, sig = payload.partition("|")
        expiry = int(expiry_s)
    except Exception:
        return False
    expect = hmac.new(AUTH_PASSWORD.encode(), expiry_s.encode(), "sha256").hexdigest()
    return hmac.compare_digest(expect, sig) and time.time() < expiry


def _read_cookie(handler: BaseHTTPRequestHandler) -> str | None:
    raw = handler.headers.get("Cookie", "")
    for pair in raw.split(";"):
        key, _, value = pair.strip().partition("=")
        if key == COOKIE_NAME:
            return value
    return None


def tcp_open(host: str, port: int, timeout: float = 0.15) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def state() -> dict:
    return {
        "status": "ok",
        "time": datetime.now(timezone.utc).isoformat(),
        "services": {
            "modelscope_http": {"address": f"{HOST}:{PORT}", "reachable": True},
            "hermes_gateway_api": {
                "address": f"127.0.0.1:{GATEWAY_PORT}",
                "reachable": tcp_open("127.0.0.1", GATEWAY_PORT),
            },
            "hermes_dashboard": {
                "enabled": os.getenv("HERMES_DASHBOARD", "0").lower() in {"1", "true", "yes", "on"},
                "address": f"127.0.0.1:{DASHBOARD_PORT}",
                "reachable": tcp_open("127.0.0.1", DASHBOARD_PORT),
            },
            "ssh": {
                "enabled": os.getenv("REMOTE_SSH_CONFIGURED", "0") == "1",
                "address": f"127.0.0.1:{SSH_PORT}",
                "reachable": tcp_open("127.0.0.1", SSH_PORT),
            },
            "cloudflare_tunnel": {
                "configured": os.getenv("REMOTE_CF_TUNNEL_CONFIGURED", "0") == "1",
            },
        },
    }


def _login_page_html(error: str | None = None) -> str:
    err = (f"<p style='color:#c0392b'>{html.escape(error)}</p>" if error else "")
    return ("<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>Hermes Lite - 登录</title>"
            "<style>body{font-family:system-ui,sans-serif;max-width:380px;margin:80px auto;padding:0 20px;line-height:1.6}"
            "h1{font-size:20px}input{width:100%;box-sizing:border-box;padding:10px;margin:6px 0;font-size:16px}"
            "button{width:100%;padding:10px;font-size:16px;background:#2c3e50;color:#fff;border:0;border-radius:4px;cursor:pointer}"
            "button:hover{background:#1a252f}</style></head><body>"
            "<h1>Hermes Lite 状态页</h1>"
            "<form method='post' action='/login'>"
            "<label>访问密码：</label><input type='password' name='password' autocomplete='current-password' required autofocus>" +
            err +
            "<button type='submit'>登录</button></form>"
            "<p><small>此页面受密码保护，请输入密码查看服务状态。</small></p></body></html>")


class Handler(BaseHTTPRequestHandler):
    server_version = "HermesLiteHealth/1.0"

    def _headers(self, status: int, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        # 健康检查接口保持开放（供 ModelScope 心跳探测，不受登录保护）
        if self.path in {"/health", "/healthz", "/ready", "/readyz"}:
            payload = json.dumps(state(), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self._headers(200, "application/json; charset=utf-8")
            self.wfile.write(payload)
            return

        if self.path == "/logout":
            self.send_response(302)
            self.send_header("Location", "/")
            self.send_header("Set-Cookie",
                             f"{COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")
            self.end_headers()
            return

        if self.path == "/":
            if AUTH_ENABLED and not _session_valid(_read_cookie(self)):
                self._headers(200, "text/html; charset=utf-8")
                self.wfile.write(_login_page_html().encode("utf-8"))
                return

            s = state()
            rows = []
            for name, info in s["services"].items():
                if isinstance(info, dict):
                    if "reachable" in info:
                        value = "UP" if info["reachable"] else "DOWN / not enabled yet"
                    elif "configured" in info:
                        value = "configured" if info["configured"] else "not configured"
                    else:
                        value = json.dumps(info, ensure_ascii=False)
                else:
                    value = str(info)
                rows.append(f"<tr><td>{html.escape(name)}</td><td>{html.escape(value)}</td></tr>")
            logout = (f"<p><a href='/logout' style='color:#2980b9'>退出登录</a></p>" if AUTH_ENABLED else "")
            body = ("<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
                    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                    "<title>Hermes Lite Status</title>"
                    "<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:48px auto;padding:0 20px;line-height:1.6}"
                    "table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #ddd;padding:10px}"
                    "code{background:#eee;padding:2px 5px;border-radius:4px}</style></head><body>"
                    "<h1>Hermes Lite is running</h1>"
                    + logout +
                    "<p>此 <code>:7860</code> 页面仅用于 ModelScope Web 入口与健康状态。"
                    "SSH、Hermes Gateway API 和可选 Dashboard 仅监听容器 loopback，并应通过 Cloudflare Access/Tunnel 访问。</p>"
                    "<table><tbody>" + "".join(rows) + "</tbody></table>"
                    "<p><small>健康接口：<code>/healthz</code></small></p></body></html>")
            self._headers(200, "text/html; charset=utf-8")
            self.wfile.write(body.encode("utf-8"))
            return

        self._headers(404, "text/plain; charset=utf-8")
        self.wfile.write(b"not found\n")

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/login":
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length).decode("utf-8", "replace")
            pw = (parse_qs(body).get("password") or [""])[0]
            if AUTH_ENABLED and hmac.compare_digest(pw.encode("utf-8"), AUTH_PASSWORD.encode("utf-8")):
                self.send_response(302)
                self.send_header("Location", "/")
                self.send_header("Set-Cookie",
                                 f"{COOKIE_NAME}={_session_token()}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_MAX_AGE}")
                self.end_headers()
            else:
                self._headers(200, "text/html; charset=utf-8")
                self.wfile.write(_login_page_html("密码错误，请重试").encode("utf-8"))
            return

        self._headers(404, "text/plain; charset=utf-8")
        self.wfile.write(b"not found\n")

    def log_message(self, fmt: str, *args) -> None:
        print("[health] " + (fmt % args), flush=True)


if __name__ == "__main__":
    if not (1 <= PORT <= 65535):
        raise SystemExit("HEALTH_PORT must be between 1 and 65535")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()