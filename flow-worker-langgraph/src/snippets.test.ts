import { describe, expect, it, vi } from "vitest";
import { expandSnippets } from "./snippets.js";
import { dictationStream } from "./dictation-stream.js";
import { runFlowGraph } from "./graph.js";
import type { Env } from "./types.js";

const definitions = [{ trigger: "my email", replacement: "aran@example.test", case_sensitive: false }];
describe("configured snippets after ASR", () => {
  it("uses literal leftmost-longest matching without re-expanding values", () => {
    expect(expandSnippets("MY EMAIL and c++", [...definitions,
      { trigger: "c++", replacement: "my email", case_sensitive: true }]).text)
      .toBe("aran@example.test and my email");
    expect(expandSnippets("MY EMAIL", [{ ...definitions[0], case_sensitive: true }]).text).toBe("MY EMAIL");
  });
  it("expands before generation and keeps the original speech separate", async () => {
    const run = vi.fn().mockResolvedValueOnce({ text: "Reach me at my email" })
      .mockResolvedValueOnce(new ReadableStream({ start(c) {
        c.enqueue(new TextEncoder().encode('data: {"response":"Reach me at aran@example.test"}\n\ndata: [DONE]\n\n')); c.close();
      } }));
    const input = { audioB64: "fixture", audioLanguage: "en", mode: "casual", shortcutsTriggered: [], shortcutDefinitions: definitions };
    const output = await new Response(dictationStream({ AI: { run } } as unknown as Env, input)).text();
    const messages = run.mock.calls[1][1].messages;
    expect(messages[1].content).toContain("Reach me at aran@example.test");
    expect(messages[0].content).toContain("aran@example.test");
    expect(output).toContain('"text":"Reach me at my email"');
    expect(output).toContain("event: done");
  });
  it("also expands buffered raw dictation without an LLM", async () => {
    const run = vi.fn();
    const result = await runFlowGraph({ audioB64: "", text: "my email", audioLanguage: "en", mode: "casual",
      shortcutDefinitions: definitions, autoRewritingEnabled: false, env: { AI: { run } } as unknown as Env });
    expect(result.transcription).toBe("my email");
    expect(result.formattedText).toBe("aran@example.test");
    expect(run).not.toHaveBeenCalled();
  });
});
