# Find screenshots by visible text

Say **“Here's the issue. Flow, find the screenshot showing payment error.”**
The message stays separate from the file instruction. The native search uses
“payment” and “error” to find screenshots containing both words, even when the
filename is just `Screenshot … .png`. It auto-appends the top result to the captured
Messages draft, then offers alternatives in the compact picker. **Text: payment ·
error** explains the match. The eye button opens a larger preview; **Use this file**
replaces only the attachment Flow owns. You send the message.

Image requests combine filename search and screenshot OCR. An exact filename
match ranks first; full OCR word matches follow, then other filename matches.
Equal OCR matches retain Spotlight's recency order. Every meaningful query word
must occur in the recognized text. Search phrasing such as “showing” and “with” is
removed locally. This is literal text retrieval, not general scene recognition or
semantic similarity. Existing clipboard and recent-download requests bypass OCR.

## Scope and cache

OCR runs only for an explicit image search, on up to 24 screenshots modified in
the last 30 days. Spotlight identifies screenshots through screen-capture metadata
or common `Screenshot…` / `Screen Shot…` names. Renamed images without that metadata
can still match a filename, but are outside the OCR scan. Non-image, hidden,
linked, incomplete, unreadable and oversized files are excluded. Cloud-only
images are skipped to avoid downloading them for a search.

Apple Vision runs off the UI thread with accurate recognition and language
detection. Image decoding uses a thumbnail bounded to 3072 pixels per dimension.
Files are limited to 24 MB and extracted text to 16,000 characters per image.
OCR failures skip the affected image; a valid filename result remains usable.

The disposable cache is `~/Library/Caches/Flow/ScreenshotOCR/text-v1.json`, bounded
to 128 entries with 30-day expiry. Entries use hashed paths, file identity, size
and modification time. Changed images are recognized again; deleted or modified
files cannot become stale candidates. The directory is private to the user and
the JSON file has mode 0600. Only matching query words reach the picker. Image
pixels, complete recognized text and local paths are never added to an LLM prompt
or sent to a cloud model. OCR has no API charges or additional API key.

## Verification

- `swift test`: 29 tests passed, including real Vision OCR, partial-match exclusion,
  disk-cache reuse across index recreation, mutation/deletion invalidation,
  cancellation and unsuitable-file exclusions.
- `python3 scripts/verify-screenshot-ocr.py`: 11 native checks passed using real
  Spotlight and generic screenshot filenames. Three images took about 0.41 seconds
  including discovery; the cached search took about 0.05 seconds on this Mac.
  [Report](../review/screenshot-ocr-verification.json) and
  [picker image](../review/screenshot-ocr-preview.png).
- `python3 scripts/verify-imessage-ocr.py`: eight actual Messages checks passed:
  auto-append, alternatives, switching and restoring the chosen file, and
  preservation of existing text and unrelated native objects. The check supplies
  a local parsed intent and performs no ASR/LLM calls; it is not a new end-to-end
  voice test. It leaves the production picker open and one synthetic screenshot
  in the unsent draft. [Report](../review/imessage-ocr-verification.json).
- Worker parsing: 97 tests and typecheck passed. New cases verify that image-search
  phrases preserve the spoken content terms in the existing protocol. No worker
  deployment or protocol change is required for this native feature.

The normal app bundle's signature and grants are preserved; the open verification
helper links the updated production modules. Rebuilding the installed app bundle
is still needed for its normal hotkey workflow to use the new implementation.

## Model and billing clarification

The Auto worker's configured rewriting default is
`@cf/meta/llama-3.3-70b-instruct-fp8-fast`; ASR uses
`@cf/openai/whisper-large-v3-turbo`, both through Cloudflare Workers AI. A server
`CHAT_MODEL` override can change the former. That route does not use the client's
OpenAI API key; direct OpenAI mode is a separate setting. No account billing total
was retrieved or verified. The startup log now prints the actual selected provider
name instead of incorrectly labelling every cloud initialization OpenAI Whisper.
