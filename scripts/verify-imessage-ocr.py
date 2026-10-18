#!/usr/bin/env python3
"""Local OCR → actual Messages attachment and candidate swap. No cloud calls."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    spec = importlib.util.spec_from_file_location('full_demo', ROOT / 'scripts/simulate-imessage-full.py')
    full = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(full)
    work = ROOT / '.build/messages-ocr-check'
    work.mkdir(parents=True, exist_ok=True)
    executable = work / 'FlowMessagesOCRCheck'
    full.stop_previous(work, executable)
    full.stop_previous(ROOT / '.build/messages-full-demo', ROOT / '.build/messages-full-demo/FlowMessagesFullDemo')
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
        str(ROOT / 'scripts/verify-imessage-ocr.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    subprocess.run(command, cwd=ROOT, check=True)
    folder = Path.home() / 'Flow Simulation Files/Screenshot text review'
    temporary = Path(tempfile.gettempdir()) / 'flow/messages-ocr-check'
    temporary.mkdir(parents=True, exist_ok=True)
    report = temporary / 'report.json'
    report.unlink(missing_ok=True)
    subprocess.run(['open', '-a', 'Messages'], check=True)
    with (temporary / 'stdout.log').open('w') as out, (temporary / 'stderr.log').open('w') as err:
        process = subprocess.Popen([str(executable), '--voice-simulation', '--fixtures', str(folder), '--report', str(report)],
                                   cwd=ROOT, stdout=out, stderr=err, start_new_session=True)
    (work / 'pid').write_text(str(process.pid))
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if report.exists():
            result = json.loads(report.read_text())
            (ROOT / 'review/imessage-ocr-verification.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result, indent=2))
            if result['status'] != 'ready': raise SystemExit(1)
            print('OCR picker remains open in Messages. The screenshot is in the unsent draft. No cloud API calls or sends.')
            return
        if process.poll() is not None: raise SystemExit((temporary / 'stderr.log').read_text())
        time.sleep(.2)
    raise SystemExit('Local OCR check timed out; inspect its temporary log. No Send event was generated.')


if __name__ == '__main__':
    main()
