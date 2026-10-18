#!/usr/bin/env python3
"""Exercise real Rust memory and deployed agentic generation with synthetic text."""
import argparse
import ctypes
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT/"review/contact-learning-verification.json")
    args = parser.parse_args()
    lib = ctypes.CDLL(str(ROOT/"flow-core/target/debug/libflow.dylib"))
    lib.flow_init.argtypes = [ctypes.c_char_p]; lib.flow_init.restype = ctypes.c_void_p
    lib.flow_destroy.argtypes = [ctypes.c_void_p]; lib.flow_destroy.restype = None
    lib.flow_free_string.argtypes = [ctypes.c_void_p]; lib.flow_free_string.restype = None
    lib.flow_format_text.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.flow_format_text.restype = ctypes.c_void_p
    lib.flow_record_final_text_for_contact.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.flow_record_final_text_for_contact.restype = ctypes.c_int32
    lib.flow_get_last_error.argtypes = [ctypes.c_void_p]; lib.flow_get_last_error.restype = ctypes.c_void_p

    def take(ptr):
        if not ptr: return None
        try: return ctypes.string_at(ptr).decode()
        finally: lib.flow_free_string(ptr)

    def generate(engine, speech, contact):
        text = take(lib.flow_format_text(engine, speech.encode(), b"Messages", contact.encode()))
        if text is None: raise RuntimeError(take(lib.flow_get_last_error(engine)) or "No model response")
        return text

    owner, other_user = lib.flow_init(b":memory:"), lib.flow_init(b":memory:")
    if not owner or not other_user: raise RuntimeError("Could not initialize isolated users")
    try:
        before = generate(owner, "Can you check the slides tomorrow?", "Alex")
        edit = "yo can u check the deck tomorrow?"
        receipt = lib.flow_record_final_text_for_contact(owner, edit.encode(), b"Alex")
        command = "Hey Flow ask for a slides review on Friday"
        own = generate(owner, command, "Alex")
        other_contact = generate(owner, command, "Sam")
        separate_user = generate(other_user, command, "Alex")
        override = generate(owner, "Hey Flow ask for a slides review on Friday; use the word slides, not deck", "Alex")
        checks = {
            "sent_edit_recorded": receipt >= 0,
            "agentic_output_uses_contact_edit": "deck" in own.lower() and "friday" in own.lower(),
            "another_contact_does_not_inherit_edit": "deck" not in other_contact.lower() and "slides" in other_contact.lower(),
            "another_user_does_not_inherit_edit": "deck" not in separate_user.lower() and "slides" in separate_user.lower(),
            "explicit_current_request_overrides_memory": "slides" in override.lower() and "deck" not in override.lower(),
        }
        result = {"kind": "actual Rust final-send memory and deployed agentic LLM; isolated synthetic users and contacts", "checks": checks,
            "initial_model_output": before, "sent_edit": edit, "agentic_request": command, "alex_after_edit": own,
            "sam_without_alex_edit": other_contact, "other_user_alex": separate_user, "explicit_override": override}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2)+"\n")
        print(json.dumps(result, indent=2))
        if not all(checks.values()): raise SystemExit("A learning check failed; inspect the saved outputs")
    finally:
        lib.flow_destroy(owner); lib.flow_destroy(other_user)


if __name__ == "__main__": main()
