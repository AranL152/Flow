# Real-time Cloudflare speech

## Reliability update, October 18

The repeated native speech failures were traced to Workers AI error 4006 / HTTP
429: the account's daily free 10,000-neuron allowance was exhausted. The old
worker hid that response behind a generic HTTP 502 WebSocket upgrade failure.
The user enabled Workers Paid, and real speech connections resumed. This removes
that free-tier quota block; it cannot guarantee provider availability.

Speech startup failures now complete the WebSocket upgrade and deliver a typed
Error frame, so the Mac can explain quota exhaustion or a temporary outage. An
exhausted quota is not retried. A transient HTTP 5xx startup failure gets one
bounded retry. Upstream connection waits, batch recognition, model startup and
model stream reads have deadlines; the final native pipeline also has a bounded
wait and restores its own provisional insertion on failure.

The formatter retains Llama 3.3 70B. A real comparison found that 8B was not
consistently faster and 3B leaked transcription tags; see the
[scoped model comparison](../review/rewrite-model-comparison.json). If the first
model token stalls for 800 ms, the worker starts one identical backup request.
The first stream to supply an actual delta wins. The other is cancelled; tokens
are never mixed and no retry starts after output is displayed. A slow request
can therefore incur one additional inference call. Pending binding calls may
still run until their stream arrives and can be cancelled. Quota failures do not
trigger a retry.

The stream decoder now prefers the exact `choices.delta.content` string.
Workers AI's convenience `response` can turn numeric tokens into JSON numbers,
losing spelling such as the trailing zero in `204.50`. This formerly caused
otherwise valid numerical messages to fail streaming validation.

When Apple Speech Recognition is authorized, the same microphone frames also
produce continuous on-device captions. Those captions remain visible while the
cloud catches up. Closely spaced cloud revisions are coalesced over 40 ms to
avoid showing a briefly shortened prefix between segment updates.

After Stop, Cloudflare gets a 600 ms head start to provide its final transcript.
A genuine Apple final delivered after end-of-audio, with mean segment confidence
of at least 0.85, can then hand off to the normal Rust personalization and cloud
LLM pipeline. A lower-scored final (at least 0.5) requires independent cloud
agreement on every word, ignoring case and punctuation; a cloud prefix or a
different name cannot qualify. An interim caption or a final from an earlier pause cannot qualify.
If neither real-time recognizer supplies a usable final, saved-audio recognition
remains the fallback. Confidence thresholds are heuristics, not proof of accuracy.
Only actual model output enters Messages; ASR captions remain in the voice HUD.

Enable the optional Apple backup using Flow → Settings → General → Enable speech
recognition for captions. The installed app now has that grant under the
persistent certificate. Updates and launches must not reset or re-add it.

Recorded verification uses the actual installed bundle and Fn helper, speaker
playback through the physical microphone, real Cloudflare inference, and fresh
unsent Messages drafts addressed to unique `example.invalid` test recipients.
It never presses Send or clears existing drafts. Footage, recipient labels and
raw logs stay private under `.build/`.

`scripts/record-adaptive-voice.py --native --new-test-draft --require-live
--expect-attachment --speech <audio.aiff> --app-log <unbuffered-native-log>` checks
captions and model writes before Stop, a genuine finalized ASR handoff, completed
processing and a native attachment object. `--require-realtime` additionally
requires Cloudflare itself to finalize; `--expect-fallback` checks an explicitly
injected speech-socket outage. The runner fails if its assertions fail.

See [the native reliability report](../review/cloud-reliability-verification.json)
for measured runs, including the earlier stall that motivated the local-final
handoff. These are generated-voice tests on this Mac, not a human-voice accuracy
benchmark or a promise of uninterrupted cloud service.

After the final server update, three consecutive recorded native runs used real
cloud finals, displayed 13 draft updates each before Stop and attached the real
saved screenshot. First recognizer captions arrived 0.90–1.16 seconds after
speaker playback began; native attachment staging finished 1.75–2.01 seconds
after Stop. A forced speech-socket outage kept local captions/model preview live,
used a completed on-device final and staged the attachment in 3.01 seconds.
The production numeric stream also preserved `3:15`, `204.50` and the synthetic
test email across 20 model deltas. Validation passed 69 Swift tests, 140 worker
tests/typechecking and five targeted Rust stream tests. All four native privacy
grants remained authorized under the persistent signing certificate.

## Original cloud-only path and earlier measurements

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
updates the existing worker and builds the app components. The website demo uses
its own runner and does not require installing the normal app. A later native
installation investigation did update that bundle; see native-install.md.

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

The native indicator, ripple and attachment layout have not changed. The normal
app was subsequently packaged and launched, with its signature/resources checked;
its actual microphone/hotkey path was not exercised. This install is optional
and is not a requirement for the Messages demo or website recording.
