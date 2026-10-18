# Flow attachment commands

Implemented in the native app with the Auto cloud transcription provider. No new
packages, model training or MCP server are required.

Say the message first, then the attachment instruction:

> Here's the deck. Flow, attach the PDF I just downloaded.

Only the message reaches the personalized formatter and streams into the draft.
The source request travels separately through the worker and Rust into Swift.
File paths and clipboard contents are resolved locally, never invented by the
model or included in the cloud request.

## Supported sources

| Say | Local source |
| --- | --- |
| Flow, attach the image on my clipboard. | Image captured at recording start |
| Flow, attach the file on my clipboard. | One copied file URL |
| Flow, attach the PDF I just downloaded. | Newest observed matching PDF in Downloads |
| Flow, attach the latest download. | Newest observed completed/stable regular file |
| Flow, attach the presentation I just downloaded. | Matching presentation file |

Both an attachment-only command and a message followed by a command work. The
parser tolerates ASR punctuation such as “Flow. Attach…”. The Whisper vocabulary
hint includes Flow, clipboard, PDF and Downloads, which repaired cue omissions in
the generated-speech check. This is not a guarantee of ASR accuracy for all voices.

“Please attach the invoice when you reply” remains a message to the recipient.
Quoted/reported instructions and negated cues do not select a file. Unsupported
or ambiguous objects produce a clarification with no file action. General file
search, screenshot OCR and cloud attachments remain future work.

## Preview and Messages staging

Flow shows the recognized command, filename, source and a Quick Look thumbnail
where available. Clipboard images retain their own bytes before text insertion
can overwrite the clipboard. Refresh explicitly captures a new source.

Downloads are filtered by the requested type. Partial downloads, directories,
symlinks and unstable files are excluded. Arrival observed while Flow is running
takes precedence over modification time. Before Flow has observed downloads, the
UI asks the user to confirm a candidate because filesystem arrival metadata is
approximate. Stable-size/mtime checks are a heuristic, not browser completion
notifications. Selected files are revalidated immediately before use.

When there is one confident candidate and the captured Messages composer and
contact are still current, Flow requests an attachment paste. Otherwise the
preview offers Add to Messages or Copy attachment. Paste dispatch is labelled
“Paste requested” until Messages exposes an additional native attachment object
in its attributed text. Then the status becomes “Attachment added”. Flow never
presses Send. The previous clipboard is restored after a short paste interval only if
the user has not copied something else in the meantime.

The native composer is identified by `messageBodyField`, including macOS versions
where it is an `AXTextField`. An empty composer can report no AXValue; Flow checks
that its character count is zero before streaming into it. Search fields are
excluded. Contact checks use native Accessibility without System Events automation.

If a draft already contains attachment objects and Messages cannot expose a
writable selected-text range, new dictation uses the final-paste fallback to
preserve those objects. The verified demo sequence streams text first, then
appends attachments. Attachment-only commands leave existing text untouched.

Text learning keeps the existing user/contact scope. The attachment command is
excluded from the remembered message span, and U+FFFC attachment markers are
removed from text saved for style learning. A delivery request does not create a
permanent attachment preference. Configured static snippets now expand before
cloud formatting, including Auto audio streaming.

## Permissions and development demos

The app no longer scans Downloads at launch or during ordinary recording. It
first accesses that folder after an explicit recent-download command. Observation
stops if access fails. Speech replay checks existing authorization and does not
open permission dialogs; requesting speech access is an explicit Settings action.

For file access, macOS has Privacy & Security → Files & Folders and Full Disk
Access. Enable the app actually named in the dialog; permissions are per app.
Full Disk Access is not needed for the basic clipboard feature and does not
replace microphone, speech recognition or Accessibility permissions.
[Apple file access controls](https://support.apple.com/en-ca/guide/security/secddd1d86a6/web).

The attachment demo has its own bundle and process. Its synthetic PDFs, generated
audio and default report live in the temporary directory, outside protected
Desktop/Documents folders. Building prepares an app; it does not grant permissions.
During implementation, GUI relaunches were stopped when the user reported
repeated access prompts. After their restart, the prepared bundle was reopened
without rebuilding or re-signing it.

To launch the separate attachment simulation when wanted:

```sh
python3 scripts/simulate-voice.py --attachment
```

For subsequent launches, use `--reuse-bundle` to keep the already signed app
unchanged and preserve its permission identity:

```sh
python3 scripts/simulate-voice.py --attachment --reuse-bundle
```

It uses real ASR and LLM streaming, with a synthetic older PDF, a newly observed
PDF carrying an old modification time, and an unrelated newer ZIP. No real
Messages conversation is changed. Replay is available in the window.

## Verification

- Worker: 84 tests passed; TypeScript checking passed.
- Rust: 350 tests passed across unit/integration/doc suites; 2 platform tests ignored.
- Swift: 16 tests passed, including image paste into an isolated native rich-text
  composer, clipboard retention, type filtering, file changes and cold-start review.
- Real Rust → deployed Whisper → LLM pipeline: 5/5 generated-speech cases passed.
  Cases cover message + download, clipboard-only, recipient text, ambiguous
  missing context, and a configured email combined with an attachment command.
- A Rust integration test verifies that sending an edited message with an
  attachment saves the wording for Alex while excluding the attachment command.

[Live speech results](../review/attachment-stream-verification.json),
[email results](../review/shortcut-stream-verification.json).
The first failing audio run is retained in
[initial results](../review/attachment-stream-initial-verification.json).

After the restart, the prepared GUI demo was reopened without rebuilding or
re-signing. It passed, presented five real model chunks and selected the matching
synthetic PDF. Live captions were unavailable; the app did not request access.
[GUI replay results](../review/attachment-demo-verification.json).

## Actual Messages verification

The production Swift components were linked into a helper running with the
editor's existing Accessibility and microphone grants. This avoided rebuilding
or restarting the user's visible demo or requesting access again. The helper
required a named conversation and an empty composer before making any change.

The real Messages composer accepted five LLM chunks through five AX text writes.
A synthetic PDF was appended, then a second attachment-only voice request
appended a clipboard image. The composer exposed two native `AXAttachment`
objects and preserved the exact generated text. File objects are exposed through
`AXAttributedStringForRange`, rather than `AXChildren`; the original child-tree
check was insufficient and its report is retained for inspection.

Actual microphone capture started, delivered 44.1 kHz samples and stopped cleanly.
That microphone audio was never uploaded. Generated speech supplied the cloud
ASR/LLM test and 118 measured audio-level updates to the production recording HUD.
The waveform envelope varied with speech and returned to zero during silence.
This is a loudness display, not a pitch/frequency analyzer.

The live prompt-memory regression passed all five checks: a sent edit influenced
Alex's subsequent agentic output, another contact and another user did not inherit
it, and current explicit wording overrode the remembered preference. This used
isolated synthetic Send receipts; no Return/Send event was issued in Messages.

[Messages verification](../review/imessage-verification.json),
[initial child-tree observation](../review/imessage-initial-verification.json),
[learning regression](../review/contact-learning-verification.json).

Messages is left with an unsent verification draft containing the generated text,
synthetic PDF and image. Existing user drafts were not replaced. Live input
captions remain unavailable because Speech Recognition is not authorized for the
testing process. Global hotkey delivery and actual browser download completion
were not tested in this run. No real message was sent.

To inspect grants without writing, or test an empty Messages draft explicitly:

```sh
python3 scripts/verify-imessage.py
python3 scripts/verify-imessage.py --run
```

The second command leaves an unsent draft and requires an existing empty composer.
It does not open permission dialogs. A follow-up append test protects the exact
prior generated message and requires the original single PDF:

```sh
python3 scripts/verify-imessage.py --run --append-image --baseline review/imessage-verification.json
```
