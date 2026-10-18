#!/usr/bin/env python3
"""Leave a replayable native Flow simulation open, using audible generated speech."""
import argparse
import os
from pathlib import Path
import subprocess
import signal
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
    parser.add_argument("--reuse-bundle", action="store_true", help="Launch the already signed app without rebuilding or re-signing it")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stop", action="store_true")
    parser.add_argument("--attachment", action="store_true", help="Separate real-pipeline attachment demo using fixture downloads")
    parser.add_argument("--file-search", action="store_true", help="Replay captioned voice, contact learning and indexed filename matches using the signed native app")
    args = parser.parse_args()
    if args.attachment and args.file_search:
        parser.error("Choose either --attachment or --file-search")
    kind = "file-search-simulation" if args.file_search else "attachment-simulation" if args.attachment else "voice-simulation"
    # Bundled test apps should not need Desktop/Documents permission merely to
    # read synthetic audio or write a verification report.
    folder = Path(tempfile.gettempdir())/"flow"/kind
    job_file = ROOT/".build"/kind/"job-label"
    job_file.parent.mkdir(parents=True, exist_ok=True)
    if job_file.exists():
        previous = job_file.read_text().strip()
        if previous.startswith("com.flow." + kind + "."):
            subprocess.run(["launchctl", "remove", previous], check=False, capture_output=True)
        elif args.file_search and previous.startswith("pid:"):
            pid = int(previous.removeprefix("pid:"))
            current = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
            if str(ROOT/".build/Flow Attachments.app/Contents/MacOS/Flow") in current and "--voice-simulation" in current and str(folder) in current:
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
        job_file.unlink(missing_ok=True)
    if args.stop: return
    build = ["python3", str(ROOT/"scripts/build-demo.py")]
    bundle = ROOT/(".build/Flow Attachments Demo.app" if args.attachment else ".build/Flow Demo.app")
    if args.file_search:
        # Preserve the exact code signature the user just authorized for speech.
        # The native binary already supports isolated replay and file search.
        bundle = ROOT/".build/Flow Attachments.app"
        args.reuse_bundle = True
    build.extend(["--bundle", str(bundle)])
    if args.reuse_bundle:
        if not (bundle/"Contents/MacOS/Flow").is_file():
            raise SystemExit(f"Prepared app is missing: {bundle}. Build it once before using --reuse-bundle.")
    else:
        if args.skip_build: build.append("--skip-build")
        subprocess.run(build, cwd=ROOT, check=True)
    folder.mkdir(parents=True, exist_ok=True)
    phrases = {"first": "Can you check the slides tomorrow?", "second": "Can you check the slides on Friday?"}
    if args.file_search:
        phrases = {"first": "Can you check the slides tomorrow? Flow, find the Orion review PDF.",
                   "second": "Can you check the slides on Friday? Flow, find the Orion review PDF."}
        # Spotlight skips /tmp. Keep dedicated synthetic files for Replay; no
        # user file is edited, and no actual Messages draft is touched.
        fixtures = Path.home()/"Flow Simulation Files"/"Orion review"
        fixtures.mkdir(parents=True, exist_ok=True)
        for filename, title in [("Orion-review-deck.pdf", "Orion project review"), ("Orion-review-notes.pdf", "Orion meeting notes")]:
            (fixtures/filename).write_bytes(fixture_pdf(title))
        subprocess.run(["mdimport", "-i", str(fixtures)], check=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            matches = subprocess.check_output(["mdfind", "-onlyin", str(fixtures), 'kMDItemFSName == "Orion-review*"cd'], text=True)
            if len(matches.splitlines()) >= 2: break
            time.sleep(.25)
        else: raise SystemExit("Spotlight has not indexed the replay PDFs yet. No app was rebuilt or re-signed.")
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
    label = "com.flow." + kind + "." + str(time.time_ns())
    report = (args.report or folder/"report.json").resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    launch = [str(bundle/"Contents/MacOS/Flow"), "--voice-simulation",
        "--simulation-audio-dir", str(folder), "--verification-report", str(report)]
    if args.attachment: launch.append("--attachment-simulation")
    if args.file_search:
        # Match the launch context of the native app whose Speech permission the
        # user enabled; launchd can resolve TCC access under a different identity.
        with (folder/"stdout.log").open("w") as out, (folder/"stderr.log").open("w") as err:
            process = subprocess.Popen(launch, stdout=out, stderr=err, start_new_session=True)
        job_file.write_text(f"pid:{process.pid}\n")
    else:
        subprocess.run(["launchctl", "submit", "-l", label, "-o", str(folder/"stdout.log"), "-e", str(folder/"stderr.log"), "--", *launch], check=True)
        job_file.write_text(label + "\n")
    print("Live Voice Simulation is open. Use Replay simulation to watch again.")
    print("Report: " + str(report))


if __name__ == "__main__": main()
