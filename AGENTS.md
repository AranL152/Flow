# Flow development

- Work on this fork's `main` and push to `origin` (`AranL152/Flow`). Never push or merge into upstream. No coauthor trailers.
- Reopen with `python3 scripts/launch-native.py`. Never rebuild merely to launch.
- Native updates must use `python3 scripts/install-native.py` and the persistent certificate in `~/Library/Application Support/Flow/Signing/identity.json`. Reuse it; never recreate the keychain or certificate during ordinary development.
- Never silently fall back to ad-hoc signing, weaken the designated requirement to an identifier alone, or reset TCC/privacy grants as part of an update/test. These caused repeated file and microphone prompts. If signing is unavailable, preserve the installed app and repair signing first. See `docs/native-install.md`.
- Keep local signing secrets, screen recordings, OCR contents, contact labels and raw native logs out of Git. Use `.build/` for private verification artifacts.
- Use isolated native previews for visual iteration. Install only when testing an actual update; retain and verify mutually compatible signing requirements before replacement.
- Test Messages only in unsent drafts, preserve existing text/attachments, and never press Send. Report actual native attachment confirmation separately from a candidate match.
