#!/usr/bin/env python3
"""Verify real native views and real on-device ASR using labelled fixtures.
No microphone, message delivery, production database, or privacy-setting edits.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PHRASE = "Can you check the slides tomorrow"


def run_preview(folder, name, extra):
    report = folder / (name + ".json")
    prefix = folder / name
    label = "com.flow.recording-verification." + str(time.time_ns())
    binary = ROOT / ".build/Flow Demo.app/Contents/MacOS/Flow"
    # A native launchd job gives macOS the app's privacy identity. Launching a
    # Speech client as an editor child can attribute access to that editor.
    command = ["launchctl", "submit", "-l", label, "-o", str(folder/(name+".stdout")),
               "-e", str(folder/(name+".stderr")), "--", str(binary),
               "--recording-preview", "--verification-report", str(report),
               "--verification-snapshot", str(prefix)] + extra
    subprocess.run(command, check=True)
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if report.exists():
                return json.loads(report.read_text()), prefix
            time.sleep(0.25)
        raise RuntimeError("No verification report. Check macOS Speech Recognition authorization and app logs in " + str(folder))
    finally:
        subprocess.run(["launchctl", "remove", label], check=False, capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT/"review/recording-verification.json")
    args = parser.parse_args()
    build = ["python3", str(ROOT/"scripts/build-demo.py")]
    if args.skip_build: build.append("--skip-build")
    subprocess.run(build, cwd=ROOT, check=True)
    folder = Path(tempfile.mkdtemp(prefix="flow-recording-verification-"))
    print("Verification files: " + str(folder), flush=True)
    fixture = folder/"speech.aiff"
    subprocess.run(["say", "-v", "Samantha", "-r", "155", "-o", str(fixture), PHRASE], check=True)
    ui, ui_prefix = run_preview(folder, "ui", [])
    speech, speech_prefix = run_preview(folder, "speech", ["--speech-fixture", str(fixture)])
    events = speech.get("events", [])
    normalize = lambda text: " ".join(re.findall(r"\w+", text.lower()))
    checks = {
        "ui_caption_reached_full_input": ui.get("final_text") == PHRASE,
        "ui_stopped_cleanly": ui.get("recording") is False and ui.get("processing") is False,
        "ui_clock_advanced_through_silence": ui.get("frame_updates", 0) == 150,
        "speech_has_multiple_real_partial_results": len([e for e in events if not e["final"]]) >= 2,
        "speech_final_matches_generated_audio": bool(events) and events[-1]["final"] and normalize(events[-1]["text"]) == normalize(PHRASE),
        "speech_partial_precedes_final": len(events) > 1 and events[0]["seconds"] < events[-1]["seconds"],
        "speech_partial_arrived_while_audio_was_feeding": bool(events) and events[0]["seconds"] < speech.get("audio_finished_seconds", 0),
        "speech_audio_meter_responded": speech.get("peak_level", 0) > 0.01,
        "speech_stopped_cleanly": speech.get("recording") is False and speech.get("processing") is False,
        "views_rendered": all(Path(str(prefix)+"-"+stage+".png").exists() for prefix, stage in [(ui_prefix,"speaking"),(ui_prefix,"silence"),(speech_prefix,"speech")]),
    }
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    for prefix, stage, destination in [(speech_prefix, "speech", "recording-captions.png"), (ui_prefix, "silence", "recording-silence.png")]:
        source = Path(str(prefix)+"-"+stage+".png")
        if source.exists(): shutil.copy2(source, output.parent/destination)
    output.write_text(json.dumps({"kind": "isolated native rendering and generated-audio integration test",
        "expected_phrase": PHRASE, "checks": checks, "ui": ui, "speech": speech}, indent=2) + "\n")
    print(json.dumps(checks, indent=2), flush=True)
    if not all(checks.values()):
        raise SystemExit("A recording check failed. Inspect " + str(output))


if __name__ == "__main__": main()
