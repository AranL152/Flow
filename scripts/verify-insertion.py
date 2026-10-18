#!/usr/bin/env python3
"""Use an isolated native composer to verify actual Accessibility writes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT/"review/insertion-verification.json")
    args = parser.parse_args()
    build = ["python3", str(ROOT/"scripts/build-demo.py")]
    if args.skip_build: build.append("--skip-build")
    subprocess.run(build, cwd=ROOT, check=True)
    folder = Path(tempfile.mkdtemp(prefix="flow-insertion-"))
    report = folder/"report.json"
    label = "com.flow.insertion-verification." + str(time.time_ns())
    binary = ROOT/".build/Flow Demo.app/Contents/MacOS/Flow"
    subprocess.run(["launchctl", "submit", "-l", label, "-o", str(folder/"stdout"), "-e", str(folder/"stderr"),
        "--", str(binary), "--stream-insertion-preview", "--verification-report", str(report)], check=True)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not report.exists(): time.sleep(0.25)
        if not report.exists(): raise SystemExit("No native verification report; inspect " + str(folder))
        result = json.loads(report.read_text())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        if result["status"] != "passed": raise SystemExit(2 if result["status"] == "unavailable" else 1)
    finally:
        subprocess.run(["launchctl", "remove", label], check=False, capture_output=True)


if __name__ == "__main__": main()
