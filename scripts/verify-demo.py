#!/usr/bin/env python3
"""Exercise the Rust FFI + real streaming worker using synthetic messages only.
No microphone, private contacts, or production database. An inference test, not
a comparison with Wispr and not a statistically representative latency benchmark.
"""
import argparse
import ctypes
import json
from pathlib import Path
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:8787/format-stream")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    lib = ctypes.CDLL(str(ROOT / "flow-core/target/debug/libflow.dylib"))
    lib.flow_init.argtypes = [ctypes.c_char_p]
    lib.flow_init.restype = ctypes.c_void_p
    lib.flow_demo_dispatch.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.flow_demo_dispatch.restype = ctypes.c_void_p
    lib.flow_free_string.argtypes = [ctypes.c_void_p]
    lib.flow_destroy.argtypes = [ctypes.c_void_p]
    handle = lib.flow_init(b":memory:")
    if not handle:
        raise RuntimeError("Rust engine could not initialize")
    results = []

    def call(**request):
        ptr = lib.flow_demo_dispatch(handle, json.dumps(request).encode())
        if not ptr:
            raise RuntimeError("No FFI response")
        try:
            response = json.loads(ctypes.string_at(ptr))
        finally:
            lib.flow_free_string(ptr)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response

    def format_message(label, who, said, context="Project review"):
        prepared = call(op="prepare", recipient_id=who, said=said, context=context)
        request = urllib.request.Request(args.endpoint, json.dumps(prepared["request"]).encode(),
                                         {"Content-Type": "application/json", "Accept": "text/event-stream"})
        start = time.monotonic()
        text, done, event, data = "", None, "", []
        first_token_ms, chunks = None, 0
        with urllib.request.urlopen(request, timeout=60) as response:
            if "text/event-stream" not in response.headers.get("Content-Type", ""):
                raise RuntimeError("Response was not SSE")
            for raw in response:
                line = raw.decode().rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    data.append(line[5:].lstrip())
                elif not line and data:
                    payload = json.loads("\n".join(data)); data = []
                    if event == "error":
                        raise RuntimeError(payload["error"])
                    if event == "delta":
                        text += payload["text"]; chunks += 1
                        if first_token_ms is None:
                            first_token_ms = round((time.monotonic() - start) * 1000)
                    elif event == "done":
                        done = payload["text"]
                        break
        if not done or done != text.strip() or chunks < 1:
            raise RuntimeError("Incomplete or inconsistent stream")
        receipt = call(op="complete", ticket=prepared["ticket"], output=done)
        accepted = receipt["output"]
        row = {"case": label, "recipient": who, "context": context, "input": said,
               "output": accepted, "stream_output": done, "preserved_original": receipt["preserved_original"], "evidence_ids": prepared["evidence_ids"], "chunks": chunks,
               "first_token_ms": first_token_ms, "complete_ms": round((time.monotonic()-start)*1000)}
        results.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        return prepared["ticket"], accepted

    checks = {}
    try:
        _, before = format_message("held-out baseline", "alex", "Can you check the slides tomorrow?")
        ticket, _ = format_message("message to edit", "alex", "Can you check the draft?")
        correction = "got a sec to check the draft?"
        receipt = call(op="send", ticket=ticket, text=correction)
        checks["edit_recorded"] = receipt["edited"]
        _, after = format_message("held-out after edit", "alex", "Can you check the slides tomorrow?")
        checks["held_out_uses_learned_phrasing"] = "got a sec" in after.lower()
        checks["held_out_preserves_content"] = "slides" in after.lower() and "tomorrow" in after.lower() and "draft" not in after.lower()
        _, mum = format_message("recipient isolation", "mum", "Can you check the slides tomorrow?")
        checks["recipient_isolation"] = not results[-1]["evidence_ids"] and "got a sec" not in mum.lower()
        # A serious-context emoji deletion is explicitly not a universal ban.
        ticket, _ = format_message("serious message", "alex", "The deadline moved to Friday. Add a worried emoji.", "Serious update")
        call(op="send", ticket=ticket, text="the deadline moved to Friday")
        _, celebration = format_message("emoji remains allowed", "alex", "Congratulations on the launch! Add a party emoji.", "Celebration")
        checks["emoji_allowed_in_new_context"] = any(c in celebration for c in "🎉🥳🎊") and not results[-1]["evidence_ids"]
        call(op="forget", recipient_id="alex", note_id=receipt["note"]["id"])
        forgotten = call(op="prepare", recipient_id="alex", said="Can you review this?", context="Project review")
        checks["forget_removes_evidence"] = not forgotten["evidence_ids"]
        checks["multiple_real_stream_chunks"] = all(r["chunks"] > 1 for r in results)
    finally:
        lib.flow_destroy(handle)
    report = {"kind": "synthetic live integration test", "checks": checks, "results": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"checks": checks}, indent=2), flush=True)
    if not all(checks.values()):
        raise SystemExit("A learning check failed; inspect the actual outputs before recording the demo.")


if __name__ == "__main__":
    main()
