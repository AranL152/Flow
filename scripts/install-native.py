#!/usr/bin/env python3
"""Rebuild and replace Flow. For everyday launches, use scripts/launch-native.py."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / '.build/Flow Attachments.app'


def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, **kwargs)


def stop_exact(executable):
    for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or fields[1] != str(executable):
            continue
        pid = int(fields[0])
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            time.sleep(.1)
        else: raise SystemExit('Flow did not exit; no installed files were replaced.')


def same_code(left, right, scratch):
    """Keep an existing helper's grant only when its executable code is identical."""
    copies = [scratch / 'old-helper', scratch / 'new-helper']
    for source, destination in zip([left, right], copies):
        shutil.copy2(source, destination)
        run('codesign', '--remove-signature', str(destination), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return copies[0].read_bytes() == copies[1].read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args()
    app = args.app.resolve()
    print('This command rebuilds and replaces the app. Ad-hoc signed updates can require new privacy grants.', flush=True)
    print('To open the existing app without changing its identity: python3 scripts/launch-native.py', flush=True)
    run('cargo', 'build', '--manifest-path', str(ROOT / 'flow-core/Cargo.toml'), '--quiet', cwd=ROOT)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    # SwiftPM doesn't track the external Rust archive; force a fresh final link.
    (binary_dir / 'Flow').unlink(missing_ok=True)
    run('swift', 'build', cwd=ROOT)
    run('swift', 'build', cwd=ROOT / 'FlowHelper')
    with tempfile.TemporaryDirectory(prefix='flow-native-install-') as temp:
        scratch = Path(temp)
        staged = scratch / app.name
        run('python3', str(ROOT / 'scripts/build-demo.py'), '--native', '--skip-build', '--bundle', str(staged), cwd=ROOT)
        old_helper = app / 'Contents/Helpers/FlowHelper'
        new_helper = staged / 'Contents/Helpers/FlowHelper'
        if old_helper.exists() and same_code(old_helper, new_helper, scratch):
            shutil.copy2(old_helper, new_helper)
            print('Preserved the unchanged hotkey helper and its code signature.')
        info_path = staged / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['FlowBuildCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        info_path.write_bytes(plistlib.dumps(info))
        resource = staged / 'Contents/Resources/Flow_FlowApp.bundle'
        if not resource.is_dir(): raise SystemExit('Packaged app resources are missing; installation stopped.')
        run('codesign', '--force', '--sign', '-', str(staged))
        run('codesign', '--verify', '--deep', '--strict', str(staged))
        # Replacing the directory leaves a complete rollback copy in this repo.
        backup = ROOT / '.build/native-app-backups' / time.strftime('%Y%m%d-%H%M%S') / app.name
        incoming = app.with_name(app.name + '.incoming')
        if incoming.exists(): raise SystemExit(f'Remove the stale installer directory first: {incoming}')
        app.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, incoming)
        stop_exact(app / 'Contents/MacOS/Flow')
        stop_exact(old_helper)
        if app.exists():
            backup.parent.mkdir(parents=True, exist_ok=True)
            app.rename(backup)
        try: incoming.rename(app)
        except OSError:
            if backup.exists(): backup.rename(app)
            raise
        run('codesign', '--verify', '--deep', '--strict', str(app))
        installed_hash = hashlib.sha256((app / 'Contents/MacOS/Flow').read_bytes()).hexdigest()
        print(f'Updated: {app}\nBuild: {info["FlowBuildCommit"]}\nSHA256: {installed_hash}\nBackup: {backup}')
        print('Ad-hoc signing: macOS may require permission to be re-enabled for this updated build.')
        if not args.no_launch:
            run('open', str(app))


if __name__ == '__main__':
    main()
