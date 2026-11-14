#!/usr/bin/env python3
"""Model router for wrapCodex.sh.

Codex binds one model provider -- one base_url -- to a session, so /model can
switch models but never servers. This sidecar listens on a single loopback port,
is wired into config.toml as the base_url of every provider, and forwards each
request to the upstream that actually serves the model named in the request
body. Upstream keys are named in routes.json and read from the environment, so
no secret is ever written to disk or passed in argv.

launch.sh starts it just before Codex; it exits with the container.
"""

import http.client
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_ROUTES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "routes.json")
ROUTES_PATH = os.environ.get("CODEX_ROUTER_ROUTES", DEFAULT_ROUTES)
TIMEOUT = float(os.environ.get("CODEX_ROUTER_TIMEOUT", "600"))
ERROR_LOG = os.environ.get(
    "CODEX_ROUTER_ERROR_LOG",
    os.path.join(os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex")),
                 "model-router-error.json"))
MAX_DUMP = 512 * 1024
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host",
}


LAST_GOOD_ROUTES = None


def load_routes():
    """Read routes.json.

    It lives on a mount shared with the host, where starting another session
    rewrites it in place, so a read can land mid-write. Retry once and fall
    back to the last complete read rather than taking the session down with it.
    """
    global LAST_GOOD_ROUTES
    for attempt in (0, 1):
        try:
            with open(ROUTES_PATH, "rb") as fh:
                routes = json.load(fh)
        except (OSError, ValueError):
            if attempt == 0:
                time.sleep(0.25)
                continue
            if LAST_GOOD_ROUTES is not None:
                return LAST_GOOD_ROUTES
            raise
        LAST_GOOD_ROUTES = routes
        return routes


def dump_error(method, tail, body, detail):
    """Keep the last request an upstream refused, both halves of it.

    A local model sometimes emits a half-written tool call, Codex echoes the
    arguments back verbatim, and the upstream then reports the whole body as
    unparsable JSON. Without this the only trace is a bare 400 in the log.
    """
    try:
        with open(ERROR_LOG, "w", encoding="utf-8", errors="replace") as fh:
            json.dump({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "method": method, "path": tail,
                       "upstream_error": detail[:MAX_DUMP].decode("utf-8", "replace"),
                       "request": body[:MAX_DUMP].decode("utf-8", "replace")}, fh)
    except OSError:
        pass


def split_base_url(base_url):
    """http[s]://host[:port]/prefix -> (tls, host, port, prefix)."""
    tls, _, rest = base_url.partition("://")
    tls = tls.lower() == "https"
    netloc, _, prefix = rest.partition("/")
    host, _, port = netloc.partition(":")
    return tls, host, int(port) if port else (443 if tls else 80), "/" + prefix


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "codex-model-router"

    # -- helpers ---------------------------------------------------------
    def log_message(self, fmt, *args):  # keep the container log readable
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_body(self, status, payload, content_type="application/json"):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(payload)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def read_body(self):
        length = self.headers.get("content-length")
        if length is not None:
            return self.rfile.read(int(length)) if int(length) > 0 else b""
        if (self.headers.get("transfer-encoding") or "").lower() != "chunked":
            return b""
        body = b""
        while True:
            size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
            if size == 0:
                self.rfile.readline()
                break
            body += self.rfile.read(size)
            self.rfile.readline()
        return body

    def upstream_model(self, body):
        try:
            model = json.loads(body).get("model")
        except (ValueError, AttributeError):
            model = None
        routes = load_routes()
        known = routes.get("routes", {})
        if model in known:
            return model, known[model]
        default = routes.get("default")
        if model is None and default in known:
            return default, known[default]
        return None, None

    def _translate_reasoning_effort(self, entry, body):
        """Rewrite reasoning_effort per the route's reasoning_effort_map.

        Some upstreams (e.g. vLLM serving Qwen) use "xhigh" where OpenAI
        uses "high".  The map is keyed by the value Codex sends; the value is
        what the upstream expects.  Non-JSON bodies or absent maps pass
        through unchanged.
        """
        re_map = entry.get("reasoning_effort_map")
        if not re_map or not body:
            return body
        try:
            parsed = json.loads(body)
        except (ValueError, TypeError):
            return body
        level = parsed.get("reasoning_effort")
        if level and level in re_map:
            parsed["reasoning_effort"] = re_map[level]
            return json.dumps(parsed).encode()
        return body

    # -- forwarding ------------------------------------------------------
    def forward(self, method, tail, entry, body):
        tls, host, port, prefix = split_base_url(entry["base_url"])
        conn = (http.client.HTTPSConnection if tls else http.client.HTTPConnection)(
            host, port, timeout=TIMEOUT
        )
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in HOP_BY_HOP and not k.lower().startswith("x-forwarded")
        }
        key = os.environ.get(entry.get("env_key", ""), entry.get("api_key", ""))
        if key:
            headers["Authorization"] = "Bearer " + key
        headers["accept-encoding"] = "identity"
        body = self._translate_reasoning_effort(entry, body)
        try:
            conn.request(method, prefix + tail, body=body or None, headers=headers)
            resp = conn.getresponse()
            detail = None
            if resp.status >= 400:
                detail = resp.read()
                dump_error(method, tail, body, detail)
                sys.stderr.write("router: upstream %d on %s; request kept in %s\n"
                                 % (resp.status, tail, ERROR_LOG))
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            self.send_header("connection", "close")
            self.end_headers()
            self.close_connection = True
            if detail is not None:
                self.wfile.write(detail)
            else:
                while True:
                    chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            self.wfile.flush()
        except (OSError, http.client.HTTPException) as exc:
            detail = json.dumps({"error": {"message": "router: %s -> %s: %s" % (
                entry["base_url"], type(exc).__name__, exc), "type": "router_error"}}).encode()
            try:
                self.send_body(502, detail)
            except OSError:
                pass
        finally:
            conn.close()

    def serve_models(self, body):
        """GET /v1/models: merge what every upstream says it serves."""
        merged, seen = [], set()
        routes = load_routes()
        for entry in routes.get("routes", {}).values():
            tail = "/models"
            tls, host, port, prefix = split_base_url(entry["base_url"])
            conn = (http.client.HTTPSConnection if tls else http.client.HTTPConnection)(
                host, port, timeout=15
            )
            try:
                headers = {"accept": "application/json"}
                key = os.environ.get(entry.get("env_key", ""), entry.get("api_key", ""))
                if key:
                    headers["Authorization"] = "Bearer " + key
                conn.request("GET", prefix + tail, headers=headers)
                for item in json.loads(conn.getresponse().read()).get("data", []):
                    if item.get("id") not in seen:
                        seen.add(item.get("id"))
                        merged.append(item)
            except (OSError, ValueError, http.client.HTTPException):
                continue  # a server that is down must not hide the others
            finally:
                conn.close()
        self.send_body(200, json.dumps({"object": "list", "data": merged}).encode())

    # -- verbs -----------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/healthz"):
            return self.send_body(200, b'{"status":"ok"}')
        if path.endswith("/models"):
            return self.serve_models(None)
        return self.do_POST()

    def do_POST(self):
        body = self.read_body()
        model, entry = self.upstream_model(body)
        if entry is None:
            known = ", ".join(sorted(load_routes().get("routes", {}))) or "(none)"
            payload = json.dumps({
                "error": {"message": "router: no upstream serves this model; known: %s" % known,
                          "type": "router_error"}}).encode()
            return self.send_body(404, payload)
        tail = self.path.split("?")[0]
        if tail.startswith("/v1"):
            tail = tail[3:] or "/"
        return self.forward(self.command, tail, entry, body)

    # Anything else Codex throws at its provider endpoint (PUT/DELETE on
    # /v1/responses/<id>, for instance) still has to reach the right upstream.
    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST


def main():
    routes = load_routes()
    port = int(os.environ.get("CODEX_ROUTER_PORT", routes.get("port", 8777)))
    if not routes.get("routes"):
        sys.exit("router: %s has no routes" % ROUTES_PATH)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    sys.stderr.write("router: listening on 127.0.0.1:%d for %s\n"
                     % (port, ", ".join(sorted(routes["routes"]))))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    sys.exit(main())
