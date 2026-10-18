#!/usr/bin/env python3
"""Show the production attachment popup over real Messages without changing its draft."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    work = ROOT / '.build/messages-popup-simulation'
    work.mkdir(parents=True, exist_ok=True)
    executable = work / 'FlowMessagesPopup'
    pid_file = work / 'pid'
    if pid_file.exists():
        pid = int(pid_file.read_text())
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
        if str(executable) in command:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
    # Link the existing production objects; do not re-sign/restart the authorized app.
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    build = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
             str(ROOT / 'scripts/simulate-imessage-popup.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        build.extend(['-framework', framework])
    subprocess.run(build, check=True, cwd=ROOT)
    folder = Path(tempfile.gettempdir()) / 'flow/messages-popup-simulation'
    folder.mkdir(parents=True, exist_ok=True)
    fixtures = Path.home() / 'Flow Simulation Files/Orion review'
    fixtures.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('flow_fixtures', ROOT / 'scripts/simulate-voice.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for filename, title in [('Orion-review-deck.pdf', 'Orion project review'), ('Orion-review-notes.pdf', 'Orion meeting notes')]:
        path = fixtures / filename
        if not path.exists(): path.write_bytes(module.fixture_pdf(title))
    subprocess.run(['mdimport', '-i', str(fixtures)], check=True)
    subprocess.run(['say', '-v', 'Samantha', '-r', '165', '-o', str(folder / 'search.aiff'), 'Flow, find the Orion review PDF.'], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(folder / 'search.aiff'), str(folder / 'search.wav')], check=True)
    with wave.open(str(folder / 'search.wav'), 'rb') as audio:
        (folder / 'search.pcm').write_bytes(audio.readframes(audio.getnframes()))
    report = folder / 'report.json'
    report.unlink(missing_ok=True)
    subprocess.run(['open', '-a', 'Messages'], check=True)
    with (folder / 'stdout.log').open('w') as out, (folder / 'stderr.log').open('w') as err:
        process = subprocess.Popen([str(executable), '--voice-simulation', '--folder', str(folder), '--report', str(report)], stdout=out, stderr=err, start_new_session=True)
    pid_file.write_text(str(process.pid))
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if report.exists():
            result = json.loads(report.read_text())
            (ROOT / 'review/imessage-popup-verification.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result, indent=2))
            if result['status'] != 'ready': raise SystemExit(1)
            print('The popup is open over Messages. Select a PDF, then Add to Messages. Nothing was sent.')
            return
        if process.poll() is not None:
            raise SystemExit((folder / 'stderr.log').read_text())
        time.sleep(.25)
    raise SystemExit('The popup did not become ready; inspect its log. No Send event was issued.')


if __name__ == '__main__':
    main()
