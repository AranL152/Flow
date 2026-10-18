# Upstream sync — 2026-10-17

Merged `JasonLovesDoggo/Flow` main at
`8d5cd6cbcb87034f4022e85548f4a531bc04af45` into `AranL152/Flow` main, retaining
the fork at `c1fc033fb2ab5f32b72e2e951c59e9e9bd55a4be`. The histories had
36 upstream-only commits and 29 fork-only commits. No new branch or upstream
pull request was created.

## Integration decisions

- Preserve recipient style examples, profile editing, cloud fallback and the
  isolated streaming demo alongside the upstream audio, accessibility, hotkey,
  helper, alignment, undo and custom OpenAI base URL changes.
- Adopt the Auto provider name while retaining the fork's existing worker URL.
  Keep `flow-worker-langgraph/` for personalization, commands and streaming;
  keep the upstream Rust worker in `flow-worker/` too.
- Carry the auto-rewriting switch through the fork worker. Disabling it returns
  raw wording without executing wake commands or calling the formatting model.
  The worker code must be deployed separately for this switch to take effect
  on an existing cloud deployment; this sync does not deploy a worker.
- Add database migrations for style examples/contact keys and legacy history
  raw text. Upgrade tests verify stored examples survive both old schemas.
- Use upstream AX monitoring and alignment while retaining learning only on
  Return in the target app. Stable text, timeout and focus loss do not train.
  Return remains a heuristic for external apps; the demo's Send is explicit.
- Regenerate the C header using cbindgen to include both sets of FFI functions.
- Keep the fork's Aho-Corasick correction matcher, whitespace preservation and
  byte offsets. Adapt the upstream word-position assertion to that API.
- Isolate upstream FFI tests in memory rather than opening the user's database.
- Remove the now-unused Swift dependency lockfile after upstream removed
  Amplitude. Leave the local nested checkout on disk after upstream removed
  its gitlink.

## Validation

- `cargo test --manifest-path flow-core/Cargo.toml --tests --quiet`: 335 passed,
  zero failed, two ignored (macOS Messages integration).
- `cargo build`: passed; C header generated from merged FFI.
- `swift package clean && swift test`: app built; three tests passed.
- `swift build` in `FlowHelper/`: passed.
- `npm test` in `flow-worker-langgraph/`: 47 passed.
- `npm run typecheck`: passed.

No live microphone, global hotkey, Messages permissions, production database
or deployed worker behavior was exercised by these checks.
