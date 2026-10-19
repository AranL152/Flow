# Local PDF and slide content search

Say the message, then the explicit attachment command:

> Hey Alex, here's the report. Flow, find the PDF containing quarterly revenue.

> Here's the deck. Flow, find the presentation mentioning quarterly revenue.

The outgoing message excludes the command. Flow searches both filenames and
document text, stages the best match in the captured Messages draft, and offers
the other matches in the existing compact picker. Each content result explains
the requested words, for example **Matches: "quarterly revenue" · Page 2** or
**Matches: "quarterly revenue" · Slide 3**. Matches spanning multiple pages omit
the page number. Choosing an alternative uses the existing guarded replacement
of only Flow's attachment. Flow never presses Send.

## Readers and discovery

- PDF: PDFKit extracts selectable text. Image-only pages are rendered locally
  and recognized with Apple Vision. Password-locked PDFs are skipped.
- PowerPoint `.pptx`: the bundled macOS ZIP reader opens bounded archive entries
  in memory. XMLParser reads DrawingML text; slide relationships establish the
  displayed slide order. Referenced raster slide images also get local OCR.
  Unreferenced media, speaker notes, masters and external relationships are not
  indexed. No Office app or script automation is launched.
- Keynote `.key` and legacy PowerPoint `.ppt`: Spotlight's installed importer
  supplies content matches. These formats require Spotlight content indexing;
  they have no independent direct reader. Keynote packages stored as directories
  retain the existing regular-file restriction.
- Spotlight content queries find older indexed documents regardless of age.
  Up to 32 recent, downloaded PDFs/PPTX files provide a direct-reading fallback
  when their text isn't indexed. Discovery uses the existing home-directory
  scope; it doesn't recursively walk folders, download cloud placeholders,
  search Google Slides or fetch remote attachments.

Apple documents that `kMDItemTextContent` is searchable but not directly readable,
so Flow queries it for the requested words and uses the independent readers for
page/slide evidence. [Apple's metadata documentation](https://developer.apple.com/documentation/coreservices/kmditemtextcontent).
PDFKit provides page text and rendering; PowerPoint text is stored in the slide's
DrawingML elements. [PDFPage](https://developer.apple.com/documentation/pdfkit/pdfpage),
[Microsoft slide text documentation](https://learn.microsoft.com/en-us/office/open-xml/presentation/how-to-get-all-the-text-in-a-slide-in-a-presentation).

## Bounds, privacy and limitations

Content is read only for an explicit attachment search. Document bytes and
extracted text stay on the Mac and never enter the cloud formatter's prompt.
Only the user's spoken query already travels through the speech/command pipeline.
No new API or GPU cost is introduced by document searching.

Direct extraction accepts downloaded, readable regular PDF/PPTX files up to
64 MiB, 200 pages/slides and 128,000 characters. OCR covers up to 12 image-only
PDF pages or 12 referenced raster images per deck. Charts stored in separate
chart parts, vector-only slide images and OCR beyond those bounds aren't
independently recognized. This matches words, including case/diacritic folding;
it isn't semantic retrieval or a scene-understanding model.

The extraction pass has an eight-second cooperative budget (two seconds when
Spotlight already found content matches); each ZIP read also has a two-second
deadline and an output cap. PDFKit/Vision calls can finish after the cooperative
budget expires. Cancellation stops the query and prevents a late result from
being attached. Filename/Spotlight matches remain usable if extraction fails.

The private cache is `~/Library/Caches/Flow/DocumentText/text-v1.json`, with a
0700 directory and 0600 file. It retains at most 64 entries for 30 days and
invalidates entries when file size, modification time or identity changes.
Files are rechecked before and after extraction and again before pasting.
Hidden, linked, incomplete, missing and undownloaded files are excluded from the
direct reader. Full document text is not placed in match explanations or logs.

## Verification

`swift test` covers selectable text on a second PDF page, real Vision OCR of
scanned PDFs and embedded slide images, presentation-order mapping, persistent
cache reuse, edits/deletion/symlinks, malformed XML/entity rejection and cancellation.

`python3 scripts/verify-document-content.py` creates disposable generic-named
documents in an isolated home folder and verifies actual Spotlight discovery and
content queries, both independent readers, type filtering, the production
AttachmentSession and native picker rendering. It makes no API calls or Messages
writes and removes its fixtures. Its screenshot/logs stay private under
`.build/document-content-review/`.
See [recorded synthetic verification](../review/document-content-verification.json).
