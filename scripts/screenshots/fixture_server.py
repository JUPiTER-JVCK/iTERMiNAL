#!/usr/bin/env python3
"""A small made-up website for the README screenshots to point at.

The HTTP client and the site explorer need something to talk to, and a
screenshot of either should not depend on a real site staying the same, or on
a CI runner having a network. This serves a robots.txt that names a sitemap, the
sitemap, a few pages, and a JSON API — all of it invented, all of it on this
machine. It also answers the one request an OpenAI-compatible assistant makes
(POST .../chat/completions) with a fixed reply, so the AI picture does not
depend on a model, a key or a network.

    fixture_server.py [--port 8765] [--log requests.log]

Standard library only. Every request is also written, one line each, to --log,
which one of the screenshots shows in a terminal.
"""
import argparse
import json
import socket
import socketserver
import struct
import sys
import time
import uuid
import zlib
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

# Two users, and no value with a slash in it: the whole body fits in the
# response pane of the screenshot, and the formatter writes "/" as "\/", which
# is valid JSON but not what a picture of the pane should be remembered for.
USERS = [
    {"id": 1, "name": "Mina Park", "email": "mina@example.com", "role": "admin", "active": True},
    {"id": 2, "name": "Jonas Weber", "email": "jonas@example.com", "role": "editor", "active": True},
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


# One stylesheet for every page. It follows the system's light or dark setting,
# so the page in the browser panel looks at home in either of the app's looks.
STYLE = """
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea;
        --card: #f5f5f7; --code: #f2f2f4; --accent: #10a37f; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161617; --fg: #f5f5f7; --muted: #a1a1a6; --line: #2c2c2e; --card: #1f1f21; --code: #222224; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
       font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
header { display: flex; align-items: center; gap: 20px; padding: 14px 28px; border-bottom: 1px solid var(--line); }
header b { font-size: 16px; letter-spacing: -0.01em; margin-right: 8px; }
header a { color: var(--muted); text-decoration: none; font-size: 13px; }
header a.on { color: var(--fg); font-weight: 600; }
main { max-width: 760px; margin: 0 auto; padding: 40px 28px 48px; }
h1 { font-size: 34px; line-height: 1.15; letter-spacing: -0.02em; margin: 0 0 10px; }
h2 { font-size: 18px; margin: 30px 0 8px; }
.lead { font-size: 17px; color: var(--muted); margin: 0 0 24px; }
.btn { display: inline-block; background: var(--accent); color: #fff; padding: 9px 16px; border-radius: 9px;
       text-decoration: none; font-weight: 600; font-size: 14px; }
.btn.alt { background: transparent; color: var(--fg); border: 1px solid var(--line); margin-left: 8px; }
pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 13px; }
pre { background: var(--code); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px;
      overflow: auto; margin: 22px 0; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 26px 0; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
.card h3 { margin: 0 0 4px; font-size: 14px; }
.card p { margin: 0; color: var(--muted); font-size: 13px; }
table { width: 100%; border-collapse: collapse; margin: 14px 0; font-size: 14px; }
th, td { text-align: left; padding: 9px 10px; border-bottom: 1px solid var(--line); }
th { color: var(--muted); font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
.tag { display: inline-block; font-size: 12px; color: var(--accent); border: 1px solid var(--line);
       border-radius: 6px; padding: 1px 7px; margin-left: 8px; }
footer { color: var(--muted); font-size: 13px; border-top: 1px solid var(--line); padding: 18px 28px; }
footer a { color: var(--muted); margin-right: 16px; text-decoration: none; }
"""

NAV = [("/docs/", "Docs"), ("/changelog", "Changelog"), ("/pricing", "Pricing"), ("/about", "About")]
FOOTER = [("/blog/hello-world", "Blog"), ("/pricing", "Pricing"), ("/about", "About"), ("/contact", "Contact")]


def page(title, body, active=""):
    """A page of the made-up site, in its one stylesheet."""
    nav = "".join(
        '<a class="{}" href="{}">{}</a>'.format("on" if href == active else "", href, label) for href, label in NAV
    )
    footer = "".join('<a href="{}">{}</a>'.format(href, label) for href, label in FOOTER)
    return (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        "<title>{title}</title><style>{style}</style></head>\n"
        '<body>\n<header><b><a href="/" style="color:inherit;font-size:16px">hello-api</a></b>{nav}</header>\n'
        "<main>\n{body}\n</main>\n<footer>{footer}</footer>\n</body></html>\n"
    ).format(title=title, style=STYLE, nav=nav, body=body, footer=footer)


def home_page(origin):
    body = (
        "<h1>A small API for users and orders.</h1>\n"
        '<p class="lead">JSON over HTTP, paginated, rate limited, and documented in one page.</p>\n'
        '<p><a class="btn" href="/docs/">Get started</a>'
        '<a class="btn alt" href="/changelog">What\'s new in 0.3</a></p>\n'
        "<pre>$ curl {origin}/api/users\n"
        '{{"users": [{{"id": 1, "name": "Mina Park", "role": "admin"}}, ...], "total": 2}}</pre>\n'
        '<div class="cards">\n'
        '<div class="card"><h3>Users</h3><p>List and page through accounts.</p></div>\n'
        '<div class="card"><h3>Orders</h3><p>Totals and status for every order.</p></div>\n'
        '<div class="card"><h3>Health</h3><p>One call to know the service is up.</p></div>\n'
        "</div>"
    ).format(origin=origin)
    return page("hello-api", body)


def docs_page(origin):
    body = (
        '<h1>Documentation <span class="tag">v0.3.0</span></h1>\n'
        '<p class="lead">Every endpoint returns JSON and takes no authentication in this sample.</p>\n'
        "<h2>Endpoints</h2>\n"
        "<table>\n<tr><th>Method</th><th>Path</th><th>Returns</th></tr>\n"
        "<tr><td>GET</td><td><code>/api/users</code></td><td>the list of users</td></tr>\n"
        "<tr><td>GET</td><td><code>/api/orders</code></td><td>the list of orders</td></tr>\n"
        "<tr><td>GET</td><td><code>/api/health</code></td><td>service status</td></tr>\n"
        "</table>\n"
        "<h2>Paging</h2>\n"
        "<p>Add <code>?page=2&amp;per_page=25</code> to any list. <code>per_page</code> is capped at 100.</p>\n"
        "<pre>$ curl '{origin}/api/users?page=2&amp;per_page=25'</pre>"
    ).format(origin=origin)
    return page("Docs · hello-api", body, active="/docs/")


def changelog_page():
    body = (
        "<h1>Changelog</h1>\n"
        '<p class="lead">What changed, newest first.</p>\n'
        '<h2>0.3.0 <span class="tag">2025-04-30</span></h2>\n'
        "<p>A health endpoint, rate limiting by address, and a Kubernetes deployment.</p>\n"
        '<h2>0.2.0 <span class="tag">2025-02-17</span></h2>\n'
        "<p>Pagination for <code>/api/users</code>, and a Dockerfile.</p>\n"
        '<h2>0.1.0 <span class="tag">2025-01-08</span></h2>\n'
        "<p>Users and orders.</p>"
    )
    return page("Changelog · hello-api", body, active="/changelog")


# Each post points to the next, so a crawl that starts on the front page finds
# the second post two links away and the third three.
NEXT_POST = {
    "/blog/hello-world": ("/blog/launch-notes", "Launch notes"),
    "/blog/launch-notes": ("/blog/scaling-the-api", "Scaling the API"),
}


def plain_page(path):
    title = (path.strip("/").split("/")[-1] or "home").replace("-", " ").capitalize()
    body = "<h1>{0}</h1>\n<p class=\"lead\">Nothing more to see on this made-up page.</p>".format(title)
    if path in NEXT_POST:
        href, label = NEXT_POST[path]
        body += '\n<p>Next: <a href="{}">{}</a></p>'.format(href, label)
    return page("{} · hello-api".format(title), body, active=path)


# --- A page with things on it: the HTTP client's Extract tab reads this one. ---
#
# Pictures, a video, a podcast, files to save and a feed, all made up here: the
# pictures are drawn below, and the rest are the right kind of file with next to
# nothing in them. None of the addresses on the page leave this machine except
# the two that name other sites, which are listed and never requested.

def png(width, height, pixel):
    """A PNG, 8-bit RGB, from a function (x, y) -> (r, g, b). Standard library only."""
    rows = b"".join(
        b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height)
    )

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def cover_pixel(x, y):
    # A soft diagonal wash, green to blue.
    t = (x / 320 + y / 180) / 2
    return (int(16 + 20 * t), int(163 - 70 * t), int(127 + 90 * t))


def chart_pixel(x, y):
    # Four bars on a pale ground.
    bars = [(30, 70, 80), (100, 140, 120), (170, 210, 60), (240, 280, 100)]
    for left, right, top in bars:
        if left <= x < right and y >= 180 - top - 20:
            return (16, 163, 127)
    return (245, 245, 247)


def avatar_pixel(x, y):
    dx, dy = x - 40, y - 40
    return (193, 98, 222) if dx * dx + dy * dy < 34 * 34 else (230, 230, 235)


MEDIA = {
    "/media/cover.png": ("image/png", lambda: png(320, 180, cover_pixel)),
    "/media/cover-640.png": ("image/png", lambda: png(640, 360, lambda x, y: cover_pixel(x // 2, y // 2))),
    "/media/chart.png": ("image/png", lambda: png(320, 180, chart_pixel)),
    "/media/avatar.png": ("image/png", lambda: png(80, 80, avatar_pixel)),
    "/media/favicon.png": ("image/png", lambda: png(32, 32, lambda x, y: (16, 163, 127))),
    # The right first bytes for the type, and not a playable file.
    "/media/demo.mp4": ("video/mp4", lambda: b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + b"\x00" * 2048),
    "/media/demo.webm": ("video/webm", lambda: b"\x1aE\xdf\xa3" + b"\x00" * 2048),
    "/media/demo.en.vtt": ("text/vtt", lambda: b"WEBVTT\n\n00:00.000 --> 00:02.000\nThe quarter, in one minute.\n"),
    "/media/episode.mp3": ("audio/mpeg", lambda: b"ID3\x03\x00\x00\x00\x00\x00\x00" + b"\x00" * 4096),
    "/files/ledger-q2.pdf": ("application/pdf", lambda: b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0/Kids[]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"),
    "/files/ledger-data.csv": ("text/csv", lambda: b"region,revenue,costs\nNorth,12,7\nSouth,8,5\nEast,15,9\nWest,10,6\n"),
    "/files/ledger-archive.zip": ("application/zip", lambda: b"PK\x05\x06" + b"\x00" * 18),
}


def article_page(origin):
    body = (
        '<article>\n<h1 id="top">The Ledger Report: a quarter in numbers</h1>\n'
        '<p class="lead"><img src="/media/avatar.png" alt="Ada Byron" width="40" height="40" style="vertical-align:middle;border-radius:50%"> '
        'By <a href="/about" rel="author">Ada Byron</a> · 1 June 2025 · 6 minute read</p>\n'
        '<figure><img src="/media/cover.png" srcset="/media/cover.png 320w, /media/cover-640.png 640w" '
        'alt="A green and blue wash" width="320" height="180"><figcaption>The quarter, in one picture.</figcaption></figure>\n'
        "<p>The quarter closed with <a href=\"/changelog\">strong gains</a>, according to "
        '<a href="https://example.org/report" rel="nofollow">the analysts</a>, who expected less; the figures, '
        "revised twice, show growth in every region we cover, and the costs stayed flat.</p>\n"
        "<h2>Highlights</h2>\n<ul><li>Revenue up 12%</li><li>Costs flat</li><li>Two new regions</li></ul>\n"
        '<img src="/media/chart.png" alt="Revenue by region" width="320" height="180">\n'
        # An old page's picture, from a host that serves it over plain http: the
        # download plan leaves it out and says why. Never requested by anything.
        '<img src="http://cdn.example.net/banner.png" alt="Sponsor banner" width="320" height="40">\n'
        "<h2>Numbers by region</h2>\n"
        "<table><caption>Q2, in millions</caption><thead><tr><th>Region</th><th>Revenue</th><th>Costs</th></tr></thead>"
        "<tbody><tr><td>North</td><td>12</td><td>7</td></tr><tr><td>South</td><td>8</td><td>5</td></tr>"
        "<tr><td>East</td><td>15</td><td>9</td></tr><tr><td>West</td><td>10</td><td>6</td></tr></tbody></table>\n"
        "<h2>Watch and listen</h2>\n"
        '<video controls poster="/media/cover.png" width="320"><source src="/media/demo.mp4" type="video/mp4">'
        '<source src="/media/demo.webm" type="video/webm"><track kind="captions" src="/media/demo.en.vtt" srclang="en" label="English"></video>\n'
        '<audio controls src="/media/episode.mp3"></audio>\n'
        '<iframe width="320" height="180" src="https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ" title="The quarter, explained"></iframe>\n'
        "<h2>Take it with you</h2>\n"
        '<p><a class="btn" href="/files/ledger-q2.pdf">The full report (PDF)</a> '
        '<a class="btn alt" href="/files/ledger-data.csv">The data (CSV)</a> '
        '<a href="/files/ledger-archive.zip" download>Everything, zipped</a></p>\n'
        '<p>Questions? <a href="mailto:desk@example.com">Write to the desk</a>. <a href="#top">Back to the top</a>. '
        # The one link on the page that robots.txt asks crawlers to leave alone.
        '<a href="/admin/">Staff area</a>.</p>\n'
        "</article>"
    )
    head = (
        '<link rel="canonical" href="{origin}/blog/ledger-notes">'
        '<link rel="icon" href="/media/favicon.png" sizes="32x32">'
        '<link rel="alternate" type="application/rss+xml" title="hello-api blog" href="/feed.xml">'
        '<meta name="description" content="Revenue up 12% on flat costs: the quarter, region by region.">'
        '<meta name="author" content="Ada Byron">'
        '<meta property="og:title" content="The Ledger Report">'
        '<meta property="og:site_name" content="hello-api blog">'
        '<meta property="og:image" content="{origin}/media/cover-640.png">'
        '<meta property="article:published_time" content="2025-06-01T09:00:00Z">'
        '<meta name="twitter:card" content="summary_large_image">'
        '<script type="application/ld+json">{{"@context":"https://schema.org","@type":"NewsArticle",'
        '"headline":"The Ledger Report","url":"{origin}/blog/ledger-notes","datePublished":"2025-06-01",'
        '"author":{{"@type":"Person","name":"Ada Byron"}}}}</script>'
    ).format(origin=origin)
    html = page("The Ledger Report · hello-api", body, active="")
    return html.replace("</head>", head + "</head>", 1)


def feed(origin):
    items = "".join(
        "<item><title>{}</title><link>{}{}</link><pubDate>{}</pubDate><description>{}</description></item>\n".format(
            title, origin, path, date, summary
        )
        for title, path, date, summary in [
            ("The Ledger Report", "/blog/ledger-notes", "Sun, 01 Jun 2025 09:00:00 GMT", "A quarter in numbers."),
            ("Scaling the API", "/blog/scaling-the-api", "Wed, 09 Apr 2025 08:00:00 GMT", "What changed to keep up."),
            ("Launch notes", "/blog/launch-notes", "Tue, 04 Mar 2025 08:00:00 GMT", "Version 0.2, and what is next."),
        ]
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>hello-api blog</title>'
        "<link>{0}/</link><description>News from the made-up API.</description>\n{1}</channel></rss>\n"
    ).format(origin, items)


def route(path, origin):
    """(status, content type, body text) for a path."""
    if path == "/robots.txt":
        return 200, "text/plain; charset=utf-8", ROBOTS.format(origin=origin)
    if path == "/sitemap.xml":
        return 200, "application/xml; charset=utf-8", sitemap(origin)
    if path == "/api/users":
        body = {"users": USERS, "total": len(USERS), "page": 1}
        return 200, "application/json; charset=utf-8", json.dumps(body, indent=2) + "\n"
    if path == "/api/orders":
        return 200, "application/json; charset=utf-8", json.dumps({"orders": ORDERS}, indent=2) + "\n"
    if path == "/api/health":
        return 200, "application/json; charset=utf-8", json.dumps({"status": "ok", "version": "0.3.0"}) + "\n"
    if path == "/blog/ledger-notes":
        return 200, "text/html; charset=utf-8", article_page(origin)
    if path == "/feed.xml":
        return 200, "application/rss+xml; charset=utf-8", feed(origin)
    if path in MEDIA:
        content_type, make = MEDIA[path]
        return 200, content_type, make()
    if path == "/":
        return 200, "text/html; charset=utf-8", home_page(origin)
    if path == "/docs/":
        return 200, "text/html; charset=utf-8", docs_page(origin)
    if path == "/changelog":
        return 200, "text/html; charset=utf-8", changelog_page()
    if path in PAGES:
        return 200, "text/html; charset=utf-8", plain_page(path)
    if path.startswith(("/admin", "/internal")):
        return 403, "application/json; charset=utf-8", json.dumps({"error": "forbidden"}) + "\n"
    return 404, "application/json; charset=utf-8", json.dumps({"error": "not found", "path": path}) + "\n"


# What the assistant "says" in the README picture. A fixed reply, chosen by what
# was asked: this is a stand-in for a model, not one, and the README says so.
ASSISTANT_REPLIES = (
    (
        ("discard", "throw away", "match origin", "match the remote"),
        "That throws away everything you haven't committed. To make your branch match "
        "the remote exactly:\n\n"
        "```bash\ngit fetch origin\ngit reset --hard origin/main\n```\n\n"
        "Run `git status` first if you're not sure what would be lost.",
    ),
)
ASSISTANT_DEFAULT = "I'm a stand-in for a model, used to take screenshots."


def assistant_reply(request_body):
    """The text of a chat-completions reply to the last user message in the request."""
    try:
        messages = json.loads(request_body or b"{}").get("messages", [])
    except ValueError:
        messages = []
    asked = ""
    for message in messages:
        if message.get("role") == "user":
            asked = str(message.get("content", ""))
    # Only the request itself, not the context lines (directory, branch) above it.
    asked = asked.rsplit("Request:", 1)[-1].lower()
    for keywords, reply in ASSISTANT_REPLIES:
        if any(word in asked for word in keywords):
            return reply
    return ASSISTANT_DEFAULT


def make_handler(origin, log_path, detail_path=""):
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

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            path = urlsplit(self.path).path.rstrip("/")
            if not path.endswith("/chat/completions"):
                self.send_json(404, {"error": "not found", "path": path})
                return
            self.send_json(200, {
                "id": "chatcmpl-sample",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": "sample",
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": assistant_reply(body)},
                    "finish_reason": "stop",
                }],
            })

        def send_json(self, status, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def respond(self, send_body):
            path = urlsplit(self.path).path
            status, content_type, body = route(path, origin)
            # Pages are text; the pictures and files the sample page links to are bytes.
            data = body if isinstance(body, bytes) else body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Request-Id", uuid.uuid4().hex[:12])
            self.end_headers()
            if send_body:
                self.wfile.write(data)

        def log_request(self, code="-", size="-"):
            if detail_path:
                # Who asked, and what they sent along: the crawl is checked
                # against this, not against a picture.
                detail = "{} {} {} {} agent={!r} accept={!r} cookie={} authorization={} referer={!r}\n".format(
                    time.strftime("%H:%M:%S"), self.command, self.path, code,
                    self.headers.get("User-Agent", ""), self.headers.get("Accept", ""),
                    "yes" if self.headers.get("Cookie") else "no",
                    "yes" if self.headers.get("Authorization") else "no",
                    self.headers.get("Referer", ""),
                )
                with open(detail_path, "a", encoding="utf-8") as handle:
                    handle.write(detail)
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
    parser.add_argument("--detail-log", default="")
    args = parser.parse_args()

    origin = ORIGIN.format(port=args.port)
    handler = make_handler(origin, args.log, args.detail_log)
    for path in (args.log, args.detail_log):
        if path:
            open(path, "w", encoding="utf-8").close()
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
