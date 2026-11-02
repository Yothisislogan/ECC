"""Minimal Anthropic Messages API stub for checking Claude Code inside the sandbox.
Logs every request path so we can see exactly what the harness calls."""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLY = "Hello from the sandboxed stub model."


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[stub] " + (fmt % args) + "\n")  # noqa: UP031 (stdlib log format)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self._json(
                200,
                {
                    "data": [
                        {
                            "id": "local-model",
                            "type": "model",
                            "display_name": "local-model",
                        }
                    ],
                    "has_more": False,
                    "first_id": "local-model",
                    "last_id": "local-model",
                },
            )
        else:
            self._json(200, {"status": "ok"})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        auth = (
            "bearer"
            if self.headers.get("authorization", "").startswith("Bearer ")
            else "none"
        )
        sys.stderr.write(
            f"[stub] auth={auth} model={req.get('model')} stream={req.get('stream')}\n"
        )
        if self.path.startswith("/v1/messages/count_tokens"):
            return self._json(200, {"input_tokens": 100})
        if not self.path.startswith("/v1/messages"):
            return self._json(
                404,
                {
                    "type": "error",
                    "error": {"type": "not_found_error", "message": self.path},
                },
            )
        usage = {"input_tokens": 10, "output_tokens": 8}
        msg = {
            "id": "msg_stub",
            "type": "message",
            "role": "assistant",
            "model": req.get("model", "local-model"),
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": usage,
        }
        if not req.get("stream"):
            msg["content"] = [{"type": "text", "text": REPLY}]
            msg["stop_reason"] = "end_turn"
            return self._json(200, msg)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def ev(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        ev("message_start", {"type": "message_start", "message": msg})
        ev(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
        )
        ev(
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": REPLY},
            },
        )
        ev("content_block_stop", {"type": "content_block_stop", "index": 0})
        ev(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 8},
            },
        )
        ev("message_stop", {"type": "message_stop"})


ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
