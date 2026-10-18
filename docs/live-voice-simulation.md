# Replay the native voice simulation

```sh
python3 scripts/simulate-voice.py
# Reuse an existing fresh Swift/Rust build:
python3 scripts/simulate-voice.py --skip-build
```

The script leaves **Flow · Live Voice Simulation** open with Reset and replay and Dictate again controls.
It generates two audible Samantha recordings and uses an isolated, in-memory
Flow engine. The left pane reuses the normal Record tab and floating recording
indicator. The right pane is a clearly labelled simulated conversation with Alex.
No microphone or real Messages conversation is used.

1. The generated voice says “Can you check the slides tomorrow?” Live recognition
   and measured audio levels drive the actual captions and waveform. Alex’s draft
   stays empty while speech plays; raw speech appears only under You said.
2. After speech stops, supplied PCM16 goes through the normal Rust provider,
   Cloudflare Whisper, model SSE, C callback and Swift async stream. The first
   model chunk starts Alex’s draft; later chunks append to it. Captions never
   populate the composer.
3. A labelled scripted edit changes the draft to “yo can u check the deck
   tomorrow?”. Simulated Send calls the production Rust final-text learning API.
   The edited example is saved specifically for Alex in the isolated engine.
4. New audio says “Can you check the slides on Friday?”. Actual model output
   reflects the saved example; it is not substituted with a fixed answer.

**Readable playback** displays each actually received model chunk 180 ms apart,
so a short response does not look instantaneous. Turn it off, then Replay to see
actual arrival speed. The report records receipt and presentation separately;
playback timing is not a latency measurement. There is no timer-generated speech
transcript or completed-response splitting.

After completion, edit the second draft and use Simulated Send to save that
example. The **Edit saved for Alex** card shows **Flow generated → You sent**,
so you can inspect the exact correction. The left panel is labelled **Original
LLM output** and retains the original generation. Saving does not rewrite that
history. Dictate again reuses relevant saved edits in the next model request;
Reset and replay explicitly clears fixture memory. Manual drafts stay inside
this process. This does not test Accessibility insertion into iMessage.

The report is `.build/voice-simulation/report.json`. The checked-in
[verification record](../review/voice-simulation-verification.json) contains
recognizer updates, individual received/presented chunks, and the learning result.
The launcher’s temporary job remains active to keep the window open. Stop it with
`python3 scripts/simulate-voice.py --stop`, or close its window.

This version updates the local report immediately after a manual Simulated Send,
including the exact before/after text. The card shows available recipient memory;
it does not claim every example was selected or that every correction must be
copied literally. Native UI changes appear after a new launch. Avoid restarting
a current analysis session without finishing it: its existing database is in memory.
