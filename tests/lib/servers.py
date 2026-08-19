"""A server that answers every request with a redirect to the real artifact
store: if the plugin followed redirects an install through it would succeed,
so a failure proves redirects are refused, not merely that the target was down.
Every request path is appended to a log so a test can prove the plugin
actually reached this server."""
import http.client
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer


@contextmanager
def redirect_server(port, target, log_path):
    class Handler(BaseHTTPRequestHandler):
        def _redirect(self):
            with open(log_path, "a") as f:
                f.write(self.path + "\n")
            self.send_response(302)
            self.send_header("Location", target + self.path)
            self.end_headers()

        do_GET = _redirect
        do_HEAD = _redirect

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        _wait_until_answering(port)
        yield server
    finally:
        server.shutdown()
        server.server_close()


def _wait_until_answering(port, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/ready")
            if conn.getresponse().status == 302:
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError(f"redirect server did not come up on 127.0.0.1:{port}")
