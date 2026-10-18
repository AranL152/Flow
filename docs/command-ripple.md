# Liquid command captions

Explicit “Flow, attach/find/search…” instructions appear on a separate purple,
semibold line in the existing live-caption card. Recipient text remains white.
A Flow command badge makes the distinction visible without relying on color.
Ordinary mentions, quoted/reported instructions and negated cues remain normal
caption text. Detection runs on the complete transcript before display cropping.
This classifier only styles captions; the worker's authoritative command parser,
message insertion and attachment safeguards are unchanged.

During recording the command has a static purple fill. When recording ends, a
single 700 ms highlight and one smooth crest sweep from left to right,
with up to 2 points of letter displacement. A Gaussian crest follows the highlight
without oscillation or trailing ripples, with a gentle fade at either end.
Once the crest has settled, all command letters flash a bright luminous purple
once over 400 ms, then fade back to their normal purple. This is a change in the
glyph fill, using the cached glyph alpha mask, with no outer shadow or halo.
The recipient message stays white. The letters stay still during this finish.
The full timing is shared by rendering and animation cleanup.
There is no replay on each partial recognition update. The glyph alpha image is
cached per text/width/scale and drawn through narrow Canvas strips, so only the
command letters distort. Recipient text is outside that layer. Canvas's animation
timeline pauses after the pass. The final words stay purple. Long commands wrap
to two lines and preserve the beginning/end when truncated.

The badge follows actual attachment state: Finding screenshot/image/file… while
searching, Adding attachment… during insertion, Added to draft after confirmation,
and Needs detail for a clarification. The attachment picker repeats the Command
badge. The full Messages runner passes its own attachment session into the HUD,
so it observes the same real search as the popup.

Reduce Motion disables the ripple, sweeping highlight and finishing flash while retaining static
purple text, weight and the badge. A preview may request reduced motion but can
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
It never records microphone audio, invokes ASR/LLM APIs, or changes Messages. The
existing signed app bundle and permissions are preserved; this is a separate
review helper using the updated app components.

The preview exports [a GIF](../review/command-ripple.gif), stills for listening,
mid-ripple, finishing text flash, settled, ordinary mentions, reduced motion
and long commands, and
[a scoped report](../review/command-ripple-verification.json). Its frame interval
is a capture target, not a measured production frame-rate guarantee.

33 Swift tests passed, including new cue-boundary, quotation, negation, Unicode
and full-context guards. Eight native preview checks passed after the glyph-flash adjustment. The exported stills
were visually reviewed: command motion/glow, unchanged recipient text, no
microphone waveform during processing, readable long commands and static reduced
motion. A pixel comparison between active/settled fixtures also found no changes
in the recipient-message region while command-region pixels changed. This was
not a new voice-to-Messages or microphone integration run.
