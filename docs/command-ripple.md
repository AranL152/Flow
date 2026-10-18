# Liquid command captions

Explicit “Flow, attach/find/search…” instructions appear on a separate purple,
semibold line in the existing live-caption card. Recipient text remains white.
A plain purple status label identifies the command without a capsule or pill.
Ordinary mentions, quoted/reported instructions, negated cues and bare incomplete
forms such as “Flow, attach” remain normal caption text. Saying “Flow” alone is
not a command. The reserved pattern is “Flow, attach/find/search…” followed by an
object. This is a pattern-based cue, not unrestricted intent understanding.
Detection runs on the complete transcript before display cropping.
This classifier only styles captions; the worker's authoritative command parser,
message insertion and attachment safeguards are unchanged.

During recording all spoken words remain white. Only the Listening label and
its three dots are purple; the dots pulse in a small left-to-right wave while
audio is being captured, and remain static with Reduce Motion. There is no
command highlight until recording stops.
After recording stops, an explicit command with an object turns purple and a
single 700 ms highlight and one smooth crest sweep from left to right,
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

The plain purple label follows actual attachment state: Finding screenshot/image/file… while
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
mid-ripple, synchronized finishing glow, settled, ordinary mentions, reduced motion
and long commands, and
[a scoped report](../review/command-ripple-verification.json). Its frame interval
is a capture target, not a measured production frame-rate guarantee.

35 Swift tests passed, including recording-phase gating, incomplete commands,
quotation, negation, Unicode and full-context guards. Thirteen native preview
checks passed after the stable-bar/listening-dot adjustment. The exported stills
were visually reviewed: command motion/glow, unchanged recipient text, no
microphone waveform during processing, readable long commands and static reduced
motion. A pixel comparison between active/settled fixtures also found no changes
in the recipient-message region while command-region pixels changed. This was
not a new voice-to-Messages or microphone integration run.

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

The latest October 18 run passed 12 checks: 16 live-caption updates detected the
real Flow cue, six model chunks became 44 small display frames and 22 native
writes over about 1.82 seconds, and the screenshot was confirmed with an
alternative candidate. The reveal is paced more slowly for readability.
See review/imessage-full-demo-verification.json. The processing label is now
centered with balanced spinner space and a visible spinner on the dark pill.
