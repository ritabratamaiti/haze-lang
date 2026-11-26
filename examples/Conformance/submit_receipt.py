"""Local one-operation form fixture. Restart the process for each experiment.

python examples/Conformance/submit_receipt.py before
python examples/Conformance/submit_receipt.py after --keyed
"""

import argparse
import json
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock


PAGE = b"""<!doctype html><html lang="en"><meta charset="utf-8">
<title>Save one draft</title><h1>Save one draft</h1>
<form><input aria-label="Draft text" value="Release checklist" readonly>
<button>Save draft</button></form><p role="status">Ready</p>
<a href="/audit" target="_blank" rel="noopener">Read the test server's count</a>
<script>
const button = document.querySelector("button"), status = document.querySelector("[role=status]");
document.querySelector("form").onsubmit = async (e) => {
  e.preventDefault();
  button.disabled = true;
  try {
    const r = await fetch("/save", {method: "POST", headers: {"Idempotency-Key": "draft-1"},
      body: document.querySelector("input").value});
    status.textContent = r.ok ? "Receipt received" : "HTTP " + r.status;
  } catch (e) {
    status.textContent = "No receipt (" + e.name + ")";
  } finally { button.disabled = false; }
};
</script></html>"""


def fixture(cut, keyed):
    """Return a loopback-only server with isolated, in-memory state."""
    lock, keys, rows = Lock(), set(), []
    attempts = 0

    class Handler(BaseHTTPRequestHandler):
        def send_body(self, mime, body):
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self.send_body("text/html; charset=utf-8", PAGE)
            elif self.path == "/audit":
                with lock:
                    body = json.dumps({"requests": attempts, "saves": len(rows), "rows": rows}).encode()
                self.send_body("application/json", body)
            else:
                self.send_error(404)

        def do_POST(self):
            nonlocal attempts
            if self.path != "/save":
                self.send_error(404)
                return
            draft = b"Release checklist"
            if self.headers.get("Content-Length") != str(len(draft)) or self.rfile.read(len(draft)) != draft:
                self.send_error(400, "This fixture accepts only the draft shown in the form")
                return
            key = self.headers.get("Idempotency-Key")
            with lock:
                attempts += 1
                first = attempts == 1
                if not (first and cut == "before"):
                    if not keyed or not key or key not in keys:
                        rows.append(draft.decode())
                        if key:
                            keys.add(key)
            if first:
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            self.send_body("text/plain", b"saved")

    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cut", choices=("before", "after"))
    parser.add_argument("--keyed", action="store_true", help="deduplicate saves with the same operation key")
    args = parser.parse_args()
    with fixture(args.cut, args.keyed) as server:
        print(f"Open http://127.0.0.1:{server.server_port}/ and click Save draft twice.", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
