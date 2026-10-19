#!/usr/bin/env python3
"""Open the installed Flow app without building, replacing or signing it."""
import argparse
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / '.build/Flow Attachments.app'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    args = parser.parse_args()
    app = args.app.resolve()
    info_path = app / 'Contents/Info.plist'
    if not info_path.is_file():
        raise SystemExit(f'No installed app at {app}. Run scripts/install-native.py once to build it.')
    info = plistlib.loads(info_path.read_bytes())
    executable = app / 'Contents/MacOS' / info.get('CFBundleExecutable', '')
    if info.get('CFBundleIdentifier') != 'com.flow.flow' or not executable.is_file():
        raise SystemExit(f'This is not a complete native Flow installation: {app}')
    subprocess.run(['open', str(app)], check=True)
    print(f'Opened existing app: {app}')


if __name__ == '__main__':
    main()
