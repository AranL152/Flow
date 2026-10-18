#!/usr/bin/env python3
"""Leave a replayable native Flow simulation open, using audible generated speech."""
import argparse
from pathlib import Path
import subprocess
import time
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]


def fixture_pdf(title):
    stream = f"BT /F1 24 Tf 50 700 Td ({title}) Tj 0 -48 Td /F1 14 Tf (Flow attachment demo - synthetic fixture) Tj ET".encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"]
    output = b"%PDF-1.4\n"
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output)); output += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    start = len(output)
    output += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:])
    return output + f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stop", action="store_true")
    parser.add_argument("--attachment", action="store_true", help="Separate real-pipeline attachment demo using fixture downloads")
    args = parser.parse_args()
    kind = "attachment-simulation" if args.attachment else "voice-simulation"
    # Bundled test apps should not need Desktop/Documents permission merely to
    # read synthetic audio or write a verification report.
    folder = Path(tempfile.gettempdir())/"flow"/kind
    job_file = ROOT/".build"/kind/"job-label"
    job_file.parent.mkdir(parents=True, exist_ok=True)
    if job_file.exists():
        previous = job_file.read_text().strip()
        if previous.startswith("com.flow.attachment-simulation." if args.attachment else "com.flow.voice-simulation."):
            subprocess.run(["launchctl", "remove", previous], check=False, capture_output=True)
        job_file.unlink(missing_ok=True)
    if args.stop: return
    build = ["python3", str(ROOT/"scripts/build-demo.py")]
    bundle = ROOT/(".build/Flow Attachments Demo.app" if args.attachment else ".build/Flow Demo.app")
    build.extend(["--bundle", str(bundle)])
    if args.skip_build: build.append("--skip-build")
    subprocess.run(build, cwd=ROOT, check=True)
    folder.mkdir(parents=True, exist_ok=True)
    phrases = {"first": "Can you check the slides tomorrow?", "second": "Can you check the slides on Friday?"}
    if args.attachment:
        phrases = {"attachment": "Here's the deck. Flow, attach the PDF I just downloaded."}
        (folder/"Downloads").mkdir(exist_ok=True)
        (folder/"Downloads/Older-deck.pdf").write_bytes(fixture_pdf("Previous project review"))
        (folder/"updated-deck.pdf").write_bytes(fixture_pdf("Updated project review"))
    for name, phrase in phrases.items():
        audio, wav = folder/(name+".aiff"), folder/(name+".wav")
        subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(audio), phrase], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(audio), str(wav)], check=True)
        with wave.open(str(wav), "rb") as source:
            assert source.getsampwidth() == 2 and source.getnchannels() == 1 and source.getframerate() == 16000
            (folder/(name+".pcm")).write_bytes(source.readframes(source.getnframes()))
    label = ("com.flow.attachment-simulation." if args.attachment else "com.flow.voice-simulation.") + str(time.time_ns())
    report = (args.report or folder/"report.json").resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    launch = ["launchctl", "submit", "-l", label, "-o", str(folder/"stdout.log"), "-e", str(folder/"stderr.log"),
        "--", str(bundle/"Contents/MacOS/Flow"), "--voice-simulation",
        "--simulation-audio-dir", str(folder), "--verification-report", str(report)]
    if args.attachment: launch.append("--attachment-simulation")
    subprocess.run(launch, check=True)
    job_file.write_text(label + "\n")
    print("Live Voice Simulation is open. Use Replay simulation to watch again.")
    print("Report: " + str(report))


if __name__ == "__main__": main()
