#!/usr/bin/env python3
"""Audible voice → real captions/LLM stream → auto-append → candidates, in Messages."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]


def stop_previous(work, executable):
    pid_file = work / 'pid'
    if pid_file.exists():
        pid = int(pid_file.read_text())
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
        if command.strip().startswith(str(executable)):
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        pid_file.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kind', choices=['both', 'file', 'screenshot'], default='both')
    parser.add_argument('--verify-replacement', action='store_true', help='Swap Flow’s own file to an alternative and back without sending')
    args = parser.parse_args()
    work = ROOT / '.build/messages-full-demo'
    work.mkdir(parents=True, exist_ok=True)
    executable = work / 'FlowMessagesFullDemo'
    stop_previous(work, executable)
    stop_previous(ROOT / '.build/messages-popup-simulation', ROOT / '.build/messages-popup-simulation/FlowMessagesPopup')
    # The existing app's signature/grants stay untouched. The CLI embeds usage
    # strings and inherits the host's already granted speech/Accessibility access.
    info = work / 'Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.flow.messages-full-demo', 'CFBundleName': 'Flow Demo',
        'NSSpeechRecognitionUsageDescription': 'Flow provides on-device live captions for generated voice playback.'}))
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    build = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
        str(ROOT / 'scripts/simulate-imessage-full.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'),
        '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(info), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        build.extend(['-framework', framework])
    subprocess.run(build, cwd=ROOT, check=True)
    folder = Path(tempfile.gettempdir()) / 'flow/messages-full-demo'
    folder.mkdir(parents=True, exist_ok=True)
    fixtures = Path.home() / 'Flow Simulation Files/Orion review'
    fixtures.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('flow_fixtures', ROOT / 'scripts/simulate-voice.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name, title in [('Orion-review.pdf', 'Orion project review'), ('Orion-review-notes.pdf', 'Orion review notes')]:
        path = fixtures / name
        if not path.exists(): path.write_bytes(module.fixture_pdf(title))
    subprocess.run(['mdimport', '-i', str(fixtures)], check=True)
    phrases = {'file': "Here is the Orion review. Flow, find the Orion review PDF.",
        'screenshot': "Here is the dashboard screenshot. Flow, find the Orion dashboard image."}
    for kind, phrase in phrases.items():
        subprocess.run(['say', '-v', 'Samantha', '-r', '165', '-o', str(folder / f'{kind}.aiff'), phrase], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(folder / f'{kind}.aiff'), str(folder / f'{kind}.wav')], check=True)
        with wave.open(str(folder / f'{kind}.wav'), 'rb') as audio:
            (folder / f'{kind}.pcm').write_bytes(audio.readframes(audio.getnframes()))
    report = folder / 'report.json'
    report.unlink(missing_ok=True)
    subprocess.run(['open', '-a', 'Messages'], check=True)
    with (folder / 'stdout.log').open('w') as out, (folder / 'stderr.log').open('w') as err:
        command = [str(executable), '--voice-simulation', '--folder', str(folder), '--fixtures', str(fixtures),
            '--report', str(report), '--kind', args.kind]
        if args.verify_replacement: command.append('--verify-replacement')
        process = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
    (work / 'pid').write_text(str(process.pid))
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if report.exists():
            result = json.loads(report.read_text())
            if result['status'] != 'running':
                (ROOT / 'review/imessage-full-demo-verification.json').write_text(json.dumps(result, indent=2) + '\n')
                print(json.dumps(result, indent=2))
                if result['status'] != 'ready': raise SystemExit(1)
                print('Full demo finished. Attachments and candidate popup remain in Messages; nothing was sent.')
                return
        if process.poll() is not None: raise SystemExit((folder / 'stderr.log').read_text())
        time.sleep(.25)
    raise SystemExit('Demo timed out. No Send event was generated; inspect its temporary log.')


if __name__ == '__main__':
    main()
