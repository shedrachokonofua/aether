#!/usr/bin/env python3
"""Assertions for the litellm_hooks deployment-adapter contract.

Run inside the pinned LiteLLM image by fixtures/lab.sh. Proves, against the
real litellm_hooks.py and fake backends:

1. per-attempt adaptation: the primary MiMo attempt gets a softened
   tool_choice and the primary clamp while the fallback Step attempt receives
   the client's original forced tool_choice and its own clamp -- for chat,
   streaming chat, and the Responses API;
2. a Moira refuse reaches the client as 429 with Retry-After;
3. a no-op (original request untouched) when model_info lacks the keys
   or is absent;
4. every adaptation is visible in the proxy log at INFO with the deployment
   name and what changed (no prompt content).

Exit 0 = all assertions passed; 1 = at least one failed.
"""

import json
import sys
import urllib.error
import urllib.request

PROXY = "http://127.0.0.1:4000"
FAKE = "http://127.0.0.1:9000"
KEY = "sk-contract-test"

FORCED = {"type": "function", "function": {"name": "submit"}}
TOOLS = [{"type": "function",
          "function": {"name": "submit",
                       "parameters": {"type": "object", "properties": {}}}}]

failures = []


def check(condition, message):
    if condition:
        print(f"  ok: {message}")
    else:
        print(f"  FAIL: {message}")
        failures.append(message)


def post(path, payload):
    request = urllib.request.Request(
        PROXY + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {KEY}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, headers_of(response), response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, headers_of(error), error.read().decode()


def headers_of(message):
    return {k.lower(): v for k, v in dict(message.headers).items()}


def fake_post(path):
    request = urllib.request.Request(FAKE + path, data=b"", method="POST")
    urllib.request.urlopen(request, timeout=10).read()


def backend_calls():
    with urllib.request.urlopen(FAKE + "/requests", timeout=10) as response:
        return json.load(response)


def sent_cap(body):
    for key in ("max_output_tokens", "max_completion_tokens", "max_tokens"):
        if key in body:
            return body[key]
    return None


def forced_name(tool_choice):
    try:
        return tool_choice["function"]["name"]
    except (KeyError, TypeError):
        return None


def legs(mimo_model, step_model, path_suffix):
    calls = [c for c in backend_calls() if c["path"].endswith(path_suffix)]
    mimo = [c["body"] for c in calls if c["body"].get("model") == mimo_model]
    step = [c["body"] for c in calls if c["body"].get("model") == step_model]
    check(bool(mimo), f"{mimo_model}: backend saw at least one attempt")
    check(bool(step), f"{step_model}: fallback saw at least one attempt")
    return mimo, step


def assert_per_attempt(tag, mimo_model, step_model, path_suffix, original_tool_choice):
    mimo, step = legs(mimo_model, step_model, path_suffix)
    for body in mimo:
        check(body.get("tool_choice") == "auto",
              f"{tag} primary ({mimo_model}): tool_choice softened to 'auto'")
        check(sent_cap(body) == 8192,
              f"{tag} primary ({mimo_model}): token cap clamped to 8192, got {sent_cap(body)}")
    for body in step:
        check(body.get("tool_choice") == original_tool_choice,
              f"{tag} fallback ({step_model}): original tool_choice preserved, got {body.get('tool_choice')!r}")
        check(sent_cap(body) == 32768,
              f"{tag} fallback ({step_model}): clamped to its own cap 32768, got {sent_cap(body)}")


def scenario_chat():
    print("chat: forced tool_choice dict + max_tokens over cap, MiMo primary -> Step fallback")
    fake_post("/reset")
    status, _, text = post("/v1/chat/completions", {
        "model": "moira/strong",
        "messages": [{"role": "user", "content": "hi"}],
        "tools": TOOLS,
        "tool_choice": FORCED,
        "max_tokens": 200000,
    })
    check(status == 200, f"chat: request succeeded via fallback, got {status}: {text[:300]}")
    assert_per_attempt("chat", "test-mimo-chat", "test-step-chat",
                       "chat/completions", FORCED)


def scenario_stream():
    print("streaming chat: tool_choice 'required' + max_completion_tokens over cap")
    fake_post("/reset")
    status, headers, body_text = post("/v1/chat/completions", {
        "model": "moira/strong",
        "messages": [{"role": "user", "content": "hi"}],
        "tools": TOOLS,
        "tool_choice": "required",
        "max_completion_tokens": 200000,
        "stream": True,
    })
    check(status == 200, f"stream: request succeeded via fallback, got {status}: {body_text[:300]}")
    check("text/event-stream" in headers.get("content-type", ""),
          f"stream: response is SSE, got {headers.get('content-type')!r}")
    check("[DONE]" in body_text, "stream: response stream completed")
    assert_per_attempt("stream", "test-mimo-stream", "test-step-stream",
                       "chat/completions", "required")


def scenario_responses():
    print("Responses API: forced tool_choice dict + max_output_tokens over cap")
    fake_post("/reset")
    status, _, text = post("/v1/responses", {
        "model": "moira/strong",
        "input": "hi",
        "tools": TOOLS,
        "tool_choice": FORCED,
        "max_output_tokens": 200000,
        # OMP sends client metadata; the deployment's model_info lives in
        # litellm_metadata for Responses calls and must still be found.
        "metadata": {"session_id": "contract-test"},
    })
    check(status == 200, f"responses: request succeeded via fallback, got {status}: {text[:300]}")
    assert_per_attempt("responses", "test-mimo-resp", "test-step-resp",
                       "/responses", FORCED)


def scenario_refuse():
    print("Moira refuse: client sees the 429 with Retry-After")
    fake_post("/reset")
    status, headers, text = post("/v1/chat/completions", {
        "model": "moira/flash",
        "messages": [{"role": "user", "content": "hi"}],
        "tools": TOOLS,
        "tool_choice": FORCED,
        "max_tokens": 200000,
    })
    check(status == 429, f"refuse: client got 429, got {status}: {text[:300]}")
    check(headers.get("retry-after") == "42",
          f"refuse: Retry-After surfaced, got {headers.get('retry-after')!r}")
    check(backend_calls() == [], "refuse: no backend attempt after a refuse")


def scenario_noop():
    print("no-op: model_info lacking the keys (or absent) leaves the request alone")
    for model in ("test/plain", "test/noinfo"):
        fake_post("/reset")
        status, _, text = post("/v1/chat/completions", {
            "model": model,
            "messages": [{"role": "user", "content": "hi"}],
            "tools": TOOLS,
            "tool_choice": FORCED,
            "max_tokens": 200000,
        })
        check(status == 200, f"{model}: request succeeded, got {status}: {text[:300]}")
        calls = backend_calls()
        check(len(calls) == 1, f"{model}: exactly one backend attempt, got {len(calls)}")
        if not calls:
            continue
        body = calls[0]["body"]
        check(body.get("tool_choice") == FORCED,
              f"{model}: forced tool_choice untouched, got {body.get('tool_choice')!r}")
        check(sent_cap(body) == 200000,
              f"{model}: token cap untouched, got {sent_cap(body)}")


def scenario_pinned_effort():
    print("reasoning_effort_override: absent, 'none' and 'low' all reach the backend as 'high'")
    for sent in (None, "none", "low"):
        fake_post("/reset")
        payload = {"model": "test/pinned-effort", "messages": [{"role": "user", "content": "hi"}]}
        if sent is not None:
            payload["reasoning_effort"] = sent
        status, _, text = post("/v1/chat/completions", payload)
        check(status == 200, f"pinned effort ({sent!r}): request succeeded, got {status}: {text[:300]}")
        calls = backend_calls()
        check(len(calls) == 1, f"pinned effort ({sent!r}): exactly one backend attempt, got {len(calls)}")
        if calls:
            got = calls[0]["body"].get("reasoning_effort")
            check(got == "high", f"pinned effort ({sent!r}): backend got reasoning_effort 'high', got {got!r}")


def scenario_logs():
    print("INFO log: every adaptation is visible with deployment name + change")
    try:
        with open("/tmp/litellm.log", errors="ignore") as handle:
            lines = [ln for ln in handle if "deployment_adapter" in ln]
    except OSError as error:
        check(False, f"log: /tmp/litellm.log readable ({error})")
        return
    for line in lines:
        print(f"    log: {line.rstrip()}")
    joined = "".join(lines)
    check("softened forced tool_choice" in joined,
          "log: tool_choice softening logged")
    check("clamped max_tokens 200000 -> 8192" in joined
          or "clamped max_completion_tokens 200000 -> 8192" in joined,
          "log: primary clamp logged with the clamped key and both values")
    check("clamped max_output_tokens 200000 -> 32768" in joined,
          "log: fallback clamp logged with the clamped key and both values")
    check(all("test/" in ln or "test-" in ln for ln in lines) and bool(lines),
          "log: each adaptation line names the deployment")


def reports():
    with urllib.request.urlopen(FAKE + "/reports", timeout=10) as response:
        return json.load(response)


def sse_events(body_text):
    events = []
    for line in body_text.splitlines():
        if line.startswith("data: ") and line != "data: [DONE]":
            try:
                events.append(json.loads(line[len("data: "):]))
            except ValueError:
                pass
    return events


def finishes(events):
    return [c.get("finish_reason") for e in events for c in e.get("choices") or [] if c.get("finish_reason")]


def answer_text(events):
    return "".join((c.get("delta") or {}).get("content") or "" for e in events for c in e.get("choices") or [])


def called_models():
    return [c["body"].get("model") for c in backend_calls() if c["path"].endswith("chat/completions")]


def scenario_filter_early():
    print("content_filter before any answer: served by the next fallback that answers, each refusal reported")
    fake_post("/reset")
    status, _, body_text = post("/v1/chat/completions", {
        "model": "moira/frontier", "user": "s-early", "stream": True,
        "messages": [{"role": "user", "content": "hi"}],
    })
    events = sse_events(body_text)
    check(status == 200, f"filter early: request succeeded, got {status}: {body_text[:300]}")
    check("content_filter" not in finishes(events), f"filter early: client never sees content_filter, got {finishes(events)}")
    check(finishes(events)[-1:] == ["stop"], f"filter early: the answer finishes with stop, got {finishes(events)}")
    check(answer_text(events) == "ok", f"filter early: the fallback's answer is served, got {answer_text(events)!r}")
    check(called_models() == ["test-filter-early", "test-filter-early-b", "test-step-stream"],
          f"filter early: primary, filtered fallback, then the answering one, got {called_models()}")
    check(reports() == [
        {"model": "test/filter-early", "reason": "content_filter", "session_id": "s-early"},
        {"model": "test/filter-early-b", "reason": "content_filter", "session_id": "s-early"},
    ], f"filter early: both refusals reported with the session, got {reports()}")


def scenario_filter_late():
    print("content_filter after answer text: the stream errors instead of truncating, reported")
    fake_post("/reset")
    status, _, body_text = post("/v1/chat/completions", {
        "model": "moira/balanced", "user": "s-late", "stream": True,
        "messages": [{"role": "user", "content": "hi"}],
    })
    events = sse_events(body_text)
    check(any("error" in e for e in events) or status >= 500,
          f"filter late: the client sees an error, got {status}: {body_text[:300]}")
    check("content_filter" not in finishes(events), f"filter late: no silent content_filter finish, got {finishes(events)}")
    check(called_models() == ["test-filter-late"], f"filter late: no second answer spliced in, got {called_models()}")
    check(reports() == [{"model": "test/filter-late", "reason": "content_filter", "session_id": "s-late"}],
          f"filter late: refusal reported, got {reports()}")


def scenario_filter_nonstream():
    print("content_filter on a non-streaming answer: replaced by the fallback's answer, reported")
    fake_post("/reset")
    status, _, body_text = post("/v1/chat/completions", {
        "model": "moira/cyber", "user": "s-chat",
        "messages": [{"role": "user", "content": "hi"}],
    })
    body = json.loads(body_text) if status == 200 else {}
    choice = (body.get("choices") or [{}])[0]
    check(status == 200, f"filter non-stream: request succeeded, got {status}: {body_text[:300]}")
    check(choice.get("finish_reason") == "stop" and (choice.get("message") or {}).get("content") == "ok",
          f"filter non-stream: the fallback's answer is returned, got {choice}")
    check(reports() == [{"model": "test/filter-early", "reason": "content_filter", "session_id": "s-chat"}],
          f"filter non-stream: refusal reported, got {reports()}")


def scenario_filter_unrouted():
    print("content_filter on a request Moira did not route: passed through untouched, not reported")
    fake_post("/reset")
    status, _, body_text = post("/v1/chat/completions", {
        "model": "test/filter-early", "user": "s-direct", "stream": True,
        "messages": [{"role": "user", "content": "hi"}],
    })
    events = sse_events(body_text)
    check(status == 200 and finishes(events) == ["content_filter"],
          f"filter unrouted: upstream finish passes through, got {status} {finishes(events)}")
    check(called_models() == ["test-filter-early"], f"filter unrouted: no failover, got {called_models()}")
    check(reports() == [], f"filter unrouted: nothing reported, got {reports()}")


def main():
    scenario_chat()
    scenario_stream()
    scenario_responses()
    scenario_refuse()
    scenario_noop()
    scenario_pinned_effort()
    scenario_logs()
    scenario_filter_early()
    scenario_filter_late()
    scenario_filter_nonstream()
    scenario_filter_unrouted()
    if failures:
        print(f"\n{len(failures)} assertion(s) FAILED", file=sys.stderr)
        return 1
    print("\nall contract assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
