#!/usr/bin/env python3
"""Minimal ModelScope-facing status/health server for Hermes Lite.

Only this server binds to 0.0.0.0:7860.

Internal services such as Web Shell, Hermes Gateway API, and Dashboard
remain on 127.0.0.1 and can be reached through Cloudflare Tunnel.

Auth:
- HTML status page "/" is protected by HEALTH_PASSWORD.
- JSON health probes remain open for ModelScope health checks.
- Login creates a session cookie.
- /logout clears the session cookie.
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
from urllib.parse import parse_qs, urlsplit


# ============================================================
# Basic config
# ============================================================

HOST = os.getenv("HEALTH_HOST", "0.0.0.0")
PORT = int(os.getenv("HEALTH_PORT", "7860"))

WEB_SHELL_PORT = int(
    os.getenv("WEB_SHELL_PORT", "2222")
)

GATEWAY_PORT = int(
    os.getenv("API_SERVER_PORT", "8642")
)

DASHBOARD_PORT = int(
    os.getenv("HERMES_DASHBOARD_PORT", "9110")
)


# ============================================================
# Auth config
# ============================================================

AUTH_PASSWORD = os.getenv("HEALTH_PASSWORD", "")
AUTH_ENABLED = bool(AUTH_PASSWORD)

SESSION_MAX_AGE = int(
    os.getenv(
        "HEALTH_SESSION_MAX_AGE",
        str(7 * 24 * 3600),
    )
)

COOKIE_NAME = "hermes_health_session"


# ============================================================
# Session helpers
# ============================================================

def _session_token() -> str:
    """Create stateless signed session token."""

    expiry_secs = int(time.time()) + SESSION_MAX_AGE

    sig = hmac.new(
        AUTH_PASSWORD.encode("utf-8"),
        str(expiry_secs).encode("utf-8"),
        "sha256",
    ).hexdigest()

    payload = f"{expiry_secs}|{sig}".encode("utf-8")

    return base64.urlsafe_b64encode(payload).decode("ascii")


def _session_valid(token: str | None) -> bool:
    """Validate session token."""

    if not token or not AUTH_ENABLED:
        return False

    try:
        payload = base64.urlsafe_b64decode(
            token.encode("ascii")
        ).decode("utf-8")

        expiry_s, sep, sig = payload.partition("|")

        if not sep:
            return False

        expiry = int(expiry_s)

    except Exception:
        return False

    expect = hmac.new(
        AUTH_PASSWORD.encode("utf-8"),
        expiry_s.encode("utf-8"),
        "sha256",
    ).hexdigest()

    return (
        hmac.compare_digest(expect, sig)
        and time.time() < expiry
    )


def _read_cookie(
    handler: BaseHTTPRequestHandler,
) -> str | None:
    """Read session cookie."""

    raw = handler.headers.get("Cookie", "")

    for pair in raw.split(";"):
        key, _, value = pair.strip().partition("=")

        if key == COOKIE_NAME:
            return value

    return None


# ============================================================
# Service helpers
# ============================================================

def tcp_open(
    host: str,
    port: int,
    timeout: float = 0.15,
) -> bool:
    """Check whether TCP port is reachable."""

    try:
        with socket.create_connection(
            (host, port),
            timeout=timeout,
        ):
            return True

    except OSError:
        return False


def env_true(name: str, default: str = "0") -> bool:
    """Parse common boolean environment values."""

    return os.getenv(
        name,
        default,
    ).lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def state() -> dict:
    """Return current Hermes Lite service state."""

    return {
        "status": "ok",
        "time": datetime.now(
            timezone.utc
        ).isoformat(),

        "services": {

            "modelscope_http": {
                "address": f"{HOST}:{PORT}",
                "reachable": True,
            },

            "hermes_gateway_api": {
                "enabled": env_true(
                    "API_SERVER_ENABLED",
                    "false",
                ),
                "address": (
                    f"127.0.0.1:{GATEWAY_PORT}"
                ),
                "reachable": tcp_open(
                    "127.0.0.1",
                    GATEWAY_PORT,
                ),
            },

            "hermes_dashboard": {
                "enabled": env_true(
                    "HERMES_DASHBOARD",
                    "0",
                ),
                "address": (
                    f"127.0.0.1:{DASHBOARD_PORT}"
                ),
                "reachable": tcp_open(
                    "127.0.0.1",
                    DASHBOARD_PORT,
                ),
            },

            "web_shell": {
                "enabled": os.getenv(
                    "REMOTE_WEB_SHELL_CONFIGURED",
                    "0",
                ) == "1",

                "address": (
                    f"127.0.0.1:{WEB_SHELL_PORT}"
                ),

                "reachable": tcp_open(
                    "127.0.0.1",
                    WEB_SHELL_PORT,
                ),
            },

            "cloudflare_tunnel": {
                "configured": os.getenv(
                    "REMOTE_CF_TUNNEL_CONFIGURED",
                    "0",
                ) == "1",
            },
        },
    }


# ============================================================
# HTML
# ============================================================

def _login_page_html(
    error: str | None = None,
) -> str:
    """Render login page."""

    error_html = ""

    if error:
        error_html = (
            "<p style='color:#c0392b'>"
            f"{html.escape(error)}"
            "</p>"
        )

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta
    name="viewport"
    content="width=device-width,initial-scale=1"
>
<title>Hermes Lite - 登录</title>

<style>
body {{
    font-family: system-ui, sans-serif;
    max-width: 380px;
    margin: 80px auto;
    padding: 0 20px;
    line-height: 1.6;
}}

h1 {{
    font-size: 22px;
}}

input {{
    width: 100%;
    box-sizing: border-box;
    padding: 10px;
    margin: 6px 0;
    font-size: 16px;
}}

button {{
    width: 100%;
    padding: 10px;
    margin-top: 8px;
    font-size: 16px;
    background: #2c3e50;
    color: #fff;
    border: 0;
    border-radius: 4px;
    cursor: pointer;
}}

button:hover {{
    opacity: 0.9;
}}
</style>
</head>

<body>

<h1>hello world</h1>

<p>
此页面受密码保护，请输入密码查看服务状态。
</p>

{error_html}

<form method="post" action="/login">

<label for="password">
访问密码：
</label>

<input
    id="password"
    name="password"
    type="password"
    autocomplete="current-password"
    autofocus
    required
>

<button type="submit">
登录
</button>

</form>

</body>
</html>
"""


def _status_page_html() -> str:
    """Render status page."""

    current = state()

    rows: list[str] = []

    for name, info in current["services"].items():

        value = ""

        if isinstance(info, dict):

            if "reachable" in info:

                enabled = info.get(
                    "enabled",
                    True,
                )

                if not enabled:
                    value = "disabled"

                elif info["reachable"]:
                    value = "UP"

                else:
                    value = "DOWN"

            elif "configured" in info:

                value = (
                    "configured"
                    if info["configured"]
                    else "not configured"
                )

            else:
                value = json.dumps(
                    info,
                    ensure_ascii=False,
                )

        else:
            value = str(info)

        rows.append(
            "<tr>"
            f"<td>{html.escape(name)}</td>"
            f"<td>{html.escape(value)}</td>"
            "</tr>"
        )

    logout = ""

    if AUTH_ENABLED:
        logout = (
            "<p>"
            "<a "
            "href='/logout' "
            "style='color:#2980b9'"
            ">"
            "退出登录"
            "</a>"
            "</p>"
        )

    return f"""<!doctype html>
<html lang="zh-CN">

<head>

<meta charset="utf-8">

<meta
    name="viewport"
    content="width=device-width,initial-scale=1"
>

<title>Hermes Lite Status</title>

<style>

body {{
    font-family: system-ui, sans-serif;
    max-width: 760px;
    margin: 48px auto;
    padding: 0 20px;
    line-height: 1.6;
}}

table {{
    border-collapse: collapse;
    width: 100%;
}}

td {{
    border-bottom: 1px solid #ddd;
    padding: 10px;
}}

td:first-child {{
    font-weight: 600;
}}

code {{
    background: #eee;
    padding: 2px 5px;
    border-radius: 4px;
}}

small {{
    color: #666;
}}

</style>

</head>

<body>

<h1>Hermes Lite is running</h1>

{logout}

<p>
此 <code>:7860</code> 页面用于
ModelScope Web 入口与健康状态。
</p>

<p>
Web Shell、Hermes Gateway API 和 Dashboard
仅监听容器内部地址，可通过 Cloudflare Tunnel 访问。
</p>

<table>
<tbody>
{"".join(rows)}
</tbody>
</table>

<p>
<small>
健康接口：
<code>/healthz</code>
</small>
</p>

</body>
</html>
"""


# ============================================================
# HTTP handler
# ============================================================

class Handler(BaseHTTPRequestHandler):

    server_version = "HermesLiteHealth/1.1"

    def _headers(
        self,
        status: int,
        content_type: str,
    ) -> None:

        self.send_response(status)

        self.send_header(
            "Content-Type",
            content_type,
        )

        self.send_header(
            "Cache-Control",
            "no-store",
        )

        self.send_header(
            "X-Content-Type-Options",
            "nosniff",
        )

        self.end_headers()

    # --------------------------------------------------------
    # GET
    # --------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802

        # self.path 可能是：
        #
        # /
        # /?foo=bar
        # /index.html?xxx=123
        #
        # 这里只取真正的 URL path。
        path = urlsplit(
            self.path
        ).path

        # ----------------------------------------------------
        # Health probes
        # ----------------------------------------------------

        if path in {
            "/health",
            "/healthz",
            "/ready",
            "/readyz",
        }:

            payload = json.dumps(
                state(),
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")

            self._headers(
                200,
                "application/json; charset=utf-8",
            )

            self.wfile.write(payload)

            return

        # ----------------------------------------------------
        # Logout
        # ----------------------------------------------------

        if path == "/logout":

            self.send_response(302)

            self.send_header(
                "Location",
                "/",
            )

            self.send_header(
                "Set-Cookie",
                (
                    f"{COOKIE_NAME}=; "
                    "Path=/; "
                    "HttpOnly; "
                    "SameSite=Lax; "
                    "Max-Age=0"
                ),
            )

            self.end_headers()

            return

        # ----------------------------------------------------
        # Homepage
        # ----------------------------------------------------

        if path in {
            "/",
            "/index.html",
        }:

            if (
                AUTH_ENABLED
                and not _session_valid(
                    _read_cookie(self)
                )
            ):

                self._headers(
                    200,
                    "text/html; charset=utf-8",
                )

                self.wfile.write(
                    _login_page_html().encode(
                        "utf-8"
                    )
                )

                return

            body = _status_page_html()

            self._headers(
                200,
                "text/html; charset=utf-8",
            )

            self.wfile.write(
                body.encode("utf-8")
            )

            return

        # ----------------------------------------------------
        # 404
        # ----------------------------------------------------

        self._headers(
            404,
            "text/plain; charset=utf-8",
        )

        self.wfile.write(
            b"not found\n"
        )

    # --------------------------------------------------------
    # POST
    # --------------------------------------------------------

    def do_POST(self) -> None:  # noqa: N802

        path = urlsplit(
            self.path
        ).path

        # ----------------------------------------------------
        # Login
        # ----------------------------------------------------

        if path == "/login":

            length = int(
                self.headers.get(
                    "Content-Length",
                    "0",
                )
                or "0"
            )

            body = self.rfile.read(
                length
            ).decode(
                "utf-8",
                "replace",
            )

            password = (
                parse_qs(
                    body
                ).get(
                    "password"
                )
                or [""]
            )[0]

            if (
                AUTH_ENABLED
                and hmac.compare_digest(
                    password.encode(
                        "utf-8"
                    ),
                    AUTH_PASSWORD.encode(
                        "utf-8"
                    ),
                )
            ):

                self.send_response(302)

                self.send_header(
                    "Location",
                    "/",
                )

                self.send_header(
                    "Set-Cookie",
                    (
                        f"{COOKIE_NAME}="
                        f"{_session_token()}; "
                        "Path=/; "
                        "HttpOnly; "
                        "SameSite=Lax; "
                        f"Max-Age={SESSION_MAX_AGE}"
                    ),
                )

                self.end_headers()

            else:

                self._headers(
                    200,
                    "text/html; charset=utf-8",
                )

                self.wfile.write(
                    _login_page_html(
                        "密码错误，请重试"
                    ).encode(
                        "utf-8"
                    )
                )

            return

        # ----------------------------------------------------
        # 404
        # ----------------------------------------------------

        self._headers(
            404,
            "text/plain; charset=utf-8",
        )

        self.wfile.write(
            b"not found\n"
        )

    # --------------------------------------------------------
    # Log
    # --------------------------------------------------------

    def log_message(
        self,
        fmt: str,
        *args,
    ) -> None:

        print(
            "[health] "
            + (fmt % args),
            flush=True,
        )


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":

    if not (
        1 <= PORT <= 65535
    ):
        raise SystemExit(
            "HEALTH_PORT must be between 1 and 65535"
        )

    print(
        f"[health] Listening on http://{HOST}:{PORT}",
        flush=True,
    )

    ThreadingHTTPServer(
        (HOST, PORT),
        Handler,
    ).serve_forever()
