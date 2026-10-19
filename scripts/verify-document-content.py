#!/usr/bin/env python3
"""Verify local PDF/slide content search with disposable indexed fixtures."""
import argparse
from contextlib import nullcontext
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keep-fixtures', action='store_true', help='Retain synthetic documents for a native voice check')
    args = parser.parse_args()
    work = ROOT / '.build/document-content-review'
    work.mkdir(parents=True, exist_ok=True)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines()
               if not p.endswith('/FlowApp.swift.o')]
    executable = work / 'FlowDocumentContentCheck'
    command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
               str(ROOT / 'scripts/verify-document-content.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    with (work / 'build.log').open('w') as log:
        subprocess.run(command, check=True, cwd=ROOT, stdout=log, stderr=log)
    report = work / 'report.json'
    report.unlink(missing_ok=True)
    retained = Path.home() / 'Flow Simulation Files/Document content review'
    if args.keep_fixtures:
        retained.mkdir(parents=True, exist_ok=True)
    fixture_context = nullcontext(str(retained)) if args.keep_fixtures else tempfile.TemporaryDirectory(prefix='FlowDocumentVerification-', dir=Path.home())
    with fixture_context as directory:
        with (work / 'native.log').open('w') as log:
            completed = subprocess.run([str(executable), '--voice-simulation', '--fixtures', directory,
                '--report', str(report), '--snapshot', str(work / 'picker.png')], cwd=ROOT, stdout=log, stderr=log, timeout=90)
    result = json.loads(report.read_text())
    print(json.dumps(result, indent=2))
    if completed.returncode or not result.get('passed'):
        raise SystemExit('Document verification failed; inspect .build/document-content-review/.')
    (ROOT / 'review/document-content-verification.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
