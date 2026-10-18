# Update and launch the native Mac app

This is optional for everyday hotkey use, not a prerequisite for the website
video. The user clarified on October 18: “isnt this just for the demo?” Keep
demo work on `python3 scripts/simulate-imessage-full.py --kind screenshot`, which
builds its own native production-component runner and uses generated speech.
Do not require a normal app install or its permission setup to record that demo.

From this checkout:

```sh
python3 scripts/install-native.py
```

This builds Rust, Swift and the hotkey helper, packages the normal app with its
resources, verifies its signature, then replaces and opens the existing
`.build/Flow Attachments.app`. No simulation flag is passed. The previous bundle
is kept under `.build/native-app-backups/<timestamp>/`. The bundle identifier
remains com.flow.flow, so the app uses the same settings and existing flow.db.
The installer does not reset privacy permissions or request microphone capture.

To reopen the installed build without compiling or signing again:

```sh
open "/Users/lumaran/Desktop/Flow/.build/Flow Attachments.app"
```

This Mac currently has no code-signing certificate. The existing app uses an
ad-hoc signature with a cdhash designated requirement. A changed binary has a
different identity, so macOS may require Accessibility or microphone access to
be enabled again. This cannot be promised away by preserving the app's name.
See [Apple's signing requirements note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
For future updates, a consistent development signing identity is the proper
way to retain compatible requirements. No signing certificate is created by
this installer. It retains the helper's exact old signature only if stripping
signatures from scratch copies proves the helper executable is unchanged.

If access is unavailable, enable this Flow app under System Settings → Privacy
& Security → Accessibility. Microphone permission is requested by recording.
The explicit Enable action requests access and opens that pane independently
of the optional fallback hotkey handler; it previously did nothing when that
handler was absent. Startup continues to check access without prompting.
Apple Speech Recognition is optional for the new cloud captions; it is used by
the existing on-device caption fallback. Nothing sends an iMessage automatically.

Use cloud Auto, remote transcription and Stream formatted output for the new
real-time path. Hold the configured hotkey, speak, and release to rewrite. Live
words appear in the HUD; only LLM chunks enter the target draft. The new cloud
client can provide captions even without Apple's Speech permission.

The latest synthetic checks measured about 0.44–0.47 seconds from Stop to first
LLM delta on two successful real-time streams. One of three used fallback and
took about four seconds. These measurements exclude deliberate smooth reveal
pacing and are not a guarantee of consistently sub-second latency.

The normal bundle was nevertheless updated and launched during installation
investigation, at code commit 28e2d38. Signature verification and packaged-resource
resolution passed, and a live process/window was observed. Its UI reported that
Accessibility still needed enabling. No microphone or Messages write was tested;
see [the scoped install report](../review/native-install-verification.json).
