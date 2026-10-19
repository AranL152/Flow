# Streaming presentation

`DictationPresentation.smooth` receives genuine provider events independently
of presentation. Every 33 ms it reveals a Unicode character batch proportional
to the remaining backlog (3–32 characters). It adds no word or punctuation
pauses. One trailing grapheme is held while the stream is open so split emoji
and combining characters are not briefly rendered broken. Completion follows
all text; cancellation stops receiving and presentation. Errors discard queued
presentation without promoting an incomplete result.

`DictationPresentation.reconcile` presents full text snapshots over an already
owned draft range. Replacement model prefixes are consumed at network speed
until they catch up to the visible draft; only the new suffix is paced. ASR/model
corrections can revise the visible prefix once. A validated final result may be
shorter than its preview. The app never inserts raw captions into the draft.

## Following speech in the bar

Listening captions retain a bounded 512-character history inside a fixed,
two-line-height viewport. Its bottom anchor follows every rendered change
without a scrolling animation. Older lines leave the viewport; the newest
words stay visible instead of being replaced by a trailing ellipsis. ASR bursts
fast-forward all but 12 trailing characters, limiting catch-up animation to four
33 ms frames. Model output uses its separate adaptive pacing.

While recording, the entire speech caption stays white, including possible
commands. After finalization, the complete white command appears for 220 ms,
then its single purple ripple and synchronized inner/outer glow run. Recognition
revisions never replay a whole paragraph before showing its newest words.

## Stalled live rewrites

Speculative rewrites have a 2-second text-idle deadline and a 6-second total
deadline. Cancellation propagates through the Swift receiver to Rust's 100 ms
cancellation heartbeat, including while waiting for HTTP response headers. The
latest candidate can retry once; subsequent speech starts a new candidate.
A failed preview keeps the current draft and cannot enter learning/history as
a completed result. The final inference request retains its own error handling.

These deadlines apply to speculative rewriting, not cloud speech finalization.
If the realtime transcript fails to finalize, the recorded-audio fallback can
still take several seconds. Smoother presentation cannot remove inference waits.

## Verification

All 63 Swift tests pass, including Unicode fragments, whitespace, metadata order,
corrections, long draft reconciliation, completion, upstream failure, cancellation
and deadline recovery. The bounded caption catch-up has a regression test.

Use an empty, unsent Messages draft to capture actual voice input and native writes:

```sh
python3 scripts/record-adaptive-voice.py --speech /path/to/speech.aiff --name review
# Installed app already running with an unbuffered log:
python3 scripts/record-adaptive-voice.py --native --app-log /path/to/app.log \
  --speech /path/to/speech.aiff --name native-review
# Diagnostic host only: stall one request, forward every other request to the real service.
python3 scripts/record-adaptive-voice.py --speech /path/to/speech.aiff --stall-request 4
```

The default diagnostic host uses production AppState with in-memory history;
`--native` drives the already installed app's actual Fn helper. Neither mode
installs or signs the app. Both play generated speech through speakers into the
physical microphone, record the screen, observe actual Messages updates and
never send. Existing draft text/attachments are never cleared. All footage,
logs and raw timing points remain private under `.build/adaptive-voice-review/`.
Obtain first-run microphone/file grants before a measured take: clicking a
permission dialog intentionally interrupts the draft insertion safety monitor.

Design references: [Deepgram interim results](https://developers.deepgram.com/docs/interim-results),
[AWS partial-result stabilization](https://docs.aws.amazon.com/transcribe/latest/dg/streaming-partial-results.html),
[AI SDK stream smoothing](https://ai-sdk.dev/docs/reference/ai-sdk-core/smooth-stream).
