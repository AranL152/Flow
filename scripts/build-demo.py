#!/usr/bin/env python3
"""Build a real macOS bundle with speech permission strings, without installing it."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:8787/format-stream")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--open", action="store_true")
    parser.add_argument("--native", action="store_true", help="Build the normal Flow app with live captions")
    parser.add_argument("--recording-preview", action="store_true", help="Open an isolated preview of the real recording UI")
    parser.add_argument("--speech-fixture", type=Path)
    parser.add_argument("--verification-report", type=Path)
    parser.add_argument("--verification-snapshot", type=Path, help="PNG filename prefix for the isolated preview")
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(["cargo", "build", "--offline"], cwd=ROOT/"flow-core", check=True)
        # SwiftPM does not track the Rust archive passed as an unsafe linker flag.
        subprocess.run(["swift", "package", "clean"], cwd=ROOT, check=True)
        subprocess.run(["swift", "build"], cwd=ROOT, check=True)
        if args.native:
            subprocess.run(["swift", "build"], cwd=ROOT/"FlowHelper", check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
    bundle = ROOT / (".build/Flow.app" if args.native else ".build/Flow Demo.app")
    contents = bundle / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
    shutil.copy2(binary_dir/"Flow", contents/"MacOS/Flow")
    for resource in binary_dir.glob("*.bundle"):
        destination = contents/"Resources"/resource.name
        # Package resources can be read-only; replace the generated copy.
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(resource, destination)
    shutil.copy2(ROOT/"AppIcon.icns", contents/"Resources/AppIcon.icns")
    if args.native:
        helper = ROOT/"FlowHelper/.build/debug/FlowHelper"
        if helper.exists():
            (contents/"Helpers").mkdir(exist_ok=True)
            shutil.copy2(helper, contents/"Helpers/FlowHelper")
    info = {"CFBundleExecutable":"Flow", "CFBundleIdentifier":"com.flow.flow" if args.native else "com.flow.conversations-demo",
            "CFBundleName":"Flow" if args.native else "Flow Demo", "CFBundleDisplayName":"Flow" if args.native else "Flow Demo", "CFBundlePackageType":"APPL",
            "CFBundleShortVersionString":"1.0", "CFBundleVersion":"1", "LSMinimumSystemVersion":"14.0",
            "CFBundleIconFile":"AppIcon", "NSHighResolutionCapable":True,
            "NSMicrophoneUsageDescription":"Flow uses your microphone to show your words as you speak.",
            "NSSpeechRecognitionUsageDescription":"Flow uses on-device speech recognition for live captions.",
            "FlowDemoEndpoint":args.endpoint}
    with (contents/"Info.plist").open("wb") as output: plistlib.dump(info, output)
    subprocess.run(["codesign","--force","--deep","--sign","-",str(bundle)], check=True)
    print(bundle)
    if args.open:
        launch = ["open", "-n", str(bundle), "--args"]
        if args.recording_preview: launch.append("--recording-preview")
        elif not args.native: launch.append("--demo")
        if args.speech_fixture: launch.extend(["--speech-fixture", str(args.speech_fixture.resolve())])
        if args.verification_report: launch.extend(["--verification-report", str(args.verification_report.resolve())])
        if args.verification_snapshot: launch.extend(["--verification-snapshot", str(args.verification_snapshot.resolve())])
        subprocess.run(launch, check=True)

if __name__ == "__main__": main()
