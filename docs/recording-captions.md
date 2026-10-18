# Native live captions and recording UI

The normal Flow recording overlay now shows the microphone waveform and the
live words being recognized. The Record tab also keeps a **You said** section,
separate from formatted output. **Settings → General → Live speech captions**
turns captions on or off.

Captions use Apple's Speech framework with partial results and on-device
recognition required. Swift reads bounded mono sample chunks from the existing
Rust microphone capture; it does not open a second microphone or consume the
audio needed by final transcription. At Stop it reads the remaining cached PCM
before the final pipeline consumes that audio.

These are unformatted recognition results. Words can revise as more audio
arrives, and recognition can be wrong. They are not guaranteed verbatim text
and are not the personalized output. Automatic punctuation is disabled for the
caption request. The Auto provider also streams formatted model output after Stop; see
[streamed dictation](streamed-dictation.md).

The waveform samples measured microphone levels on a clock, including unchanged
silence. A fixed loudness range and quick attack/gentler release make speech
visible without turning quiet background noise into a full-height waveform.
No animation, DSP or speech dependency was added: Speech, AVFoundation and
SwiftUI are system frameworks.

## Build the normal app

```sh
python3 scripts/build-demo.py --native
open .build/Flow.app
```

The build script compiles and bundles FlowHelper and includes microphone and
Speech usage descriptions. Open the bundle through Finder/Launch Services for
the intended macOS privacy identity. Running the raw executable from an editor
can attribute Speech permission to that editor and cause a TCC termination if
the editor lacks the usage description. This happened during the initial
verification attempt; the detached native fixture launch below succeeded.

On first recording, macOS may request Speech Recognition authorization. If
captions or on-device recognition are unavailable, Flow shows a status message
and continues normal dictation. Captions use the Mac's current locale.

## Reproducible verification

```sh
python3 scripts/verify-recording.py
# After a fresh Rust + Swift build, skip compilation:
python3 scripts/verify-recording.py --skip-build
```

The verifier generates a local Samantha voice fixture saying “Can you check the
slides tomorrow”. It launches an isolated native preview under launchd, feeds
that audio to the same caption recognizer in real time, records actual partial
and final results and captures the actual SwiftUI views. No microphone recording,
real contacts, production database, message sending or privacy-setting edits are
performed. The temporary launchd jobs are removed when each check finishes.

The other preview uses explicitly labelled simulated captions/levels to check
speech, constant silence and processing states. It is a UI fixture, not ASR
evidence. It renders the same recording indicator and waveform components used
by the normal app.

Results: [recording verification](../review/recording-verification.json),
[caption UI](../review/recording-captions.png),
[silence UI](../review/recording-silence.png).

The audio fixture produced eight real recognition updates and a matching final
sentence. Unit/integration checks cover bounds, end-of-audio reads, preservation
of final-transcription audio, waveform silence decay and input sanitization.
343 Rust tests and 11 Swift tests passed (two Messages tests remain ignored).

macOS blocked System Events UI automation from this editor. The preview's own
native rendering and recorded state were used instead; this is not an XCUITest
run. Physical microphone behavior, device switching and the global hotkey still
need a live take. Fixture timings include app/model/permission startup and UI
capture; they are not latency benchmarks.

Apple references:
- [Partial recognition results](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/shouldreportpartialresults)
- [Audio-buffer recognition](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)
- [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation)
