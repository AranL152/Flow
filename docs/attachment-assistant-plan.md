# Voice composition with clipboard images and file references

Implementation update: clipboard/recent-download commands and native previews
are now integrated. See [supported commands and current verification](attachment-commands.md).
The proposal and initial research below are retained as the original design record.

## Decision and scope

Build toward a voice instruction that produces a reviewable message plus the
right attachment. Prioritize the current clipboard image/file and the newest
completed matching download. Broader file search comes next. Use the existing
LLM and retrieved user/contact edits; model training is not part of this plan.

This document is a proposal supported by limited feasibility tests. Retrieval,
attachment staging, and the intent planner are not integrated into the normal
Flow app. The running simulation and its in-memory edits were left open.

The user's requirement is to distinguish what the recipient should read from
words describing an object to find. The composer must contain only final LLM
chunks, with raw speech confined to You said. Existing user/contact memory must
continue to influence wording without becoming a global file-selection rule.

## What already exists

Wispr's email substitution is a saved static snippet, not evidence that it can
resolve arbitrary file references. Its documentation supports triggers within
sentences and recommends distinctive phrases, such as “my email signature.”
[Official snippets documentation](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets).

Wispr also documents context awareness, command mode and MCP access to notes.
“We added MCP” would not establish a product advantage. The feature to evaluate
is whether Flow can turn a spoken reference into the correct reviewable local
attachment while keeping the message clean.
[Wispr context](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness),
[command mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode),
[MCP notes](https://docs.wisprflow.ai/articles/5166327995-switching-to-wispr-flow-keep-all-your-notetakers-in-one-place-mcp).
Screenpipe's MCP search is another existing approach to retrieving screen context;
it is relevant to remembered descriptions, but does not by itself establish
correct file selection or attachment delivery.
[Screenpipe MCP](https://docs.screenpipe.com/mcp-server).

This repo has a Rust phrase-expansion engine. A new live check configured
`my email → aran@example.test` in an isolated user and tried the same sentence in
two paths. Typed formatting returned the configured address; generated audio
through Auto streaming returned “You can reach me at my email.”
[Actual outputs](../review/shortcut-stream-verification.json).

The code explains the discrepancy: `transcribe_with_audio` sends empty shortcut
metadata to the combined worker, processes shortcuts after the response, then
prefers the worker's already-completed text. This must be fixed and tested before
building dynamic references on top of shortcuts. This plan does not patch that
production path yet.

macOS pasteboards support images and file URLs, which gives us direct native
sources without MCP. Their change counter can identify whether a captured value
is still current. [Apple pasteboards](https://developer.apple.com/documentation/appkit/nspasteboard),
[changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount).

## Tests performed

| Test | Result | What it establishes |
| --- | --- | --- |
| Native private-pasteboard/temp-file fixtures | 7/7 checks passed | Image and file-URL reads; retained image survives a text paste; partial downloads/wrong types excluded in fixtures |
| Existing LLM, synthetic intent development cases | 17/20 met all assertions | Common explicit requests can be separated; prompt-only action classification has concrete failures |
| Explicit-cue guard replay on the same outputs | 20/20 case assertions after 3 interventions | A proposed hard boundary blocks the observed unsafe interpretations; this is not held-out accuracy |
| Configured email shortcut, typed vs Auto audio | Typed passed; audio failed | A real existing end-to-end shortcut integration gap |

The twenty intent cases contain four deterministic normal-dictation passthroughs
and sixteen live assist requests. Fifteen assist requests returned valid plans.
The two unsafe interpretations were:

- “Tell Alex please attach the invoice when you reply” incorrectly requested a
  clipboard artifact. The imperative belongs in the message to Alex.
- “Please attach the invoice” incorrectly requested a file search without
  recognizing uncertainty about whom the instruction addressed.

“Flow, attach the one I meant earlier” failed to return a valid plan and remained
blocked. No plan was executed. The first-run results are retained, not replaced
with a tuned all-green model result.

Among the fifteen valid live-model responses, measured model-call duration had a
median of 896 ms and a maximum of 3023 ms. Calls used up to three concurrent
requests and may include startup effects. These are feasibility timings, not
production latency benchmarks. An extra general LLM call before every dictation
would be a poor starting design.

[Intent outputs](../review/attachment-intent-verification.json),
[guard replay](../review/attachment-guard-replay.json),
[native fixtures](../review/attachment-sources-verification.json).
These did not test ASR accuracy for mixed commands, actual Downloads access,
Spotlight indexing, broad file ranking, or insertion into a real Messages draft.

## Interaction and language boundary

Keep normal dictation as text-only. For the initial release, expose a clearly
labelled compose-assist mode/shortcut. In that mode reserve an explicit cue:

> Here's the updated deck. Flow, attach the PDF I just downloaded.

The message span is “Here's the updated deck.” The command span resolves the
newest completed PDF in Downloads. Only the message span reaches the personalized
streaming formatter. Never stream planner JSON or search descriptions into the
composer and then replace them with a finished rewrite.

Fast paths can identify the explicit cue and clipboard/latest-download request
without another LLM call. General object descriptions use a structured planner
only after assist is invoked. File search can run beside final text generation.

| Spoken input | Intended result |
| --- | --- |
| “Here's the chart. Flow, attach the image on my clipboard.” | Personalized message + captured clipboard image |
| “Here's the invoice. Flow, attach the last PDF I downloaded.” | Message + newest completed PDF, even if a newer ZIP exists |
| “Here's the chart. Flow, find the retention screenshot showing 42 percent from yesterday.” | Message + search request; identifying terms belong to search |
| “Please attach the invoice when you reply.” in normal dictation | Literal message; no filesystem action |
| “Please attach the invoice.” with unclear intent in assist mode | Ask whether this is message text or an attachment request |
| A distinctive configured email trigger | Exact configured address; never an invented one |

Quoted cues, reported speech, negation, corrections mid-utterance and commands
with missing context must be included in held-out tests. The explicit cue is a
first-release language contract, not a claim that all natural speech is solved.

## Source resolution

1. **Clipboard image or copied file.** Capture a stable snapshot before Flow's
   clipboard-based text fallback can overwrite it. Retain image bytes or verified
   file references, not a later call to the general clipboard. Use changeCount to
   detect a replacement; expose Refresh instead of silently switching objects.
   Label it “Image from clipboard,” because image bytes do not prove screenshot
   provenance. Empty or incompatible clipboard content produces a clear choice,
   not a fallback to an unrelated file.
2. **Recent download.** Enumerate an authorized Downloads folder, use observed
   completion/directory-arrival evidence, filter by the spoken file kind, and skip
   partial downloads, directories and unsuitable links. Do not sort solely by
   modification time. Apple's added-to-directory date may help on cold start,
   but it also changes on rename and is not supported on every volume; it is not
   authoritative browser download history. Show the filename/type/source for
   review. [Apple directory-arrival metadata](https://developer.apple.com/documentation/foundation/urlresourcekey/addedtodirectorydatekey).
3. **Search approved files.** Use filename, type, project and time constraints
   first; add cached OCR for screenshot text. Voice supplies useful search terms
   even when the user cannot remember the filename. Spotlight supports location
   and kind narrowing; its index may omit or lag files, so test the real folders.
   Apple's Vision supports on-device OCR. Return a few grounded candidates when
   there is no clear match, rather than selecting based on an LLM confidence score.
   [Spotlight filters](https://support.apple.com/en-au/guide/mac-help/mchl4d69efd3/mac),
   [Apple OCR](https://developer.apple.com/documentation/vision/recognizing-text-in-images).

An in-memory candidate registry maps opaque IDs to verified local files or owned
clipboard snapshots. The LLM can describe a search or select an offered ID; it
cannot invent a path to open. Recheck existence/readability and recipient/focus
before staging. If a download is still incomplete, surface that state.

## Message, memory and attachment contracts

The internal plan should separate these fields:

```json
{
  "message": "Here's the updated deck.",
  "requests": [{"source":"recent_download","kind":"pdf","query":""}],
  "needs_clarification": false
}
```

The source resolver produces attachment candidates; the existing writer streams
personalized message text. Saved user/contact examples apply to wording. They do
not authorize a search or make yesterday's attachment the right one today.
Keep an explicit preference such as “Alex prefers PDF exports” separate from a
single example. “Use a link this time” overrides that delivery default.

Stage attachments with a thumbnail, filename and source label. The user sends.
If text is ready before an attachment, show “Finding attachment” without claiming
it is attached. Missing files, unsupported target apps and ambiguous matches must
remain visible rather than silently degrading into an incorrect attachment.
Apple documents image paste in Messages; the existing text AX writer does not
prove attachment automation works. Verify that integration separately, including
clipboard restoration and focus changes. [Messages image insertion](https://support.apple.com/en-gb/guide/messages/ichtb967d30b/mac).

## Implementation order and gates

1. **Repair static snippet propagation.** Run configured email/link values through
   the actual Auto audio pipeline. Expand deterministically after ASR and before
   formatting; carry exact replacement protection into the model request. Verify
   the address survives all deltas and final output. Keep this distinct from
   contact-specific style examples.
2. **Clipboard MVP.** Add the explicit intent boundary, snapshot ownership,
   attachment preview, source label and cancellation. Reuse existing streaming
   text and contact guards. Test image, file URL, empty clipboard and changes
   during dictation before real Messages staging.
3. **Recent-download provider.** Add type-aware arrival ordering, partial-file
   exclusion, stable-file checks and a preview choice for uncertainty. Test with
   actual browser downloads and copied files, not only synthetic timestamps.
4. **Descriptive search.** Add selected-folder indexing, Spotlight and cached
   screenshot OCR. Validate candidate recall and ranking on cluttered folders.
5. **MCP/cloud sources when needed.** Reuse the resolver interface for Google
   Drive search/export or other services. MCP supplies tool discovery and calls;
   it does not resolve intent or choose the correct object by itself. Native
   clipboard/Downloads access does not require an MCP server.
   [MCP architecture](https://modelcontextprotocol.io/docs/learn/architecture).

   A concrete later cloud case is: “Here's the deck. Flow, attach the Q4 planning
   presentation from Drive as a PDF.” Search returns actual accessible Drive
   items, ambiguous versions require a choice, and a supported export produces
   the previewed PDF. Google's export formats support this conversion; permissions,
   export limits and integration still need implementation and verification.
   [Drive export formats](https://developers.google.com/workspace/drive/api/guides/ref-export-formats?hl=en).

Use focused commits for each provider, UI integration and verification. Keep the
current working simulation open until a deliberate new launch, because its
existing memory is process-local.

Release evaluation needs a separate held-out set: literal imperatives, quotes,
negation, ASR errors, unavailable/stale clipboard, wrong file types, ambiguous
versions, source changes, contact switches and target apps without attachment
support. Report wrong staged files, correct first-choice rate, clarification
rate and time from speech end to a correct reviewable draft. Compare with normal
paste and manual file selection. Do not report synthetic-case pass rates as user
accuracy.

## Demo and value test

A 10–15 second target storyboard:

- Show Alex's chat and a Downloads window containing two PDFs and a newer ZIP.
- Speak: “Here's the deck. Flow, attach the PDF I just downloaded.”
- Show the instruction identified separately, actual LLM text chunks, then the
  correct PDF preview labelled “Newest completed PDF in Downloads.”
- Leave the complete message ready for user review.

Measure the real implementation before promising that duration. For clipboard
images the benefit is combining a hands-free message and attachment, not file
search; ordinary paste is already fast. Recent-download filtering and descriptive
search have a stronger chance of removing meaningful work. Build the two direct
sources first, then expand only if the observed workflow beats the manual path.
