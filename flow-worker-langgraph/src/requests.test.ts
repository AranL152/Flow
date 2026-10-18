import { describe, expect, it } from "vitest";
import {
  MAX_AUDIO_BYTES,
  parseCorrectionsRequest,
  parseStyleProfileRequest,
  parseTranscriptionRequest,
} from "./requests.js";

function validBody(): Record<string, unknown> {
  return {
    whisper_input: {
      audio: { audio_b64: "AAAA" },
      whisper_params: { audio_language: "en" },
    },
    completion: { mode: "casual" },
  };
}

describe("parseTranscriptionRequest", () => {
  it("requires a boolean search capability and carries it through", () => {
    const body = validBody();
    body.completion = { mode: "casual", attachment_search_enabled: "yes" };
    expect(parseTranscriptionRequest(body).ok).toBe(false);
    body.completion = { mode: "casual", attachment_search_enabled: true };
    expect(parseTranscriptionRequest(body)).toMatchObject({ ok: true, value: { attachmentSearchEnabled: true } });
  });
  it("accepts a minimal request and defaults the shortcut list", () => {
    const result = parseTranscriptionRequest(validBody());

    expect(result).toEqual({
      ok: true,
      value: {
        audioB64: "AAAA",
        audioLanguage: "en",
        promptHint: undefined,
        mode: "casual",
        appContext: undefined,
        shortcutsTriggered: [],
        voiceInstruction: undefined,
      },
    });
  });

  it("rejects a non-object body", () => {
    expect(parseTranscriptionRequest("nope").ok).toBe(false);
    expect(parseTranscriptionRequest([]).ok).toBe(false);
    expect(parseTranscriptionRequest(null).ok).toBe(false);
  });

  it("reports the missing field", () => {
    const body = validBody();
    delete (body.whisper_input as Record<string, unknown>).audio;

    const result = parseTranscriptionRequest(body);

    expect(result.ok).toBe(false);
    expect(result.ok === false && result.error).toContain("audio_b64");
  });

  it("rejects a mode of the wrong type", () => {
    const body = validBody();
    (body.completion as Record<string, unknown>).mode = 7;

    const result = parseTranscriptionRequest(body);

    expect(result.ok).toBe(false);
    expect(result.ok === false && result.error).toContain("completion.mode");
  });

  it("rejects shortcuts that are not an array of strings", () => {
    const body = validBody();
    (body.completion as Record<string, unknown>).shortcuts_triggered = "nope";
    expect(parseTranscriptionRequest(body).ok).toBe(false);

    (body.completion as Record<string, unknown>).shortcuts_triggered = [1, 2];
    expect(parseTranscriptionRequest(body).ok).toBe(false);
  });

  it("rejects audio over the size limit before forwarding it", () => {
    const body = validBody();
    // Four base64 characters carry three bytes, so this clears the limit.
    const oversized = "A".repeat(Math.ceil((MAX_AUDIO_BYTES * 4) / 3) + 8);
    (body.whisper_input as Record<string, unknown>).audio = {
      audio_b64: oversized,
    };

    const result = parseTranscriptionRequest(body);

    expect(result.ok).toBe(false);
    expect(result.ok === false && result.error).toContain("limit");
  });

  it("carries optional fields through", () => {
    const body = validBody();
    (body.whisper_input as Record<string, unknown>).whisper_params = {
      audio_language: "en",
      prompt: "a hint",
    };
    body.completion = {
      mode: "formal",
      app_context: "Mail",
      shortcuts_triggered: ["jsn.cam/li"],
      voice_instruction: "say thanks",
    };

    const result = parseTranscriptionRequest(body);

    expect(result.ok).toBe(true);
    expect(result.ok === true && result.value).toMatchObject({
      promptHint: "a hint",
      mode: "formal",
      appContext: "Mail",
      shortcutsTriggered: ["jsn.cam/li"],
      voiceInstruction: "say thanks",
    });
  });
});

describe("parseCorrectionsRequest", () => {
  it("accepts well formed pairs", () => {
    const result = parseCorrectionsRequest({
      corrections: [{ original: "teh", corrected: "the" }],
    });

    expect(result).toEqual({
      ok: true,
      value: [{ original: "teh", corrected: "the" }],
    });
  });

  it("accepts an empty list", () => {
    expect(parseCorrectionsRequest({ corrections: [] })).toEqual({
      ok: true,
      value: [],
    });
  });

  it("rejects a missing or non-array corrections field", () => {
    expect(parseCorrectionsRequest({}).ok).toBe(false);
    expect(parseCorrectionsRequest({ corrections: "teh" }).ok).toBe(false);
  });

  it("rejects pairs with missing sides", () => {
    expect(parseCorrectionsRequest({ corrections: [{ original: "teh" }] }).ok).toBe(
      false
    );
  });

  it("rejects an oversized batch", () => {
    const corrections = Array.from({ length: 101 }, () => ({
      original: "teh",
      corrected: "the",
    }));

    expect(parseCorrectionsRequest({ corrections }).ok).toBe(false);
  });
});

describe("typed text and personalization", () => {
  it("accepts typed text without audio", () => {
    const body = validBody();
    body.whisper_input = { text: "hi how are you", whisper_params: { audio_language: "en" } };

    const result = parseTranscriptionRequest(body);
    expect(result.ok && result.value.text).toBe("hi how are you");
  });

  it("still requires audio when no text is given", () => {
    const body = validBody();
    body.whisper_input = { whisper_params: { audio_language: "en" } };

    expect(parseTranscriptionRequest(body)).toEqual({
      ok: false,
      error: "missing whisper_input.audio.audio_b64",
    });
  });

  it("carries personalization through", () => {
    const body = validBody();
    (body.completion as Record<string, unknown>).personalization = "lowercase always";

    const result = parseTranscriptionRequest(body);
    expect(result.ok && result.value.personalization).toBe("lowercase always");
  });
});

describe("parseStyleProfileRequest", () => {
  it("parses examples and the current profile", () => {
    const result = parseStyleProfileRequest({
      examples: [
        { category: "partner", sent: "omw bub" },
        { category: "friend", sent: "lol no", formatter_wrote: "Haha, no." },
      ],
      current_profile: "## Overall",
    });

    expect(result).toEqual({
      ok: true,
      value: {
        examples: [
          { category: "partner", sent: "omw bub", formatterWrote: undefined },
          { category: "friend", sent: "lol no", formatterWrote: "Haha, no." },
        ],
        currentProfile: "## Overall",
      },
    });
  });

  it("rejects an empty example list", () => {
    expect(parseStyleProfileRequest({ examples: [] })).toEqual({
      ok: false,
      error: "missing examples array",
    });
  });
});
