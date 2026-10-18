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
“Paste requested”; there is no claim of a Messages receipt. Flow never presses
Send. The previous clipboard is restored after a short paste interval only if
the user has not copied something else in the meantime.

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
During this implementation, GUI relaunches were stopped when the user reported
repeated access prompts. The final GUI replay was not rerun after that instruction.

To launch the separate attachment simulation when wanted:

```sh
python3 scripts/simulate-voice.py --attachment
```

It uses real ASR and LLM streaming, with a synthetic older PDF, a newly observed
PDF carrying an old modification time, and an unrelated newer ZIP. No real
Messages conversation is changed. Replay is available in the window.

## Verification

- Worker: 84 tests passed; TypeScript checking passed.
- Rust: 350 tests passed across unit/integration/doc suites; 2 platform tests ignored.
- Swift: 15 tests passed, including image paste into an isolated native rich-text
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

Real Messages attachment acceptance, actual browser download completion and the
final GUI replay remain unverified. Unit tests and a dispatched paste event are
not evidence that Messages accepted an attachment. No real message was sent.
