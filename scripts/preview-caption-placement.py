#!/usr/bin/env python3
"""Open a silent layout preview using existing native build objects; no app install."""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--messages', action='store_true', help='Anchor silent captions to the real Messages composer without editing it.')
    args = parser.parse_args()
    work = ROOT / '.build/caption-placement-preview'
    work.mkdir(parents=True, exist_ok=True)
    binary_dir = Path(subprocess.check_output(
        ['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    link_file = binary_dir / 'Flow.product/Objects.LinkFileList'
    if not link_file.exists():
        raise SystemExit('An existing native debug build is required. This preview does not rebuild or install Flow.')
    objects = [p for p in link_file.read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    executable = work / 'FlowCaptionPlacementPreview'
    command = ['swiftc', '-parse-as-library', '-I', str(binary_dir / 'Modules'),
               '-I', str(ROOT / 'Sources/CFlow/include'),
               str(ROOT / 'scripts/preview-caption-placement.swift'), *objects,
               str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration',
                      'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    with (work / 'compile.log').open('w') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=log)
    if result.returncode:
        raise SystemExit((work / 'compile.log').read_text())
    arguments = [str(executable), '--voice-simulation']
    if args.messages:
        arguments.append('--messages')
    with (work / 'stdout.log').open('w') as out, (work / 'stderr.log').open('w') as err:
        process = subprocess.Popen(arguments, cwd=ROOT,
                                   stdout=out, stderr=err, start_new_session=True)
    (work / 'pid').write_text(str(process.pid))
    print('Silent Messages preview opened.' if args.messages else 'Silent layout preview opened. Use Bottom / Top and Expand draft.')
    print('Replay is available. No audio, capture, or Messages changes.')


if __name__ == '__main__':
    main()
