#!/usr/bin/env python3
"""A small made-up website for the README screenshots to point at.

The HTTP client and the site explorer need something to talk to, and a
screenshot of either should not depend on a real site staying the same, or on
a CI runner having a network. This serves a robots.txt that names a sitemap, the
sitemap, a few pages, and a JSON API — all of it invented, all of it on this
machine.

    fixture_server.py [--port 8765] [--log requests.log]

Standard library only. Every request is also written, one line each, to --log,
which one of the screenshots shows in a terminal.
"""
import argparse
import json
import socket
import socketserver
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ORIGIN = "http://localhost:{port}"

ROBOTS = """\
User-agent: *
Allow: /api/
Disallow: /admin/
Disallow: /internal/

Sitemap: {origin}/sitemap.xml
"""

# Paths the sitemap declares, with a last-modified date each.
PAGES = {
    "/": "2025-05-02",
    "/pricing": "2025-04-18",
    "/about": "2025-03-30",
    "/contact": "2025-03-30",
    "/changelog": "2025-05-01",
    "/docs/": "2025-05-02",
    "/docs/getting-started": "2025-04-21",
    "/docs/authentication": "2025-04-21",
    "/docs/api/users": "2025-04-28",
    "/docs/api/orders": "2025-04-28",
    "/docs/api/webhooks": "2025-05-01",
    "/blog/hello-world": "2025-02-11",
    "/blog/launch-notes": "2025-03-04",
    "/blog/scaling-the-api": "2025-04-09",
}

USERS = [
    {"id": 1, "name": "Mina Park", "email": "mina@example.com", "role": "admin", "active": True},
    {"id": 2, "name": "Jonas Weber", "email": "jonas@example.com", "role": "editor", "active": True},
    {"id": 3, "name": "Priya Nair", "email": "priya@example.com", "role": "viewer", "active": False},
    {"id": 4, "name": "Tomas Silva", "email": "tomas@example.com", "role": "editor", "active": True},
]

ORDERS = [
    {"id": 1001, "user": 1, "total": 49.00, "status": "paid"},
    {"id": 1002, "user": 2, "total": 129.50, "status": "shipped"},
    {"id": 1003, "user": 4, "total": 18.25, "status": "pending"},
]


def sitemap(origin):
    entries = "".join(
        "  <url><loc>{}{}</loc><lastmod>{}</lastmod></url>\n".format(origin, path, modified)
        for path, modified in PAGES.items()
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + entries + "</urlset>\n"
    )


def page(title, links=()):
    items = "".join('    <li><a href="{0}">{0}</a></li>\n'.format(link) for link in links)
    return (
        "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>{0}</title></head>\n"
        "<body>\n  <h1>{0}</h1>\n  <ul>\n{1}  </ul>\n</body></html>\n"
    ).format(title, items)


def route(path, origin):
    """(status, content type, body text) for a path."""
    if path == "/robots.txt":
        return 200, "text/plain; charset=utf-8", ROBOTS.format(origin=origin)
    if path == "/sitemap.xml":
        return 200, "application/xml; charset=utf-8", sitemap(origin)
    if path == "/api/users":
        body = {"users": USERS, "total": len(USERS), "page": 1, "next": "/api/users?page=2"}
        return 200, "application/json; charset=utf-8", json.dumps(body, indent=2) + "\n"
    if path == "/api/orders":
        return 200, "application/json; charset=utf-8", json.dumps({"orders": ORDERS}, indent=2) + "\n"
    if path == "/api/health":
        return 200, "application/json; charset=utf-8", json.dumps({"status": "ok", "version": "0.3.0"}) + "\n"
    if path == "/":
        links = ["/docs/", "/blog/hello-world", "/pricing", "/changelog", "/about", "/contact"]
        return 200, "text/html; charset=utf-8", page("hello-api", links)
    if path in PAGES:
        return 200, "text/html; charset=utf-8", page(path.strip("/") or "home")
    if path.startswith(("/admin", "/internal")):
        return 403, "application/json; charset=utf-8", json.dumps({"error": "forbidden"}) + "\n"
    return 404, "application/json; charset=utf-8", json.dumps({"error": "not found", "path": path}) + "\n"


def make_handler(origin, log_path):
    class Handler(BaseHTTPRequestHandler):
        server_version = "hello-api/0.3.0"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def version_string(self):
            return self.server_version

        def do_GET(self):
            self.respond(send_body=True)

        def do_HEAD(self):
            self.respond(send_body=False)

        def respond(self, send_body):
            path = urlsplit(self.path).path
            status, content_type, text = route(path, origin)
            data = text.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Request-Id", uuid.uuid4().hex[:12])
            self.end_headers()
            if send_body:
                self.wfile.write(data)

        def log_request(self, code="-", size="-"):
            if not log_path:
                return
            line = "{} {} {} {}\n".format(time.strftime("%H:%M:%S"), self.command, self.path, code)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(line)

        def log_message(self, format, *args):
            pass

    return Handler


class DualStackServer(ThreadingHTTPServer):
    """localhost can resolve to ::1 or 127.0.0.1; answer on both."""

    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        # HTTPServer.server_bind asks DNS for the host's name, which can take
        # seconds on a CI runner and is not needed here.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class IPv4Server(ThreadingHTTPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--log", default="")
    args = parser.parse_args()

    origin = ORIGIN.format(port=args.port)
    handler = make_handler(origin, args.log)
    if args.log:
        open(args.log, "w", encoding="utf-8").close()
    try:
        server = DualStackServer(("::", args.port), handler)
    except OSError:
        server = IPv4Server(("127.0.0.1", args.port), handler)
    print("serving {} (Ctrl-C to stop)".format(origin), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
