# Liquid command captions

Explicit “Flow, attach/find/search…” instructions appear on a separate purple,
semibold line in the existing live-caption card. Recipient text remains white.
A plain purple label shows attachment progress without a capsule or pill. There
is no generic “Flow command” label; the pending state says Transcribing… and a
successful search retains Attachment found. The approved animation is unchanged.
Ordinary mentions, quoted/reported instructions, negated cues and bare incomplete
forms such as “Flow, attach” remain normal caption text. Saying “Flow” alone is
not a command. The reserved pattern is an explicit Flow cue plus a supported attachment verb
and an object; see [the supported wording](attachment-commands.md). This is a pattern-based cue, not unrestricted intent understanding.
Detection runs on the complete transcript before display cropping.
This classifier only styles captions; the worker's authoritative command parser,
message insertion and attachment safeguards are unchanged.

During recording all spoken words remain white. The Listening label and its
animated purple dots appear only in the sound-capture pill, not the speech box.
The dots pulse left to right while audio is captured and remain static with
Reduce Motion. There is no
command highlight until the transcript is finalized and completely visible.
Late final words use the adaptive character reveal, with caption catch-up
bounded to four 33 ms frames. The complete white
command holds for 220 ms before turning purple in the same layout. Fast model
responses cannot hide the HUD before this recognition animation finishes.
A single 700 ms highlight and one smooth crest sweep from left to right,
with up to 2 points of letter displacement. A Gaussian crest follows the highlight
without oscillation or trailing ripples, with a gentle fade at either end.
Once the crest has settled, all command letters flash a brighter luminous purple
with a strong outer halo once over 400 ms, then fade back to their normal purple.
A single pulse envelope drives the glyph fill and both halo layers, so their
brightness rises, peaks and fades together. The halos appear only during this
finish; there is no lingering shadow.
The recipient message stays white. The letters stay still during this finish.
The full timing is shared by rendering and animation cleanup.
There is no replay on each partial recognition update. The glyph alpha image is
cached per text/width/scale and drawn through narrow Canvas strips, so only the
command letters distort. Recipient text is outside that layer. Canvas's animation
timeline pauses after the pass. The final words stay purple. Long commands wrap
to two lines and preserve the beginning/end when truncated.

The plain purple label follows actual attachment state: Attachment found after
matches arrive, Finding screenshot/image/file… while
searching, Adding attachment… during insertion, Added to draft after confirmation,
and Needs detail for a clarification. The attachment picker repeats the Command
badge. The full Messages runner passes its own attachment session into the HUD,
so it observes the same real search as the popup.

Reduce Motion disables the ripple, sweeping highlight, finishing flash and
listening-dot motion while retaining static purple text, weight and status. A preview may request reduced motion but can
never override the system preference to enable motion. No model calls, new
packages or separately compiled shader resources are involved. The implementation
uses native [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)
and [Canvas/GraphicsContext](https://developer.apple.com/documentation/swiftui/graphicscontext)
on the app's existing macOS 14 baseline.

## Native preview

```sh
python3 scripts/preview-command-ripple.py
```

This builds production components and opens a labelled synthetic-caption preview
with Replay and Reduce Motion controls. It also runs real local screenshot OCR
in its dedicated synthetic folder, then displays the production attachment picker.
Alternate visual fixtures run in a separate hidden host, so Replay never cycles
the visible bar through test scenes. Native show/hide regressions run below the
desktop, verifying that repeated show requests retain opacity and position and
that the latest visibility request wins. The caption reserves consistent space
and the lower pill keeps its height between phases; repeated production show
requests no longer restart its fade-in.
It never records microphone audio, invokes ASR/LLM APIs, or changes Messages. The
existing signed app bundle and permissions are preserved; this is a separate
review helper using the updated app components.

The preview exports [a GIF](../review/command-ripple.gif), stills for listening,
complete white speech before recognition, mid-ripple, synchronized finishing glow, settled, ordinary mentions, reduced motion
and long commands, and
[a scoped report](../review/command-ripple-verification.json). Its frame interval
is a capture target, not a measured production frame-rate guarantee.

48 Swift tests passed, including late final-caption reveal, Unicode revisions,
command context guards and popup lifetime. Fourteen native preview checks passed.
The complete-white, active and finishing stills were visually reviewed: the full
sentence appears white before the command changes color, in the same position.
The recipient text remains white and the finishing inner/outer glow stays synced.
These preview checks use synthetic captions and local OCR, without microphone,
cloud requests or Messages writes.

## Full Messages demo

```sh
python3 scripts/simulate-imessage-full.py --kind screenshot
```

This runner builds the current production components before linking and uses the
same recording indicator, command effect and attachment session as the native
preview. It closes its prior preview helper to keep the recording view clear.
Generated speech feeds the real on-device recognizer and waveform, then the
configured cloud pipeline streams only rewritten text into the existing Messages
draft and appends a synthetic screenshot. It never sends. Unlike the isolated
visual preview, this path makes real ASR/LLM requests. Existing text and files
remain intact, and the installed permissioned app bundle is not replaced.

The latest October 18 run passed 14 checks, including complete white captions
before recognition and finishing command presentation before hiding the HUD.
Six genuine model chunks became seven complete-word display frames and seven
native writes over 1.13 seconds. The screenshot was appended with an alternative
available, preserving the original draft and attachments. This take used the
recorded-audio ASR fallback: 17.82 seconds total, with the first rewritten word
8.87 seconds after Stop. Word pacing does not guarantee cloud inference latency.
Nothing was sent. See [the actual picker](../review/imessage-other-matches.png)
and [the run report](../review/imessage-full-demo-verification.json).
