# Flow worker

Cloudflare Worker that turns dictated audio into finished text. TypeScript with
Hono for the HTTP layer and LangGraph for the state machine.

Deployed as `base10-proxy`, which is the URL `flow-core` (the Rust client in
`flow-core/src/providers/base10.rs`) already calls. It replaces the older Rust
worker that lived in `base10-worker/`, which implemented the same endpoints.

## How a request flows

```
transcribe ──error?──► END
    │
    ▼
  detect  (wake phrase, then the command table)
    │
    ├── no wake phrase ────► format    (LLM: restyle the dictation)
    ├── known command ─────► execute   (local: no model, no network)
    └── anything else ─────► instruct  (LLM: write what was asked for)
```

The `execute` branch is the point of the graph. An utterance like
"Hey Flow, all caps hello" resolves from a phrase table in `src/commands.ts`
and is answered without a model call. Only utterances the table does not
recognise reach `instruct`, so previous behaviour is preserved for everything
else.

Commands fall into transforms (`all caps`, `lowercase`, `title case`,
`sentence case`, `bullet list`, `numbered list`), which apply to the text after
the command, and actions (`scratch that`, `new line`, `new paragraph`), which
are returned to the client as an `action` for it to carry out.

## Endpoints

| Method | Path                     | Purpose                                 |
| ------ | ------------------------ | --------------------------------------- |
| GET    | `/health`                | Liveness probe                          |
| POST   | `/`                      | Transcribe, then format or execute      |
| POST   | `/validate-corrections`  | Judge learned correction pairs          |

`POST /` responds with `{ transcription, text }`, plus `command` and `action`
when the utterance was executed rather than sent to a model.

A provider failure answers `502`; a malformed request answers `400` naming the
first bad field.

## Models

Whisper and the chat model run on Workers AI through the `AI` binding, so no
API keys are needed. Override the chat model with a var:

```sh
wrangler deploy --var CHAT_MODEL:@cf/meta/llama-3.1-8b-instruct-fp8
```

## Develop

```sh
npm install
npm test        # vitest: command table and request parsing
npm run typecheck
npm run dev
npm run deploy
```
