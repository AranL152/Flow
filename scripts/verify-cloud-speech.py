#!/usr/bin/env python3
"""Real paid Cloudflare test with synthetic speech; never records or edits Messages."""
import json
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    work = ROOT / '.build/cloud-speech-check'
    work.mkdir(parents=True, exist_ok=True)
    report = ROOT / 'review/cloud-speech-verification.json'
    report.unlink(missing_ok=True)
    subprocess.run(['cargo', 'build', '--manifest-path', 'flow-core/Cargo.toml', '--quiet'], cwd=ROOT, check=True)
    subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [line for line in (binary / 'Flow.product/Objects.LinkFileList').read_text().splitlines()
               if '/Flow.build/' in line or '/CFlow.build/' in line]
    executable = work / 'VerifyCloudSpeech'
    command = ['swiftc', '-parse-as-library', '-I', str(binary / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
               str(ROOT / 'scripts/verify-cloud-speech.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command.extend(['-framework', framework])
    subprocess.run(command, cwd=ROOT, check=True)
    results = []
    for word, phrase in [
        ('issue', "Here's the issue. Flow, find the screenshot showing payment error."),
        ('dashboard', 'Here is the dashboard screenshot. Flow, find the Orion dashboard image.'),
        ('review', 'Hey Alex, here is the project review. Flow, find the robotics presentation.'),
    ]:
        subprocess.run(['say', '-v', 'Samantha', '-r', '165', '-o', str(work / 'speech.aiff'), phrase], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(work / 'speech.aiff'), str(work / 'speech.wav')], check=True)
        with wave.open(str(work / 'speech.wav'), 'rb') as audio:
            (work / 'speech.pcm').write_bytes(audio.readframes(audio.getnframes()))
        sample_report = work / f'{word}.json'
        sample_report.unlink(missing_ok=True)
        subprocess.run([str(executable), str(work / 'speech.pcm'), str(sample_report), word], cwd=ROOT, check=False, timeout=120)
        results.append(json.loads(sample_report.read_text()))
    used_realtime = sum(bool(item['final_cloud_transcript']) for item in results)
    passed = all(item['status'] == 'passed' for item in results) and used_realtime > 0
    report.write_text(json.dumps({'status': 'passed' if passed else 'failed', 'realtime_cases': used_realtime,
        'scope': 'Three sequential synthetic utterances, each compared with batch transcription. Real production client, deployed Cloudflare and Rust pipeline; no Messages writes or microphone. Not a median/p95 benchmark.',
        'samples': results}, indent=2) + '\n')
    if not passed: raise SystemExit('Cloud speech verification failed')
    print('passed')


if __name__ == '__main__':
    main()
