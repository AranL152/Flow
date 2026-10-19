# Resume after the Mac restart

The user asked to implement “Flow, attach…” and then needed to restart the Mac.
Continue the same conversation; implementation is committed on the fork's main.
Push only to `AranL152/Flow`, never upstream. No coauthor trailers or new branches.

## Latest scope clarification — October 18

The target is the website demo, not normal-app installation. The user clarified:
“isnt this just for the demo?” Use the existing full Messages runner with generated
speech and the latest production UI/cloud pipeline. It builds its own helper;
normal app installation and hotkey permission setup are not prerequisites.

Real-time Cloudflare Nova is deployed, with finalized-ASR handoff through Rust,
personalization, attachment parsing and normal send learning. See cloud-speech.md
for costs, fallback and scoped timing checks. The normal bundle was updated and
launched during an unnecessary install investigation; code commit 28e2d38 is in
its plist and the old bundle is backed up under .build/native-app-backups. Its
UI reported Accessibility disabled; do not require enabling it to make the video.
The synthetic preview was closed; the Messages draft was not changed by install.

The user reported granting access, then requested the Flow-command demo again.
The normal app's menu still reported Accessibility disabled after activation;
do not send them through that optional setup to make the website video. The
controlled Messages runner succeeded using its existing host access.

`simulate-imessage-full.py --kind screenshot` then passed all 12 scoped checks
with actual Cloudflare real-time ASR. It played generated speech, delivered 12
caption updates, ran the existing purple command effect, and inserted five real
LLM chunks as 38 display frames/19 native writes over 1.55 seconds. First display
was 637 ms after Stop; finalizing ASR took 181 ms. Orion-dashboard.png was appended
and the Other matches popup left open. Total demo runtime was 9.84 seconds.
Existing draft text/files were preserved; no Send or replacement test was run.
See review/imessage-full-demo-verification.json. This does not verify physical
microphone or hotkey operation in the normal app.

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

## Recording bar phase correction (October 18)

The user asked to hide the voice waveform during transcription and to propose a
visual effect distinguishing a Flow command from recipient text. The waveform,
recording dot and timer now appear only during active recording. Processing shows
Transcribing… with its progress indicator, including while output is streaming.
The separate You said caption remains visible. Loading retains its own status.

`swift build` passed. Native view snapshots were visually reviewed for recording
and processing (including isStreamingOutput=true and a stale nonzero meter value).
See review/recording-listening.png and review/recording-transcribing.png. This was
a local UI preview, without microphone recording, API calls or Messages changes.
Command effects are proposals only: purple command highlighting/chip, a subtle
recognition pulse, and a visual handoff into the attachment picker. They have not
been implemented or chosen yet.

## Liquid command effect implemented (October 18)

The user approved the liquid/ripple proposal. It is now implemented in native
caption views: an explicit Flow attach/find/search cue splits the white recipient
message from a purple semibold command line with a Flow command badge. A single
650 ms ripple/glint plays after recording stops, then settles. Full-transcript
styling guards block quoted, reported and negated speech; they do not execute
commands or replace worker parsing. Reduce Motion keeps a static highlight.
The actual attachment session drives Finding screenshot/image/file… and other
status labels, and the picker repeats the Command badge. The full voice demo
passes its session into the HUD for that connection.

33 Swift tests and seven local native-preview checks passed. Native stills were
visually reviewed for motion, ordinary mentions, reduced motion and long wrapping.
See docs/command-ripple.md, review/command-ripple.gif and the scoped JSON report.
Run python3 scripts/preview-command-ripple.py for the open Replay preview. Captions
there are explicitly simulated, OCR is real and local, and no microphone, model
API or Messages write occurs. The previous OCR verification helper was stopped
by checked PID; the normal signed app and unsent Messages draft are preserved.
The installed app bundle still needs rebuilding for the normal hotkey workflow.

## Attachment popup margins corrected (October 18)

The user found the unselected picker header almost touching the top edge. The
card already had uniform 14-point padding, but the panel's estimated height
clipped it when the selection hint appeared. The panel now measures the native
SwiftUI content directly, outside its layout pass, and refits after session or
search-control changes. Its lower edge stays anchored as content height changes.

The native two-candidate panel measured 264 points without a selection and 238
after selection. Both actual panel snapshots were visually reviewed for even
14-point outer margins. All 33 Swift tests and 15 real local Spotlight/picker
checks passed. See review/file-search-unselected.png, file-search-preview.png
and file-search-verification.json. No microphone, model API, Messages paste,
permission prompts or installed-bundle replacement was involved.

## Slower, stronger ripple (October 18)

The user liked the effect and requested a slower ripple with stronger flow. The
pass now lasts 1.1 seconds instead of 650 ms, with a broader wave, up to 2.6 points
of glyph displacement and a slightly stronger glow. A short fade keeps the ends
smooth. Renderer and cleanup share one duration, and the native preview waits for
the longer pass before capturing its settled state.
The build and all seven native preview checks passed; the active frame was
visually reviewed for the stronger wave and readable letters. The refreshed
Replay preview remains open. No model APIs or Messages writes were used.

## Single left-to-right crest (October 18)

The user found the stronger oscillation excessive and asked for just one ripple
from left to right. The sinusoidal carrier is removed: a single Gaussian crest
now moves with the highlight, with up to 2 points of displacement and the slower
1.1-second duration. There are no trailing waves. Glow returns to the earlier
subtle strength.
The build and seven native preview checks passed again; the regenerated active
frame was visually reviewed, and the updated Replay preview is open.

## Faster pass with a finishing glow (October 18)

The user requested a faster ripple and a finish after it settles. The single
left-to-right crest now takes 700 ms. After the displacement ends, a soft purple
glow blooms once over 400 ms and fades, without further movement of the letters.
Reduce Motion still keeps all effects static. The native preview captures the
finishing glow separately before the fully settled frame.
The build and all eight native preview checks passed. The glow and settled
frames were visually compared, and the refreshed Replay preview remains open.
No model API calls, microphone recording or Messages writes were involved.

## Stronger finishing glow (October 18)

The user requested a stronger purple glow. The finishing pulse now has a brighter,
broader halo plus a tighter inner glow around the letters. The single 700 ms
ripple and 400 ms finish retain their timing; the extra glow is confined to the
finish and remains disabled with Reduce Motion.
The build and all eight native preview checks passed. The finishing frame was
visually reviewed, and the updated Replay preview remains open.

## Finishing flash inside the text (October 18)

The user clarified that the finish should glow inside the text, like the ripple
highlight, and that the whole command sentence should flash once. All outer
shadows are removed. The finishing pulse now brightens the purple glyph fill
across all command letters simultaneously, clipped to the cached alpha mask.
The single 700 ms ripple and 400 ms finish retain their timing. Recipient text
remains white, and Reduce Motion disables the flash.
The build and eight native preview checks passed. The flash and settled frames
were visually reviewed. A pixel comparison found 8,710 changed command pixels,
zero changed background pixels in the command region and zero changed recipient
text pixels. The updated Replay preview remains open.

## Synchronized inner and outer finish (October 18)

The user asked to strengthen the inner glow and restore the outer glow, with
both synchronized after the ripple settles. The fill now flashes brighter,
with a broad purple halo and a tighter glow around the letters. One shared
400 ms pulse drives fill brightness and both halo layers' opacity and radius,
so they rise, peak and fade together. The 700 ms single ripple is unchanged.
Reduce Motion disables the entire finish.
The build and eight native preview checks passed. The finishing frame was
visually reviewed, and pixel comparison confirmed both brighter glyphs and the
restored halo. White recipient-glyph pixels stayed unchanged within a two-level
RGB tolerance; the halo intentionally changes surrounding background pixels.
The refreshed Replay preview remains open.

## Centered processing pill (October 18)

The user approved the effect and requested it in the full demo, plus a centered
Transcribing label. The production recording pill now balances the leading
14-point spinner with an equal trailing slot, centering the label itself. The
spinner uses a dark appearance so it is visible against the pill in light-mode
previews too. The build and eight local native preview checks passed, and the
updated processing pill was visually reviewed. The same native recording view
already drives the Messages demo and production recording indicator.

## Approved effect shown in the full Messages demo (October 18)

The Messages runner now builds the current source before linking, preventing a
stale demo binary after UI edits. It uses the shared production recording view
and the actual attachment session, and closes the separate ripple preview helper.
A new check confirms that real generated-speech captions contain an explicit
Flow cue, so the approved effect is exercised through the actual caption path.

Ran the screenshot case in Messages: all ten checks passed. There were 16
on-device caption updates, six real model chunks and 23 paced native text writes
over about 1.05 seconds. The top-ranked synthetic screenshot was appended and
confirmed, with an alternative available. Existing text and native attachments
were preserved; the draft and candidate picker remain open, and nothing was sent.
This full run used the configured cloud pipeline, unlike local-only UI checks.
The existing installed app bundle and permissions were preserved.

## Smoother streamed output (October 18)

The user found the real LLM reveal too fast and abrupt. Shared presentation now
reveals ordinary messages one grapheme every 40 ms, with 80 ms comma/colon/
semicolon pauses and 160 ms sentence/newline pauses. Catch-up frames are bounded
to four graphemes. Model receipt remains independent, event order and Unicode
are preserved, and cancellation/errors still stop buffered output. All 34 Swift
tests passed, including the added long-burst jump limit.

Initial native checks stopped conservatively on draft/attachment changes; single
grapheme Unicode-event inserts were unreliable in this Messages draft. The demo
writer now combines adjacent display frames into native inserts of at most two
graphemes, flushes punctuation and the final remainder, and verifies acknowledged
text against the model output before staging the attachment. Focus, selection,
text and attachment guards remain. Error diagnostics report mismatch positions
and code units without printing the existing draft. Replays also leave existing
screenshot fixture files intact instead of rewriting attached sources.

A local native-only pacing check passed with 22 writes over about 1.84 seconds,
without model calls. The subsequent genuine screenshot demo passed all 12 checks:
six provider chunks became 44 single-grapheme display frames and 22 native writes
over 1.82 seconds (previous replay: 1.17 seconds). Maximum native write size was
two graphemes; the final text, old draft and old attachments were preserved and
the screenshot was confirmed with alternatives. See the updated full-demo JSON.
Nothing was sent. The latest successful full run used the configured cloud
pipeline; the installed app bundle and permissions were preserved.

## Recognize commands visually only after the utterance (October 18)

The user asked what happens when they simply say Flow, and requested that the
effect wait until the whole command has been spoken. Caption detection now
returns no command while recording, even after a complete cue has appeared.
All live words stay white and the badge remains hidden. After Stop, a reserved
Flow attach/find/search cue with a nonempty object gets the purple split, badge
and existing single ripple/synchronized glow. Bare cues such as Flow attach
stay plain. Ordinary Flow mentions, quoted/reported instructions and negation
retain their guards. This remains a presentation classifier; the worker's
authoritative attachment parser and action safeguards are unchanged.

All 35 Swift tests and nine local native-preview checks passed. Listening and
finishing screenshots were visually reviewed: the identical complete command
is white while recording and purple only afterward. The refreshed Replay
preview is open. Its launcher stops its checked previous Messages demo helper
to avoid duplicate candidate popups, preserving the unsent draft and installed
permissioned app. This verification used simulated captions and real local OCR,
without microphone recording, new cloud requests or Messages writes.

## Steady bar, plain status and animated Listening dots (October 18)

The user reported flicker after the command appeared, requested Listening instead
of You said, and wanted Attachment found as plain purple text rather than a pill.
The preview was cycling its visible state through reduced-motion, ordinary-text
and long-command test fixtures. Those now render in a separate hidden host,
leaving the main demo untouched. Native indicator show calls are idempotent and
no longer reset alpha to zero on phase updates. Hosting auto-sizing is disabled
for its fixed panel; caption/header space and lower-pill height are steadier.

The user then clarified that the purple listening effect should not color the
recipient message. All live words, including Here's the issue, remain white.
Only Listening and three small purple dots indicate capture; the dots pulse left
to right, like typing, and stop when recording ends. Reduce Motion keeps the
dots static. After Stop, the command-only ripple and synchronized fill/halo are
unchanged. The header shows plain purple command/search status after detection,
including Attachment found, with no status capsule. No You said label remains.

All 13 native preview checks passed, including repeated-show opacity/position and
hide/show interleaving. Listening and found frames were visually reviewed. Pixel
comparison verified changing dots, unchanged white live-message pixels across
dot frames and the same caption border position before/after recording. The
review GIF and stills are updated. These checks used synthetic captions and real
local OCR without microphone, cloud requests or Messages writes.

## Make attachment alternatives explicit (October 18)

The user wanted the popup to explain that the best match is already attached
and the list contains other choices, using concise language. After confirmation,
the picker now says Other matches and filters out Flow's currently attached file.
The count reflects the remaining choices. Select one to replace guides the next
action, and choosing a candidate changes the button to Replace. Done dismisses
without changing the file. Initial selection and single-file confirmation retain
their existing labels. Keyboard selection uses the visible list, including an
empty-list guard. During an active replacement, the alternative list stays stable.

The 15 real local Spotlight/picker checks passed with even margins in the original
selected/unselected states. A full generated-speech Messages run with replacement
verification passed all 13 checks: 16 live-caption updates, six model chunks,
44 display frames and 22 native writes over 2.07 seconds. The best screenshot was
added, an alternative was swapped in and the original restored, preserving text
and all unrelated objects. One earlier take stopped before typing because the
original draft changed during playback; its edit was retained.

The actual final popup was captured through its native view without screen-
recording access and visually reviewed: Other matches, one alternative, Select
one to replace and Done, with the already-attached file absent. See
review/imessage-other-matches.png and the updated full-demo report. The latest
Messages draft and picker remain open. No Send event was generated.

## Complete speech before recognition; dismiss suggestions after Send (October 18)

Late final ASR words now reveal in white before the purple command effect. The
complete white command holds 220 ms, then changes color in place with the approved
ripple and synchronized finishing glow. The HUD waits for that presentation even
when cloud rewriting finishes sooner. This does not insert raw speech into Messages.

The attachment popup now reads the pinned Messages draft every 150 ms while
visible. After observing content, two readable empty observations dismiss the
session and popup (normally within 300 ms after Send clears the composer).
Initially empty attachment-only drafts, unreadable accessibility state, another
conversation and active attachment replacement do not count as Send. Manual
clearing also dismisses obsolete suggestions. This is popup lifetime only and
does not manufacture a Send or a learning signal. Hiding stops the timer.

All 46 Swift tests, 14 caption preview checks and 17 native Spotlight/picker checks
passed. The native popup test simulated draft content clearing through an injected
read-only observation, without sending a real message. The white, ripple and
finishing frames were visually reviewed. The full generated-speech Messages demo
passed 14 checks in 9.88 seconds, with real cloud ASR/LLM streaming, screenshot
append and alternatives. Existing draft content was retained; nothing was sent.
The updated demo helper remains open; the installed app bundle was not replaced.

## Whole-word streaming (October 18)

The user requested one word at a time. Live captions now reveal complete words
110 ms apart, preserving word counts during recognition revisions. Rewritten
output uses complete words 180 ms apart with punctuation pauses. Provider token
fragments wait for a word boundary or completion; network receipt runs at full
speed. Text, whitespace and Unicode remain exact. The complete white caption
still precedes the purple command ripple. The Messages helper inserts each word
in one checked native Unicode event, with no carried-over single character.

All 48 Swift tests and 14 native caption checks passed. The full Messages run
passed 14 checks: seven display words and seven native writes over 1.13 seconds,
with preserved draft/attachments, screenshot append and alternative candidates.
This take used ASR fallback and took 17.82 seconds total. Nothing was sent; the
updated helper is open. The installed app bundle was not replaced.
