#!/usr/bin/env python3
"""Check production helper lifecycle without permission prompts or real hotkeys."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='flow-helper-check-') as directory:
    executable = Path(directory) / 'HelperLifecycleCheck'
    subprocess.run(['swiftc', '-parse-as-library',
                    str(ROOT / 'Sources/FlowApp/HelperManager.swift'),
                    str(ROOT / 'Sources/FlowApp/Hotkey.swift'),
                    str(ROOT / 'Sources/FlowApp/GlobeKeyHandler.swift'),
                    str(ROOT / 'scripts/verify-helper-lifecycle.swift'),
                    '-o', str(executable)], check=True, cwd=ROOT)
    subprocess.run([str(executable)], check=True, cwd=ROOT, timeout=25)
