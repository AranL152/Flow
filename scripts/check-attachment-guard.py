#!/usr/bin/env python3
"""Replay recorded planner outputs through an explicit-cue policy; no AI calls."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
cases = {c['id']:c for c in json.loads((ROOT/'flow-worker-langgraph/experiments/attachment-intent/cases.json').read_text())}
probe = json.loads((ROOT/'review/attachment-intent-verification.json').read_text())
results=[]
for result in probe['results']:
    case=cases[result['id']]
    plan=result.get('plan')
    reason='unchanged_model_plan'
    if plan is None:
        plan={'message':'','requests':[],'needs_clarification':True}; reason='invalid_plan_requires_choice'
    elif plan['requests'] and not re.search(r'\bflow\s*[,;:]?\s+(?:attach|find|search)\b',case['text'],re.I):
        if re.match(r'^tell\s+alex\b',case['text'],re.I):
            plan={'message':re.sub(r'^tell\s+alex\s*[,;:]?\s*','',case['text'],flags=re.I),'requests':[],'needs_clarification':False}
            reason='recipient_message_is_not_a_tool_request'
        else:
            plan={'message':'','requests':[],'needs_clarification':True};reason='assistant_cue_required'
    checks={'sources':sorted(r['source'] for r in plan['requests'])==sorted(case['sources']),
        'clarification':plan['needs_clarification']==case.get('clarify',False)}
    if case.get('exact_message'): checks['literal_message_preserved']=plan['message']==case['text']
    if case.get('message_empty'): checks['no_invented_message']=not plan['message'].strip()
    if 'kind' in case: checks['correct_type']=len(plan['requests'])==1 and plan['requests'][0]['kind']==case['kind']
    for word in case.get('contains',[]): checks['message_has_'+word]=word.lower() in plan['message'].lower()
    for word in case.get('excludes',[]): checks['message_excludes_'+word]=word.lower() not in plan['message'].lower()
    for word in case.get('query_contains',[]): checks['query_has_'+word]=word.lower() in ' '.join(r['query'] for r in plan['requests']).lower()
    results.append({'id':result['id'],'passed':all(checks.values()),'policy':reason,'plan':plan,'checks':checks})
output={'kind':'deterministic policy replay on the same development cases; no new inference, ASR or attachment execution',
    'limitations':['This demonstrates a proposed boundary, not held-out model accuracy','Quoted assistant cues and more complex conversational phrasing still need separate held-out evaluation'],
    'summary':{'cases':len(results),'passed':sum(r['passed'] for r in results),'policy_interventions':sum(r['policy']!='unchanged_model_plan' for r in results)},'results':results}
(ROOT/'review/attachment-guard-replay.json').write_text(json.dumps(output,indent=2)+'\n')
print(json.dumps(output['summary'],indent=2))
assert all(r['passed'] for r in results)
