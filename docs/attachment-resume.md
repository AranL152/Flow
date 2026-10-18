# Resume after the Mac restart

The user asked to implement “Flow, attach…” and then needed to restart the Mac.
Continue the same conversation; implementation is committed on the fork's main.
Push only to `AranL152/Flow`, never upstream. No coauthor trailers or new branches.

## Completed

- Explicit voice command parsing before formatting, with separate inert source
  metadata through Worker → Rust → Swift. The composer receives message chunks only.
- Clipboard images/copied files, recent matching Downloads, native previews and
  guarded Messages paste dispatch. No automatic Send.
- Static email snippets repaired in Auto audio streaming.
- Contact learning excludes attachment instructions and rich-text object markers.
- Separate attachment replay and synthetic PDF/audio fixtures. Future demo runtime
  files and reports use the temporary directory rather than Desktop.
- No Downloads scan at launch or during ordinary recording. No automatic speech
  authorization request during replay. Access failures stop background observation.

## Verification and current limits

350 Rust tests passed (2 ignored), 84 worker tests passed, 16 Swift tests passed.
The real Rust/Whisper/LLM audio probe passed all 5 cases. See
`review/attachment-stream-verification.json` and `docs/attachment-commands.md`.
The final worker deployment is version `388d2369-ca4f-4516-89c0-640e4dbfe68b`.

The first GUI attachment replay exposed punctuation/cue recognition failures;
those were corrected and verified headlessly. The user then reported many access
prompts. GUI relaunches were stopped. Do not repeatedly launch/re-sign demos and
ask for access again. New normal and demo bundles were prepared without opening
them: `.build/Flow Attachments.app` and `.build/Flow Attachments Demo.app`.

After restarting, the user requested continuation with all demos closed. One
prepared attachment demo was reopened with `--reuse-bundle`, without rebuilding
or re-signing. Its GUI run passed, presented five genuine model chunks and
selected `Project-review.pdf` from the synthetic Downloads folder. Live captions
were unavailable and no authorization was requested. The window was left open.
See `review/attachment-demo-verification.json`.

The user then clarified that the demo must use real Messages. A helper linked
the production Swift components under the editor's existing AX/microphone grants.
Messages accepted five genuine LLM chunks through five AX writes. A PDF was
appended, then a separate attachment-only request appended a clipboard image.
Two native AXAttachment objects remain in the actual unsent draft; original text
was preserved. Do not send or clear this draft without the user's instruction.
See `review/imessage-verification.json`.

The real test found/fixed the AXTextField `messageBodyField` composer and its
empty AXValue behavior. Contact capture now uses native AX rather than System
Events. Native attribution also confirms acceptance after paste. Streaming into
an already attachment-bearing draft uses the final-paste fallback if no safe AX
selected-text writer is available; existing objects must never be flattened.

Actual microphone start/sample capture/stop passed at 44.1 kHz. Generated audio
fed the real HUD's measured levels; speech response and silence settling passed.
The real contact-learning regression also passed all five checks. Microphone
audio was not uploaded; synthetic audio was used for cloud ASR. Live captions
remain unauthorized. Global hotkey delivery and real browser download completion
were not tested during this run.

## Restart considerations

Normal app learning is persisted in its database. Isolated demo memory is
process-local and resets on restart. No messages were sent. A new unsent test
draft with synthetic attachments was inserted into the initially empty composer.

The user asked about one-time file access. Answer given: System Settings →
Privacy & Security → Full Disk Access for the app actually named in the prompt
(Flow, Codex or Terminal), or Downloads under Files & Folders for narrower access.
Speech, microphone and Accessibility are separate. The underlying folder access
does not require repeated approvals for every file under a stable authorized app.

To run the separate attachment simulation when the user wants it:

```sh
python3 scripts/simulate-voice.py --attachment --reuse-bundle
```

This reuses the signed bundle without rebuilding or re-signing it. It launches
the prepared demo and can use existing speech authorization, but
never automatically requests it. The simulation operates on synthetic Downloads
and does not insert into a real Messages conversation.
