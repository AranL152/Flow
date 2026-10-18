#!/usr/bin/env python3
"""Leave a replayable native Flow simulation open, using audible generated speech."""
import argparse
from pathlib import Path
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    folder = ROOT/".build/voice-simulation"
    job_file = folder/"job-label"
    if job_file.exists():
        previous = job_file.read_text().strip()
        if previous.startswith("com.flow.voice-simulation."):
            subprocess.run(["launchctl", "remove", previous], check=False, capture_output=True)
        job_file.unlink(missing_ok=True)
    if args.stop: return
    build = ["python3", str(ROOT/"scripts/build-demo.py")]
    if args.skip_build: build.append("--skip-build")
    subprocess.run(build, cwd=ROOT, check=True)
    folder = ROOT/".build/voice-simulation"
    folder.mkdir(parents=True, exist_ok=True)
    phrases = {"first": "Can you check the slides tomorrow?", "second": "Can you check the slides on Friday?"}
    for name, phrase in phrases.items():
        audio, wav = folder/(name+".aiff"), folder/(name+".wav")
        subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(audio), phrase], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(audio), str(wav)], check=True)
        with wave.open(str(wav), "rb") as source:
            assert source.getsampwidth() == 2 and source.getnchannels() == 1 and source.getframerate() == 16000
            (folder/(name+".pcm")).write_bytes(source.readframes(source.getnframes()))
    label = "com.flow.voice-simulation." + str(time.time_ns())
    report = (args.report or folder/"report.json").resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    subprocess.run(["launchctl", "submit", "-l", label, "-o", str(folder/"stdout.log"), "-e", str(folder/"stderr.log"),
        "--", str(ROOT/".build/Flow Demo.app/Contents/MacOS/Flow"), "--voice-simulation",
        "--simulation-audio-dir", str(folder), "--verification-report", str(report)], check=True)
    job_file.write_text(label + "\n")
    print("Live Voice Simulation is open. Use Replay simulation to watch again.")
    print("Report: " + str(report))


if __name__ == "__main__": main()
