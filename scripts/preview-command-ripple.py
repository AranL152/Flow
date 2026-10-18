#!/usr/bin/env python3
"""Show/export native command effects with synthetic captions and local OCR only."""
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    spec = importlib.util.spec_from_file_location('flow_demo', ROOT / 'scripts/simulate-imessage-full.py')
    demo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(demo)
    work = ROOT / '.build/command-ripple-preview'
    work.mkdir(parents=True, exist_ok=True)
    executable = work / 'FlowCommandRipplePreview'
    demo.stop_previous(work, executable)
    demo.stop_previous(ROOT / '.build/messages-full-demo', ROOT / '.build/messages-full-demo/FlowMessagesFullDemo')
    demo.stop_previous(ROOT / '.build/messages-ocr-check', ROOT / '.build/messages-ocr-check/FlowMessagesOCRCheck')
    subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
               str(ROOT / 'scripts/preview-command-ripple.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    subprocess.run(command, cwd=ROOT, check=True)
    output = ROOT / 'review'
    report = output / 'command-ripple-verification.json'
    report.unlink(missing_ok=True)
    with (work / 'stdout.log').open('w') as out, (work / 'stderr.log').open('w') as err:
        process = subprocess.Popen([str(executable), '--voice-simulation', '--fixtures', str(Path.home() / 'Flow Simulation Files/Command effect review'),
                                    '--output', str(output)], cwd=ROOT, stdout=out, stderr=err, start_new_session=True)
    (work / 'pid').write_text(str(process.pid))
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if report.exists():
            result = json.loads(report.read_text()); print(json.dumps(result, indent=2))
            if result['status'] != 'ready': raise SystemExit(1)
            print('Native effect preview is open. Replay and Reduce Motion controls are available. No model calls or Messages changes.')
            return
        if process.poll() is not None: raise SystemExit((work / 'stderr.log').read_text())
        time.sleep(.2)
    raise SystemExit('Preview timed out; inspect .build/command-ripple-preview/stderr.log')


if __name__ == '__main__':
    main()
