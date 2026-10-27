"""Fake OpenAI-compatible backends and a fake Moira for the contract test.

Stdlib only (the LiteLLM image has python, no curl, no test deps). One server
plays every upstream so each leg is recognised by the `model` field LiteLLM
sends (litellm_params.model minus the provider prefix):

- POST /decide                Moira decision per request envelope: moira/flash
                              refuses (429 + retry_after_s), moira/strong
                              routes to a failing MiMo leg with the matching
                              Step leg as request fallback.
- POST /v1/chat/completions   records the body; MiMo legs answer 429 so the
                              router falls back, everything else answers a
                              canned completion (SSE when body["stream"]).
- POST /v1/responses          same, canned Responses object.
- GET  /requests              recorded backend bodies, in call order.
- POST /reset                 clear records between scenarios.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 9000
REQUESTS = []

# Legs that answer 429 so the router falls back to the paired step-* leg.
FAILING = {"test-mimo-chat", "test-mimo-stream", "test-mimo-resp"}

SCENARIOS = {
    "chat": ("test/mimo-chat", ["test/step-chat"]),
    "stream": ("test/mimo-stream", ["test/step-stream"]),
    "responses": ("test/mimo-resp", ["test/step-resp"]),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the test output readable

    def _json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/requests":
            return self._json(200, REQUESTS)
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        body = json.loads(raw or b"{}")
        if self.path == "/decide":
            return self._decide(body)
        if self.path == "/reset":
            REQUESTS.clear()
            return self._json(200, {"ok": True})
        if self.path in ("/v1/chat/completions", "/chat/completions",
                         "/v1/responses", "/responses"):
            return self._completion(self.path, body)
        self._json(404, {"error": {"message": "not found"}})

    def _decide(self, body):
        if body.get("model") == "moira/flash":
            return self._json(200, {
                "action": "refuse",
                "status": 429,
                "body": {"error": {"type": "tier_exhausted",
                                   "message": "quota exhausted"}},
                "retry_after_s": 42,
            })
        scenario = "responses" if body.get("api") == "responses" else (
            "stream" if body.get("stream") else "chat"
        )
        model, fallbacks = SCENARIOS[scenario]
        return self._json(200, {"action": "route", "model": model,
                                "fallbacks": fallbacks})

    def _completion(self, path, body):
        model = body.get("model") or ""
        REQUESTS.append({"path": path, "body": body})
        if model in FAILING:
            return self._json(429, {"error": {
                "message": f"{model} quota exhausted",
                "type": "rate_limit_error", "code": 429,
            }})
        if path.endswith("/responses"):
            return self._json(200, {
                "id": "resp_test", "object": "response", "created_at": 1,
                "model": model, "status": "completed",
                "output": [{
                    "id": "msg_test", "type": "message", "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "ok",
                                 "annotations": []}],
                }],
                "usage": {"input_tokens": 1, "output_tokens": 1,
                          "total_tokens": 2},
            })
        if body.get("stream"):
            chunks = [
                {"id": "chatcmpl_test", "object": "chat.completion.chunk",
                 "created": 1, "model": model, "choices": [{"index": 0,
                  "delta": {"role": "assistant", "content": "ok"},
                  "finish_reason": None}]},
                {"id": "chatcmpl_test", "object": "chat.completion.chunk",
                 "created": 1, "model": model, "choices": [{"index": 0,
                  "delta": {}, "finish_reason": "stop"}]},
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            return None
        return self._json(200, {
            "id": "chatcmpl_test", "object": "chat.completion", "created": 1,
            "model": model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "ok"}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                      "total_tokens": 2},
        })


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
