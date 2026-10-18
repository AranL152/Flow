#!/usr/bin/env python3
"""Test a local-only planning prototype with synthetic dictations; no file actions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import statistics
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:8792/probe")
    parser.add_argument("--output", type=Path, default=ROOT/"review/attachment-intent-verification.json")
    args = parser.parse_args()
    cases = json.loads((ROOT/"flow-worker-langgraph/experiments/attachment-intent/cases.json").read_text())

    def run(case):
        request = urllib.request.Request(args.endpoint, data=json.dumps({"mode":case["mode"],"transcript":case["text"]}).encode(), headers={"Content-Type":"application/json"})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=60) as response: result = json.load(response)
            p = result["plan"]
            checks = {"correct_sources":sorted(r["source"] for r in p["requests"])==sorted(case["sources"]),
                "clarification":p["needs_clarification"]==case.get("clarify",False)}
            if case.get("exact_message"): checks["literal_message_preserved"] = p["message"]==case["text"]
            if case.get("message_empty"): checks["no_invented_message"] = not p["message"].strip()
            if "kind" in case: checks["correct_type"] = len(p["requests"])==1 and p["requests"][0]["kind"]==case["kind"]
            for word in case.get("contains",[]): checks["message_has_"+word] = word.lower() in p["message"].lower()
            for word in case.get("excludes",[]): checks["message_excludes_"+word] = word.lower() not in p["message"].lower()
            for word in case.get("query_contains",[]): checks["query_has_"+word] = word.lower() in " ".join(r["query"] for r in p["requests"]).lower()
            return {"id":case["id"],"input":case["text"],"mode":case["mode"],"passed":all(checks.values()),"checks":checks,**result,"wall_seconds":round(time.monotonic()-started,3)}
        except Exception as error:
            return {"id":case["id"],"input":case["text"],"mode":case["mode"],"passed":False,"error":str(error),"wall_seconds":round(time.monotonic()-started,3)}

    with ThreadPoolExecutor(max_workers=3) as pool: results = list(pool.map(run,cases))
    times = [r["milliseconds"] for r in results if r.get("model_called")]
    summary = {"cases":len(results),"passed":sum(r["passed"] for r in results),"guarded_dictation_cases":sum(not r.get("model_called",True) for r in results),
        "assist_requests":sum(c["mode"]=="assist" for c in cases),"valid_model_plans":len(times),"model_median_ms":statistics.median(times) if times else None,
        "model_max_ms":max(times) if times else None}
    output = {"kind":"synthetic text intent feasibility test, existing Workers AI model through local-only prototype; no ASR or real file insertion", "model":"@cf/meta/llama-3.3-70b-instruct-fp8-fast",
        "limitations":["Hand-authored development cases, one run per case, not a held-out accuracy benchmark", "Dictation-mode cases pass through a deterministic guard and do not measure model classification", "No actual clipboard, Downloads, private file contents, message recipients or sending used"],"summary":summary,"results":results}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(output,indent=2)+"\n")
    print(json.dumps(summary,indent=2))
    for result in results:
        if not result["passed"]: print(json.dumps(result,indent=2))
    if not all(r["passed"] for r in results): raise SystemExit(1)


if __name__ == "__main__": main()
