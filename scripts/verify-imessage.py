#!/usr/bin/env python3
"""Run production Swift components in an existing empty Messages draft; never Send.

The helper inherits the editor's existing AX/microphone grants. It does not
re-sign or restart the user's app or request any permissions.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true", help="Write an unsent test draft and append a synthetic PDF in Messages")
    parser.add_argument("--append-image", action="store_true", help="Append a clipboard image to the existing verifier-owned draft")
    parser.add_argument("--baseline", type=Path, help="Previous verifier report used to protect the existing draft")
    parser.add_argument("--output", type=Path, default=ROOT / "review/imessage-verification.json")
    args = parser.parse_args()
    binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
    objects = [line for line in (binary_dir / "Flow.product/Objects.LinkFileList").read_text().splitlines()
        if not line.endswith("/FlowApp.swift.o")]
    with tempfile.TemporaryDirectory(prefix="flow-imessage-check-") as temp:
        folder = Path(temp)
        executable = folder / "FlowMessagesCheck"
        command = ["swiftc", "-parse-as-library", "-g", "-I", str(binary_dir / "Modules"),
            "-I", str(ROOT / "Sources/CFlow/include"), str(ROOT / "scripts/verify-imessage.swift"),
            *objects, str(ROOT / "flow-core/target/debug/libflow.a"),
            "-L", str(ROOT / "flow-core/target/debug"),
            "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "flow-core/target/debug"), "-o", str(executable)]
        for framework in ["CoreAudio", "AudioToolbox", "Security", "SystemConfiguration", "Metal", "MetalKit", "MetalPerformanceShaders", "Accelerate", "Foundation"]:
            command.extend(["-framework", framework])
        subprocess.run(command, cwd=ROOT, check=True)
        fixture = folder / "speech.aiff"
        wav = folder / "speech.wav"
        phrase = "Flow, attach the image on my clipboard." if args.append_image else "Here's the deck. Flow, attach the PDF I just downloaded."
        subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(fixture), phrase], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(fixture), str(wav)], check=True)
        with wave.open(str(wav), "rb") as audio:
            assert audio.getsampwidth() == 2 and audio.getnchannels() == 1 and audio.getframerate() == 16000
            (folder / "speech.pcm").write_bytes(audio.readframes(audio.getnframes()))
        # Import a fixture generator; this never launches or rebuilds an app.
        from importlib.util import module_from_spec, spec_from_file_location
        spec = spec_from_file_location("flow_simulation_fixture", ROOT / "scripts/simulate-voice.py")
        module = module_from_spec(spec)
        spec.loader.exec_module(module)
        (folder / "source.pdf").write_bytes(module.fixture_pdf("Unsent Flow verification"))
        report = folder / "report.json"
        launch = [str(executable), "--voice-simulation", "--folder", str(folder), "--report", str(report)]
        if args.run:
            launch.append("--run")
        if args.append_image:
            if not args.run or not args.baseline:
                raise SystemExit("--append-image requires --run and --baseline; existing drafts are never replaced")
            (folder / "baseline.json").write_text(args.baseline.read_text())
            launch.append("--append-image")
        subprocess.run(launch, check=True, cwd=ROOT)
        result = json.loads(report.read_text())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        if args.run and result.get("status") != "passed":
            raise SystemExit(1)


if __name__ == "__main__":
    main()
