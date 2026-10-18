#!/usr/bin/env python3
"""Index synthetic home-directory files and verify native search without Messages writes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    token = 'flowsearch' + uuid.uuid4().hex[:10]
    # Spotlight does not index /tmp. This dedicated home folder is deleted on exit.
    with tempfile.TemporaryDirectory(prefix='FlowSearchVerification-', dir=Path.home()) as directory:
        folder = Path(directory)
        spec = importlib.util.spec_from_file_location('flow_fixtures', ROOT / 'scripts/simulate-voice.py')
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        for suffix in ['sketch', 'notes']:
            (folder / f'{token}-{suffix}.pdf').write_bytes(fixtures.fixture_pdf(f'File search verification: {suffix}'))
        (folder / f'{token}-other.txt').write_text('Unrelated type fixture')
        subprocess.run(['mdimport', '-i', str(folder)], check=True)
        until = time.monotonic() + 20
        while time.monotonic() < until:
            indexed = subprocess.check_output(['mdfind', '-onlyin', str(folder), f'kMDItemFSName == "{token}*"cd'], text=True)
            if len(indexed.splitlines()) >= 3:
                break
            time.sleep(.25)
        else:
            raise SystemExit('Spotlight did not index the fixtures; no app or permission changes made.')
        binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
        objects = [p for p in (binary_dir / 'Flow.product/Objects.LinkFileList').read_text().splitlines()
                   if not p.endswith('/FlowApp.swift.o')]
        executable = folder / 'FlowFileSearchCheck'
        command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
                   str(ROOT / 'scripts/verify-file-search.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
        for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
            command.extend(['-framework', framework])
        subprocess.run(command, check=True, cwd=ROOT)
        report = ROOT / 'review/file-search-verification.json'
        snapshot = ROOT / 'review/file-search-preview.png'
        subprocess.run([str(executable), '--voice-simulation', '--query', token, '--report', str(report), '--snapshot', str(snapshot)], cwd=ROOT, check=True, timeout=30)
        print(report.read_text())


if __name__ == '__main__':
    main()
