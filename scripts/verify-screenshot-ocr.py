#!/usr/bin/env python3
"""Verify real local OCR and Spotlight using disposable synthetic screenshots."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='FlowOCRVerification-', dir=Path.home()) as directory:
        folder = Path(directory)
        binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
        objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines()
                   if not p.endswith('/FlowApp.swift.o')]
        executable = folder / 'FlowOCRCheck'
        command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
                   str(ROOT / 'scripts/verify-screenshot-ocr.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
        for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
            command.extend(['-framework', framework])
        subprocess.run(command, check=True, cwd=ROOT)
        report = ROOT / 'review/screenshot-ocr-verification.json'
        snapshot = ROOT / 'review/screenshot-ocr-preview.png'
        subprocess.run([str(executable), '--voice-simulation', '--fixtures', str(folder), '--report', str(report), '--snapshot', str(snapshot)],
                       cwd=ROOT, check=True, timeout=40)
        print(json.dumps(json.loads(report.read_text()), indent=2))


if __name__ == '__main__':
    main()
