# Real-time Cloudflare speech

Cloud Auto dictation now sends the existing microphone frames to Cloudflare's
Nova-3 over WebSockets while recording. At Stop it drains the cached audio tail,
sends CloseStream, waits for the final segments/closing Metadata, then supplies
that transcript to Rust. The worker skips batch Whisper and immediately begins
the existing streamed rewrite. Partial speech is displayed only in the HUD;
only LLM output enters the recipient's draft.

Finalized ASR segments accumulate across pauses; interim revisions replace one
another. Duplicate final segments are ignored. Missing finalization, malformed
responses, a disconnected stream, low segment confidence (below 0.85), a full
send queue or a two-second finalization timeout uses the existing recorded-audio
ASR path instead. Confidence is a heuristic, not a guarantee of correct wording.
If a recording of at least two seconds has no cloud transcript at Stop, fallback
starts immediately instead of adding a finalization wait to a stalled service.
The original recording remains available to the normal retry/history pipeline.

The automatic path currently applies to streamed cloud Auto recording on an
English-locale Mac. Local/OpenAI modes and non-English locales keep their existing
ASR. Personalized prompts, attachment parsing and recipient-scoped send learning
are shared with normal Rust dictation. Recording alone never trains a rule.
The native Messages simulation also feeds this real-time client before Stop.
The 40 ms smooth display pacing is unchanged and independent of network speed.

No new microphone or Speech permission is requested by the cloud client, and no
new packages are added. The worker limits each socket to five minutes of mono
PCM16 at 8–48 kHz, closes idle sessions, and accepts only audio and CloseStream
from clients. The app starts a socket only when audio is captured. This task
updates the existing worker and builds the app components; it does not replace
or re-sign the installed permissioned app bundle.

## Cost, checked October 18, 2026

[Cloudflare's model prices](https://developers.cloudflare.com/workers-ai/platform/pricing/)
list Nova-3 WebSockets at $0.0092/audio minute ($0.552/hour). Batch Whisper is
$0.0005/minute, so real-time speech has a higher rate. Our unchanged default
Llama 3.3 70B formatter costs $0.293/million input tokens and $2.253/million output
tokens. All figures below are USD before free allowances, tax and other usage.
Retries and audio fallback can add inference usage.

With 1,000 prompt tokens and 100 output tokens per rewrite:

| Usage | Speech + rewriting |
| --- | ---: |
| One 10-second utterance | $0.00205 |
| 100 such demo runs | $0.205 |
| 10 minutes/day, in 10-second utterances, for 30 days | $3.69 |

Workers AI includes 10,000 neurons per day shared across the account's models.
Unused daily allocation does not roll over. It can cover light demo usage;
actual availability depends on the account's other AI calls. Above it, the
[Workers Paid plan](https://developers.cloudflare.com/workers/platform/pricing/)
starts at $5/month plus overages. No billing plan is purchased or changed by
the deployment. These are estimates, not an inspection of the account's bill.

## Verification

`python3 scripts/verify-cloud-speech.py` runs real billable inference with three
synthetic utterances paced like speech, then compares each with batch ASR through
the same Rust pipeline. It checks live updates, finalized transcript handoff,
complete real model chunks, preserved message wording and attachment plans.
It uses an in-memory database and never captures a microphone or writes Messages.
See [the report](../review/cloud-speech-verification.json) for per-sample timing
and any fallback. This is a small sequential check, not a median/p95 benchmark.
During initial checks, one batch comparison hit the existing model-truncation
guard. Such errors are failures, never completed drafts or learning evidence;
the verification runner records them rather than crashing or hiding them.
An [initial three-utterance comparison](../review/cloud-speech-initial-comparison.json)
also recorded a stalled cloud stream falling back successfully. Its extra drain
wait motivated the immediate-fallback guard above; the unit test verifies that
this case returns without waiting for the two-second finalization timeout.

The latest three-utterance run passed message/attachment checks on every route.
Two utterances used finalized real-time ASR: Stop to first real LLM delta was
440 and 466 ms, versus 1,378 and 2,495 ms for their batch comparisons. The third
used recorded-audio fallback (4,049 ms versus 4,837 ms for its batch comparison).
All times exclude deliberate display pacing. This is evidence of a faster start
when real-time ASR finishes cleanly, not consistent sub-second performance.

Validation also passed 42 Swift tests, 351 Rust tests (two macOS integration
tests ignored), 99 worker tests, worker typechecking and a typecheck of the
updated full Messages runner. The Rust fixture verifies the finalized-ASR handoff,
recipient identity, no learning before Send and saved edited text after Send.

The native indicator, ripple and attachment layout have not changed. The installed
app's microphone/hotkey path requires the updated app to be launched separately;
the scoped tests above do not claim it was exercised.
