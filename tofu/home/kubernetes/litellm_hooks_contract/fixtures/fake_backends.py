"""Fake OpenAI-compatible backends and a fake Moira for the contract test.

Stdlib only (the LiteLLM image has python, no curl, no test deps). One server
plays every upstream so each leg is recognised by the `model` field LiteLLM
sends (litellm_params.model minus the provider prefix):

- POST /decide                Moira decision per request envelope: moira/flash
                              refuses (429 + retry_after_s), moira/strong
                              routes to a failing MiMo leg with the matching
                              Step leg as request fallback; moira/frontier,
                              moira/balanced and moira/cyber route to
                              content-filtered legs (see FILTER_ROUTES).
- POST /report                records Moira reports (GET /reports lists them).
- POST /v1/chat/completions   records the body; MiMo legs answer 429 so the
                              router falls back, filter legs end with
                              finish_reason content_filter (early: after
                              reasoning only; late: after answer text),
                              everything else answers a canned completion
                              (SSE when body["stream"]).
- POST /v1/responses          same, canned Responses object.
- GET  /requests              recorded backend bodies, in call order.
- POST /reset                 clear records between scenarios.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 9000
REQUESTS = []
REPORTS = []

# Legs that answer 429 so the router falls back to the paired step-* leg.
FAILING = {"test-mimo-chat", "test-mimo-stream", "test-mimo-resp"}
# Legs whose answer ends with finish_reason content_filter before any answer
# text (reasoning only) or after some.
FILTER_EARLY = {"test-filter-early", "test-filter-early-b"}
FILTER_LATE = {"test-filter-late"}

SCENARIOS = {
    "chat": ("test/mimo-chat", ["test/step-chat"]),
    "stream": ("test/mimo-stream", ["test/step-stream"]),
    "responses": ("test/mimo-resp", ["test/step-resp"]),
}

# Requested tier -> (model, fallbacks) for the content_filter scenarios.
FILTER_ROUTES = {
    "moira/frontier": ("test/filter-early", ["test/filter-early-b", "test/step-stream"]),
    "moira/balanced": ("test/filter-late", ["test/step-stream"]),
    "moira/cyber": ("test/filter-early", ["test/step-chat"]),
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
        if self.path == "/reports":
            return self._json(200, REPORTS)
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        body = json.loads(raw or b"{}")
        if self.path == "/decide":
            return self._decide(body)
        if self.path == "/report":
            REPORTS.append(body)
            self.send_response(204)
            self.end_headers()
            return None
        if self.path == "/reset":
            REQUESTS.clear()
            REPORTS.clear()
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
        if body.get("model") in FILTER_ROUTES:
            model, fallbacks = FILTER_ROUTES[body["model"]]
            # Real Moira always sends efforts; MoiraRouter keeps them as
            # metadata.moira_efforts, which marks the request Moira-routed.
            efforts = {m: None for m in [model, *fallbacks]}
            return self._json(200, {"action": "route", "model": model,
                                    "fallbacks": fallbacks, "efforts": efforts})
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
            if model in FILTER_EARLY:
                first = {"role": "assistant", "reasoning_content": "thinking"}
            elif model in FILTER_LATE:
                first = {"role": "assistant", "content": "partial"}
            else:
                first = {"role": "assistant", "content": "ok"}
            finish = "content_filter" if model in FILTER_EARLY | FILTER_LATE else "stop"
            chunks = [
                {"id": "chatcmpl_test", "object": "chat.completion.chunk",
                 "created": 1, "model": model, "choices": [{"index": 0,
                  "delta": first, "finish_reason": None}]},
                {"id": "chatcmpl_test", "object": "chat.completion.chunk",
                 "created": 1, "model": model, "choices": [{"index": 0,
                  "delta": {}, "finish_reason": finish}]},
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            return None
        filtered = model in FILTER_EARLY | FILTER_LATE
        return self._json(200, {
            "id": "chatcmpl_test", "object": "chat.completion", "created": 1,
            "model": model,
            "choices": [{"index": 0,
                         "finish_reason": "content_filter" if filtered else "stop",
                         "message": {"role": "assistant", "content": "" if filtered else "ok"}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                      "total_tokens": 2},
        })


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
