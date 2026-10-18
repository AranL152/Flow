# Resume after the Mac restart

The user asked to implement “Flow, attach…” and then needed to restart the Mac.
Continue the same conversation; implementation is committed on the fork's main.
Push only to `AranL152/Flow`, never upstream. No coauthor trailers or new branches.

## Current state: screenshot OCR and compact picker (October 18)

The user approved local screenshot-text search, then asked which LLM/API key the
demos use. Auto's configured default is Llama 3.3 70B with Whisper Large v3 Turbo
through Cloudflare Workers AI. The client OpenAI key is not used by Auto. Actual
billing was not inspected. All new OCR verification was local, without model calls.
The generic startup log was corrected to print the real selected provider name.

Say “Flow, find the screenshot showing payment error.” The native coordinator
combines filename matches and Apple Vision OCR over the latest 24 screenshots
within 30 days. Cache: ~/Library/Caches/Flow/ScreenshotOCR/text-v1.json, private,
bounded and invalidated by identity/size/mtime. UI shows matched words; general
photo/scene understanding is not implemented. See screenshot-text-search.md.

29 Swift tests, 97 worker tests plus typecheck, 11 native Spotlight/OCR/picker
checks and eight actual Messages OCR attachment checks passed. The latter used a
supplied local intent (no voice/model call), auto-appended a synthetic screenshot,
swapped to an alternative and back, preserving text and unrelated native objects.
The OCR picker/helper remains open over Messages. Run
`python3 scripts/verify-imessage-ocr.py` to replay that local attachment check.
The synthetic screenshot remains in the unsent draft; no Send event was produced.

Earlier complete voice demos in Messages passed for PDF and filename-based
screenshot search. Shared model presentation now paces small frames; their 7/6
raw chunks became 19/23 native updates, with 15/16 real caption updates. Alternatives
can be safely swapped with Use this file. See imessage-full-demo-verification.json.
The normal app's rich-draft final-paste fallback remains unchanged; the full demo
uses a separately verified Unicode writer for native attachment-bearing drafts.

The normal signed app was deliberately not repackaged or restarted, preserving
speech/AX grants. The open helper links rebuilt production modules. Its normal
hotkey workflow still needs an updated installed bundle. Known helpers are stopped
only after checking that their PID matches the expected executable. Do not send
or clear the existing Messages draft.

The paragraphs below describe the earlier manual-selection implementation.

The normal app was opened after diagnosing that only the isolated simulation was
running (simulation intentionally has no global hotkeys). It uses the default
hold-Fn shortcut when no saved shortcut exists. Physical key delivery still needs
the user's check.

The user then requested matching older files with preview/selection. The native
app now supports local Spotlight filename search via “Flow, find my robotics
presentation”, query refinement and a native file-picker fallback. Search results
require selection and Add to Messages, even for a single match. No recursive
file scan, content/image understanding or remote file upload is implemented.
Clipboard and recent-download behavior is preserved. The updated worker version
is `4082e438-703d-4ada-b7a3-c6e5c35e68cf`, with capability gating for old clients.

Live captions were gated by the separate Speech Recognition permission. Errors
and Settings now distinguish not requested, denied and restricted. Only the
explicit Enable button requests permission; denied access links to system
settings. No automatic permission request was added.

Verification: 95 worker tests plus typecheck, 351 Rust tests (2 ignored), 18 Swift
tests, 7/7 generated-speech pipeline cases and 11/11 real Spotlight/native preview
checks passed. The normal app was rebuilt/repackaged once after testing, then
reopened at `.build/Flow Attachments.app`; the older simulation bundle was left
unchanged. Caption authorization still requires the user's explicit Settings
action. No new Messages paste or Send was performed during the search checks.

The user enabled captions and requested a simulation. `simulate-voice.py
--file-search` reuses the exact signed normal bundle (no rebuild/re-sign), with
indexed synthetic Orion review PDFs and real speech/formatting/learning. Launching
through launchd still reported speech access as not requested; launching directly
under the native app's host context worked without any prompt, producing 32 live
caption updates and nine model chunks. The older attachment simulation was
closed; the normal app and the new isolated file-search replay remain open.

The user then requested the popup over actual Messages. The isolated replay was
closed and `scripts/simulate-imessage-popup.py` launched the production panel,
bound to the current real Messages composer/contact. An attachment-only voice
request found the two Orion review PDFs. Existing draft text and attachment count
were preserved. No automatic paste or Send was issued; the user can select and
press Add to Messages. The helper stays running with the popup interactive.
See `review/imessage-popup-verification.json`. No app was re-signed or restarted.

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


## Compact attachment picker and smooth output (2026-10-18)

The picker now measures its contents at 360 points wide, shows three compact
candidate rows at a time, and opens larger Quick Look previews from eye buttons.
Selection and In draft state are distinct. Use this file replaces only the native
attachment object owned by this session, preserving text and other objects.
Messages adds a newline during replacement; remove only the proven new separator
before confirming the exact original text. Unconfirmed changes offer manual copy.

Shared genuine-model presentation uses small frames around 45 ms apart with
punctuation pauses and catch-up for long bursts. It preserves event order and
Unicode, receives independently, and stops on cancellation/errors. This is display
pacing, not a model-latency improvement. The normal rich-draft fallback is unchanged.

24 Swift tests and 12 real Spotlight/native-panel checks passed. Both full Messages
cases passed all ten checks, including switching to an alternative and back while
preserving text and unrelated files. Raw 7/6 model chunks became 19/23 display
writes over about 0.86/1.04 seconds. The eye-button preview was also opened through
native Accessibility and visually checked. See the updated review JSONs and
file-search-preview.png. The final compact screenshot picker/helper remains open;
nothing was sent. The normal authorized app bundle was not re-signed or replaced.
