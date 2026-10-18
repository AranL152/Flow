#!/usr/bin/env python3
"""Exercise the deployed ASR + LLM SSE endpoint with generated audio only."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PHRASE = "Can you check the slides tomorrow"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="https://base10-proxy.old-resonance-ed75.workers.dev/transcribe-stream")
    parser.add_argument("--output", type=Path, default=ROOT/"review/dictation-stream-verification.json")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="flow-stream-") as folder:
        audio = Path(folder)/"speech.aiff"
        wav = Path(folder)/"speech.wav"
        subprocess.run(["say", "-v", "Samantha", "-r", "155", "-o", str(audio), PHRASE], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(audio), str(wav)], check=True)
        payload = {"whisper_input": {"audio": {"audio_b64": base64.b64encode(wav.read_bytes()).decode()},
            "whisper_params": {"audio_language": "en"}}, "completion": {"mode": "casual", "app_context": "Messages",
            "shortcuts_triggered": [], "auto_rewriting_enabled": True}}
        request = urllib.request.Request(args.endpoint, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Accept": "text/event-stream", "User-Agent": "Flow/1.0"})
        started = time.monotonic()
        events = []
        with urllib.request.urlopen(request, timeout=90) as response:
            content_type = response.headers.get("Content-Type", "")
            kind, data = "", []
            for line in response:
                line = line.decode().rstrip("\r\n")
                if line.startswith("event:"): kind = line[6:].strip()
                elif line.startswith("data:"): data.append(line[5:].lstrip())
                elif not line and data:
                    events.append({"event": kind, "data": json.loads("\n".join(data)), "seconds": round(time.monotonic()-started, 4)})
                    kind, data = "", []
        raw = next((e["data"].get("text", "") for e in events if e["event"] == "transcription"), "")
        deltas = [e for e in events if e["event"] == "delta"]
        terminal = [e for e in events if e["event"] == "done"]
        normalize = lambda text: " ".join(re.findall(r"\w+", text.lower()))
        checks = {
            "server_sent_events": "text/event-stream" in content_type,
            "asr_matches_generated_speech": normalize(raw) == normalize(PHRASE),
            "transcription_precedes_generation": bool(events) and events[0]["event"] == "transcription",
            "multiple_actual_model_deltas": len(deltas) > 1,
            "terminal_text_matches_accumulated_deltas": len(terminal) == 1 and "".join(e["data"]["text"] for e in deltas).strip() == terminal[0]["data"]["text"],
            "first_delta_precedes_completion": bool(deltas) and bool(terminal) and deltas[0]["seconds"] < terminal[0]["seconds"],
            "no_error": not any(e["event"] == "error" for e in events),
        }
        result = {"kind": "live deployed worker with generated speech; no microphone or Messages automation",
            "endpoint": args.endpoint, "expected_phrase": PHRASE, "checks": checks, "events": events}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(checks, indent=2))
        if not all(checks.values()): raise SystemExit("Verification failed; inspect " + str(args.output))


if __name__ == "__main__": main()
