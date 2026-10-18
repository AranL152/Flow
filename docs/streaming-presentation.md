# Streaming presentation

`DictationPresentation.smooth` sits between genuine Rust/model events and the
native UI. Receiving continues independently; it is not slowed by display pacing.
Ordinary text appears in two-character frames about 45 ms apart, with a short
punctuation pause. Large backlogs use larger frames to catch up. Frames preserve
Unicode graphemes and metadata order; completion waits until all received text
has been presented. Errors discard queued presentation; cancellation stops both
tasks. Display time is deliberately different from model generation latency.

The normal app, isolated voice simulation and full Messages demo share this
adapter. The simulation's readable-playback toggle bypasses pacing when disabled.
Raw receipt events remain separate from presentation events in its report.

The native app still requires a safe Accessibility insertion path for incremental
writes into another app. Its existing final-paste fallback remains for rich drafts
without a writable selected-text range. The Messages demo uses the previously
verified Unicode-event writer to preserve existing native attachment objects.

Verification: `swift test` includes burst splitting, Unicode fidelity, event order,
steady presentation intervals, cancellation and upstream failure. The Messages
runner records raw provider chunk count, display frame count, native write count
and presentation duration separately.
