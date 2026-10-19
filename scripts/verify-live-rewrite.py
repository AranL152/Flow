#!/usr/bin/env python3
"""Real paid cloud preview while synthetic speech is still arriving; never writes Messages."""
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='flow-live-rewrite-') as directory:
    work = Path(directory)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [line for line in (binary / 'Flow.product/Objects.LinkFileList').read_text().splitlines()
               if '/Flow.build/' in line or '/CFlow.build/' in line]
    command = ['swiftc', '-parse-as-library', '-I', str(binary / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
               str(ROOT / 'scripts/verify-live-rewrite.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(work/'Check')]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    subprocess.run(command, check=True, cwd=ROOT)
    phrase = 'Hey Alex can you review the dashboard screenshot when you get a minute today and let me know what you think. Flow find the Orion dashboard image.'
    subprocess.run(['say', '-v', 'Samantha', '-r', '165', '-o', str(work/'speech.aiff'), phrase], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(work/'speech.aiff'), str(work/'speech.wav')], check=True)
    with wave.open(str(work/'speech.wav'), 'rb') as audio:
        (work/'speech.pcm').write_bytes(audio.readframes(audio.getnframes()))
    subprocess.run([str(work/'Check'), str(work/'speech.pcm')], check=True, cwd=ROOT, timeout=40)
