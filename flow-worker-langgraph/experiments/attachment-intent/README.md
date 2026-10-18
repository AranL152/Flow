# Attachment intent feasibility probe

Research only: this is **not** a production route or an implemented file agent.
It receives synthetic text and returns inert JSON plans. It never accesses files,
reads the general clipboard, attaches content, or sends a message. Do not deploy it.

From `flow-worker-langgraph`:

```sh
npx wrangler dev --config experiments/attachment-intent/wrangler.toml --local --ip 127.0.0.1 --port 8792
```

From the repo root in another terminal:

```sh
python3 scripts/verify-attachment-intent.py
python3 scripts/check-attachment-guard.py
swift scripts/verify-attachment-sources.swift review/attachment-sources-verification.json
python3 scripts/verify-shortcut-stream.py
```

The local Worker uses the existing Cloudflare account's real Workers AI binding;
AI requests incur its normal usage. No new public service is deployed.

The first live run met all assertions in **17/20** hand-written development cases.
Four cases bypassed the LLM through a hard normal-dictation guard; sixteen assist
requests attempted inference and fifteen returned valid plans. Two outputs
confused recipient messages/ambiguous imperatives with assistant actions; another
was rejected before producing a valid plan. The verifier exits nonzero for these
failures. The existing model is `@cf/meta/llama-3.3-70b-instruct-fp8-fast`.

The guard replay uses these **same recorded outputs**, requires an explicit Flow
cue for actions, and turns missing/invalid plans into a choice. It meets the case
assertions after three policy interventions; it is not a second model run or a
held-out success rate. More quoted, interrupted, multilingual and noisy speech
needs evaluation before production use.

The native probe uses a private pasteboard and temporary files only. Its seven
checks passed. Directory arrival order is represented by a synthetic observation
log, not actual browser download history.

The email probe reproduces a current integration gap: configured expansion works
for typed formatting but **fails in Auto audio streaming**. It uses generated
speech, an in-memory user and `aran@example.test`. Its nonzero exit is intentional
until the production pipeline is fixed.

See [the implementation plan](../../../docs/attachment-assistant-plan.md) and
[recorded results](../../../review/attachment-intent-verification.json).
