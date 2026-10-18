#!/usr/bin/env python3
"""Check configured email expansion in typed and Auto audio paths using fixtures."""
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT=Path(__file__).resolve().parents[1]
lib=ctypes.CDLL(str(ROOT/'flow-core/target/debug/libflow.dylib'))
lib.flow_init.argtypes=[ctypes.c_char_p];lib.flow_init.restype=ctypes.c_void_p
lib.flow_destroy.argtypes=[ctypes.c_void_p];lib.flow_destroy.restype=None
lib.flow_free_string.argtypes=[ctypes.c_void_p];lib.flow_free_string.restype=None
lib.flow_add_shortcut.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];lib.flow_add_shortcut.restype=ctypes.c_bool
lib.flow_format_text.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p];lib.flow_format_text.restype=ctypes.c_void_p
callback_type=ctypes.CFUNCTYPE(ctypes.c_bool,ctypes.c_char_p,ctypes.c_void_p)
lib.flow_transcribe_audio_stream.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_char_p,ctypes.c_char_p,callback_type,ctypes.c_void_p]
lib.flow_transcribe_audio_stream.restype=ctypes.c_void_p

def take(ptr):
    if not ptr:return None
    try:return ctypes.string_at(ptr).decode()
    finally:lib.flow_free_string(ptr)

engine=lib.flow_init(b':memory:')
if not engine:raise RuntimeError('Could not initialize isolated Flow')
try:
    address='aran@example.test'
    assert lib.flow_add_shortcut(engine,b'my email',address.encode())
    speech='You can reach me at my email'
    typed=take(lib.flow_format_text(engine,speech.encode(),b'Messages',b'Alex'))
    chunks=[]
    @callback_type
    def receive(delta,context):
        if delta:chunks.append(delta.decode())
        return True
    with tempfile.TemporaryDirectory(prefix='flow-email-shortcut-') as folder:
        audio=Path(folder)/'voice.aiff';wav=Path(folder)/'voice.wav'
        subprocess.run(['say','-v','Samantha','-r','155','-o',str(audio),speech],check=True)
        subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(audio),str(wav)],check=True)
        with wave.open(str(wav),'rb') as source:pcm=source.readframes(source.getnframes())
        buffer=ctypes.create_string_buffer(pcm)
        streamed=take(lib.flow_transcribe_audio_stream(engine,buffer,len(pcm),16000,b'Messages',b'Alex',receive,None))
    result={'kind':'live Rust shortcut + existing cloud model; generated speech, in-memory user, synthetic email',
        'speech':speech,'configured_trigger':'my email','configured_value':address,
        'typed_output':typed,'audio_stream_output':streamed,'audio_model_chunks':chunks,
        'checks':{'typed_expansion_works':bool(typed) and address in typed,'auto_audio_expansion_works':bool(streamed) and address in streamed},
        'scope':'diagnostic only; no production fix, clipboard writes or real messages'}
    (ROOT/'review/shortcut-stream-verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    if not all(result["checks"].values()): raise SystemExit(1)
finally:lib.flow_destroy(engine)
