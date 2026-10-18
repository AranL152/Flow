#!/usr/bin/env python3
"""Generated speech → real Rust/Whisper/LLM stream. No files attached or sent."""
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
lib = ctypes.CDLL(str(ROOT / "flow-core/target/debug/libflow.dylib"))
lib.flow_init.argtypes = [ctypes.c_char_p]
lib.flow_init.restype = ctypes.c_void_p
lib.flow_destroy.argtypes = [ctypes.c_void_p]
lib.flow_free_string.argtypes = [ctypes.c_void_p]
lib.flow_add_shortcut.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.flow_add_shortcut.restype = ctypes.c_bool
lib.flow_get_recent_transcriptions_json.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.flow_get_recent_transcriptions_json.restype = ctypes.c_void_p
lib.flow_get_attachment_plan.argtypes = [ctypes.c_void_p]
lib.flow_get_attachment_plan.restype = ctypes.c_void_p
callback_type = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_char_p, ctypes.c_void_p)
lib.flow_transcribe_audio_stream.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p, callback_type, ctypes.c_void_p]
lib.flow_transcribe_audio_stream.restype = ctypes.c_void_p


def take(pointer):
    if not pointer:
        return None
    try:
        return ctypes.string_at(pointer).decode()
    finally:
        lib.flow_free_string(pointer)


def main():
    cases = [
        {"text": "Here's the deck. Flow, attach the PDF I just downloaded.", "source": "recent_download", "kind": "pdf"},
        {"text": "Flow, attach the image on my clipboard.", "source": "clipboard", "kind": "image", "empty": True},
        {"text": "Please attach the invoice when you reply.", "literal": True},
        {"text": "Flow, attach the one I meant earlier.", "clarification": True, "empty": True},
        {"text": "You can reach me at my email. Flow, attach the PDF I just downloaded.", "source": "recent_download", "kind": "pdf", "snippet": True},
        {"text": "Here's the presentation. Flow, find my robotics presentation.", "source": "file_search", "kind": "presentation", "query": "robotics"},
        {"text": "Flow, find the beach trip image.", "source": "file_search", "kind": "image", "query": "beach trip", "empty": True},
    ]
    results = []
    engine = lib.flow_init(b":memory:")
    if not engine:
        raise RuntimeError("Couldn't initialize fixture engine")
    try:
        assert lib.flow_add_shortcut(engine, b"my email", b"aran@example.test")
        with tempfile.TemporaryDirectory(prefix="flow-attachment-stream-") as directory:
            for index, case in enumerate(cases):
                audio = Path(directory) / f"{index}.aiff"
                wav = Path(directory) / f"{index}.wav"
                subprocess.run(["say", "-v", "Samantha", "-r", "155", "-o", str(audio), case["text"]], check=True)
                subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(audio), str(wav)], check=True)
                with wave.open(str(wav), "rb") as source:
                    pcm = source.readframes(source.getnframes())
                chunks = []

                @callback_type
                def receive(delta, _):
                    if delta:
                        chunks.append(delta.decode())
                    return True

                buffer = ctypes.create_string_buffer(pcm)
                output = take(lib.flow_transcribe_audio_stream(engine, buffer, len(pcm), 16000, b"Messages", b"Alex", receive, None))
                history = json.loads(take(lib.flow_get_recent_transcriptions_json(engine, 1)) or "[]")
                raw_text = history[0].get("raw_text") if history else None
                metadata = take(lib.flow_get_attachment_plan(engine))
                plan = json.loads(metadata) if metadata else None
                checks = {"completed": output is not None, "deltas_match_final": "".join(chunks).strip() == output}
                if case.get("literal"):
                    checks["recipient_request_is_not_action"] = plan is None
                    checks["recipient_request_preserved"] = "invoice" in (output or "").lower() and any(word in (output or "").lower() for word in ["reply", "response"])
                else:
                    checks["separate_plan"] = plan is not None
                    checks["no_command_in_output"] = "flow" not in (output or "").lower() and "downloaded" not in (output or "").lower()
                    if case.get("clarification"):
                        checks["clarifies_without_action"] = bool(plan and plan.get("clarification") and not plan.get("request"))
                    else:
                        expected = {"source": case["source"], "kind": case["kind"]}
                        if "query" in case:
                            expected["query"] = case["query"]
                        checks["correct_source_and_type"] = bool(plan and plan.get("request") == expected)
                if case.get("empty"):
                    checks["no_invented_message"] = output == "" and not chunks
                if case.get("snippet"):
                    checks["configured_email_preserved"] = "aran@example.test" in (output or "")
                results.append({"input": case["text"], "raw_transcription": raw_text, "output": output, "chunks": chunks, "plan": plan, "checks": checks, "passed": all(checks.values())})
        report = {"scope": "Generated speech, real Rust + deployed Workers AI pipeline, isolated user. No actual Downloads selection, Messages insertion or sending.",
            "passed": all(r["passed"] for r in results), "cases": len(results), "results": results}
        (ROOT / "review/attachment-stream-verification.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        if not report["passed"]:
            raise SystemExit(1)
    finally:
        lib.flow_destroy(engine)


if __name__ == "__main__":
    main()
