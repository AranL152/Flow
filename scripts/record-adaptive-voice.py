#!/usr/bin/env python3
"""Record real microphone → cloud → Messages. Requires an empty unsent draft.

Does not install, sign or replace Flow. Diagnostic mode uses production AppState
with in-memory history; --native drives the already installed app's Fn helper.
Audio, footage, logs and draft timing points remain private under .build/.
"""
import argparse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def fault_proxy(work, stalled_request):
    """Forward genuine cloud SSE, except one deliberately stalled request.

    Records no request bodies. Used only in the isolated diagnostic host; speech
    recognition still goes directly to the real cloud WebSocket service.
    """
    events, lock = [], threading.Lock()
    count = 0

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            nonlocal count
            body = self.rfile.read(int(self.headers['Content-Length']))
            with lock:
                count += 1
                number = count
            began = time.monotonic()
            if number == stalled_request:
                self.connection.settimeout(.1)
                disconnected = False
                while time.monotonic() - began < 12:
                    try:
                        if self.connection.recv(1, socket.MSG_PEEK) == b'':
                            disconnected = True
                            break
                    except socket.timeout:
                        continue
                    except ConnectionError:
                        disconnected = True
                        break
                with lock:
                    events.append({'request': number, 'injected_stall': True,
                        'client_cancelled': disconnected, 'seconds': time.monotonic() - began})
                self.close_connection = True
                return
            upstream = None
            try:
                # Use the same macOS TLS/network stack as the working native
                # diagnostics; Python's default urllib client is blocked here.
                upstream = subprocess.Popen(['curl', '--fail', '--silent', '--show-error',
                    '--no-buffer', '--max-time', '30', '-H', 'Content-Type: application/json',
                    '--data-binary', '@-',
                    'https://base10-proxy.old-resonance-ed75.workers.dev/transcribe-stream'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                upstream.stdin.write(body); upstream.stdin.close()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Connection', 'close')
                self.end_headers()
                while chunk := upstream.stdout.read1(4096):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                status = upstream.wait()
                if status:
                    with lock: events.append({'request': number, 'upstream_exit': status})
            except (OSError, ValueError) as error:
                with lock:
                    events.append({'request': number, 'forward_error': type(error).__name__})
            finally:
                if upstream and upstream.poll() is None:
                    upstream.terminate(); upstream.wait()
                self.close_connection = True

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--speech', required=True, type=Path, help='Existing AIFF/WAV spoken through speakers')
    parser.add_argument('--name', default='voice-review')
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--app-log', type=Path, help='Unbuffered installed-app log, required with --native')
    parser.add_argument('--new-test-draft', action='store_true', help='Create an unsent draft addressed to a unique example.invalid test recipient')
    parser.add_argument('--require-realtime', action='store_true', help='Fail unless native cloud captions and a finalized real-time transcript were observed')
    parser.add_argument('--require-live', action='store_true', help='Require live captions, streamed model writes while speaking and a finalized cloud/on-device ASR handoff')
    parser.add_argument('--expect-fallback', action='store_true', help='Fail unless native on-device captions survive an intentionally unavailable speech socket')
    parser.add_argument('--expect-attachment', action='store_true', help='Fail unless a native file object is present after the test')
    parser.add_argument('--stall-request', type=int, help='Diagnostic host only: inject one stalled cloud rewrite request')
    args = parser.parse_args()
    if args.native and not args.app_log:
        parser.error('--native requires --app-log')
    if (args.require_realtime or args.require_live or args.expect_fallback) and not args.native:
        parser.error('Native caption assertions require --native')
    if args.require_realtime and args.expect_fallback:
        parser.error('Choose either real-time recognition or the forced fallback check')
    if args.stall_request is not None and (args.native or args.stall_request < 1):
        parser.error('--stall-request must be positive and is limited to diagnostic mode')
    if not args.native:
        processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
        if str(ROOT / '.build/Flow Attachments.app/Contents/MacOS/Flow') in [p.strip() for p in processes.splitlines()]:
            parser.error('Quit the installed Flow app before diagnostic mode; its signature and grants stay untouched.')
    safe_name = ''.join(c if c.isalnum() or c in '-_' else '-' for c in args.name)
    work = ROOT / '.build/adaptive-voice-review' / f'{safe_name}-{datetime.now():%Y%m%d-%H%M%S}'
    work.mkdir(parents=True, exist_ok=False)
    subprocess.run(['swift', 'build'], cwd=ROOT, check=True, stdout=(work / 'build.log').open('w'), stderr=subprocess.STDOUT)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    objects = [p for p in (binary / 'Flow.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/FlowApp.swift.o')]
    info = work / 'Info.plist'
    info.write_bytes(plistlib.dumps({'NSMicrophoneUsageDescription': 'Record the explicitly requested Flow voice test.',
        'NSSpeechRecognitionUsageDescription': 'Use existing live-caption authorization for this voice test.'}))
    executable = work / 'VoiceReview'
    command = ['swiftc', '-parse-as-library', '-I', str(binary / 'Modules'), '-I', str(ROOT / 'Sources/CFlow/include'),
        str(ROOT / 'scripts/record-adaptive-voice.swift'), *objects, str(ROOT / 'flow-core/target/debug/libflow.a'),
        '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(info), '-o', str(executable)]
    for framework in ['CoreAudio', 'AudioToolbox', 'Security', 'SystemConfiguration', 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation']:
        command += ['-framework', framework]
    with (work / 'link.log').open('w') as output:
        subprocess.run(command, cwd=ROOT, check=True, stdout=output, stderr=subprocess.STDOUT)
    import re
    detail = subprocess.check_output(['afinfo', str(args.speech.resolve())], text=True)
    duration = float(re.search(r'estimated duration:\s*([0-9.]+)', detail).group(1))
    command = [str(executable), '--recording-preview', '--output', str(work), '--speech', str(args.speech.resolve()), '--duration', str(duration)]
    if args.native: command += ['--native', '--app-log', str(args.app_log.resolve())]
    if args.new_test_draft: command.append('--new-test-draft')
    environment = {**os.environ, 'NSUnbufferedIO': 'YES'}
    server, events = None, []
    if args.stall_request:
        server, events = fault_proxy(work, args.stall_request)
        environment['FLOW_STREAM_ENDPOINT'] = f'http://127.0.0.1:{server.server_port}/transcribe-stream'
    try:
        with (work / 'app.log').open('w') as output, (work / 'errors.log').open('w') as errors:
            subprocess.run(command, cwd=ROOT, stdout=output, stderr=errors, env=environment, check=True)
    finally:
        if server:
            server.shutdown(); server.server_close()
            (work / 'injected-fault.json').write_text(json.dumps(events, indent=2) + '\n')
    if not (work / 'timing.json').is_file():
        raise SystemExit(f'Voice test did not finish. Inspect private log: {work / "errors.log"}')
    report = json.loads((work / 'timing.json').read_text())
    checks = {'processing_completed': report['processing_completed'],
              'message_populated': report['final_characters'] > 0,
              'nothing_sent': report['send_generated'] is False}
    if args.require_realtime:
        checks.update(cloud_captions_observed=report['native_cloud_caption_updates'] > 0,
                      real_time_final_transcript=report['native_final_realtime_transcript'])
    if args.expect_fallback:
        checks.update(on_device_captions_observed=report['native_on_device_caption_updates'] > 0,
                      fallback_used=not report['native_final_realtime_transcript'])
    if args.require_live:
        checks.update(captions_while_speaking=report['native_caption_updates_before_stop'] >= 2,
                      model_streamed_while_speaking=report['draft_updates_before_stop'] >= 2,
                      genuine_final_asr_handoff=report['native_asr_source'] in ['cloud', 'on_device'])
    if args.expect_attachment: checks['native_attachment_present'] = report['attachments_after'] > 0
    report['checks'] = checks
    (work / 'timing.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Recording and timings: {work}')
    if not all(checks.values()):
        raise SystemExit('Voice verification failed: ' + ', '.join(k for k, v in checks.items() if not v))


if __name__ == '__main__':
    main()
