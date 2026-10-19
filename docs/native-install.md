# Update and launch the native Mac app

For everyday use, open the **Flow Attachments** alias on the Desktop, or run:

```sh
python3 scripts/launch-native.py
```

This opens the existing bundle in place. It never compiles, replaces or signs
the app, so reopening it does not change its permission identity. Do not run
the installer just to open Flow. The Desktop alias targets this checkout's
`.build/Flow Attachments.app`; keep that bundle in place.

This is optional for everyday hotkey use, not a prerequisite for the website
video. The user clarified on October 18: “isnt this just for the demo?” Keep
demo work on `python3 scripts/simulate-imessage-full.py --kind screenshot`, which
builds its own native production-component runner and uses generated speech.
Do not require a normal app install or its permission setup to record that demo.

Only when intentionally installing code changes, from this checkout:

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

## Persistent signing and permissions

Flow now uses one local certificate-backed signing identity. macOS recognizes
updates by their designated requirement, not the filename; the old ad-hoc builds
used a different code hash after every edit. Repeated manual TCC resets added to
the prompts. Normal development must never use that workflow again.
[Apple explains permission identity across updates](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

One-time setup on a new Mac:

```sh
python3 scripts/setup-native-signing.py --trust-local-certificate
python3 scripts/install-native.py --migrate-signing
```

The setup reuses an existing identity and verifies two different compiled programs
against each other's requirements. It also verifies that an unrelated signer
cannot impersonate them. Trust is limited to code signing in the current user's
domain; it does not install a system TLS root or grant Full Disk Access. This is
local development signing, not Developer ID distribution/notarization. No paid
Apple account is needed.

The non-exportable private key is in a dedicated keychain under
`~/Library/Application Support/Flow/Signing/`. Its generated password and identity
configuration are protected by user-only filesystem permissions outside Git.
Preserve that directory across checkouts and backups. Signing temporarily makes
the keychain available and restores the normal keychain search list afterward.

The app and Fn helper both have a requirement pinned to that certificate and their
own identifiers. The installer refuses an incompatible update before replacing
the existing app and never silently falls back to ad-hoc signing. The initial
migration from the old signer may require one last macOS permission approval;
subsequent builds retain the same certificate-backed requirement.

For normal updates, run `python3 scripts/install-native.py`; never recreate the
certificate, reset TCC, remove/re-add the app, or re-sign it manually as routine
update steps. Launches continue using `scripts/launch-native.py` without signing.

An explicit diagnostic mode checks the actual app identity without recording
sound, model calls, hotkeys or Messages changes:

```sh
open -n ".build/Flow Attachments.app" --args --privacy-audit \
  --privacy-report /tmp/flow-privacy.json
```

`--request-microphone` requests access only if undetermined. The optional
`--privacy-read-file /path/to/file` verifies a real file read (one byte, no content
logged). Use it only for an explicitly authorized test file. Diagnostic mode
uses in-memory state and exits when the report is saved.
`--privacy-read-desktop` additionally verifies Desktop directory access without
logging filenames. This checks folder access separately from an explicitly
provided file, which can carry its own access grant.

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

## Accessibility grant and helper recovery (October 18)

Restarting the 9c50c96 bundle after a reported grant still returned Accessibility
permission not granted for both app and helper. The helper manager also had an
EOF bug: its readable-empty pipe callback repeatedly scheduled cleanup/restarts,
while the termination callback scheduled the same work again. The app reached
100% CPU while logging the denied state. The affected process was stopped.

EOF now immediately disables its handler. Only the matching process's termination
callback owns recovery; stale exits cannot clear a replacement helper. Stopping
cancels pending retries, and permission denial never automatically retries or
prompts. Output/state updates are serialized on the main queue. The app checks
access again on application switches, allowing a recognized grant to start the
helper when returning from Settings to Messages.

`python3 scripts/verify-helper-lifecycle.py` passed five production lifecycle
checks with synthetic child processes: denied parent, denied child, cancelled
restart, rapid stop/start and one bounded restart budget for EOF plus exit.
All 48 Swift tests also passed. These are not physical Fn/microphone tests and
do not establish that macOS accepted the user's grant.

When the current running build still reports denied after restart, an enabled
old Flow entry is insufficient evidence. Remove the stale entry and add this
exact bundle through the Accessibility pane's + file picker (Cmd-Shift-G):
`/Users/lumaran/Desktop/Flow/.build/Flow Attachments.app`. The app does not reset
TCC, edit its database or automatically toggle privacy settings. This describes historical ad-hoc builds. Current native updates use the persistent
signer above and must not repeat permission-entry repair during normal updates.

If the main app is authorized but the helper is denied or unavailable, Flow now
uses its existing in-process hotkey handler as a fallback, requiring no extra
helper grant. Helper-ready disables that fallback to avoid duplicate triggers.
Both paths share the configured hotkey and recording activation mode. This path
was compiled but still requires a physical-key test after macOS grants access.

## Historical Desktop grant repair before persistent signing

The real Moby-Dick screenshot test found that an enabled Desktop switch still
referred to an older build's signing requirement, while microphone and
Accessibility already matched the current app. Toggling Desktop off/on retained
that stale requirement. A one-off reset of only Flow's Desktop grant, followed
by the standard OS consent request and reopening the unchanged bundle, restored
native screenshot OCR. No TCC database was edited; read-only, app-specific signing
requirements confirmed the mismatch and repair. Do not add permission resets to
the launch or install scripts. The successful retry and remaining long-dictation
issues are recorded in the [native test report](../review/moby-dick-native-verification.json).
