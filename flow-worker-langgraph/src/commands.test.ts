import { describe, expect, it } from "vitest";
import { resolveCommand } from "./commands.js";

describe("resolveCommand", () => {
  it("applies a casing transform to the text that follows", () => {
    expect(resolveCommand("all caps hello world")).toEqual({
      id: "upper",
      text: "HELLO WORLD",
    });
  });

  it("matches a single word command", () => {
    expect(resolveCommand("uppercase hello")).toEqual({
      id: "upper",
      text: "HELLO",
    });
  });

  it("prefers the longer phrase when two commands share a first word", () => {
    expect(resolveCommand("all lowercase SHOUTING TEXT")).toEqual({
      id: "lower",
      text: "shouting text",
    });
  });

  it("ignores punctuation spoken after the command", () => {
    expect(resolveCommand("all caps, hello there")).toEqual({
      id: "upper",
      text: "HELLO THERE",
    });
  });

  it("is case insensitive on the command itself", () => {
    expect(resolveCommand("ALL CAPS hello")).toEqual({
      id: "upper",
      text: "HELLO",
    });
  });

  it("title cases the remainder", () => {
    expect(resolveCommand("title case the quick brown fox")).toEqual({
      id: "title",
      text: "The Quick Brown Fox",
    });
  });

  it("sentence cases the remainder across sentences", () => {
    expect(resolveCommand("sentence case hello there. how are you")).toEqual({
      id: "sentence",
      text: "Hello there. How are you",
    });
  });

  it("builds a bullet list from sentences", () => {
    expect(resolveCommand("bullet list eggs. milk. bread")).toEqual({
      id: "bullets",
      text: "- eggs\n- milk\n- bread",
    });
  });

  it("falls back to splitting on and when there are no sentences", () => {
    expect(resolveCommand("bullet list eggs and milk and bread")).toEqual({
      id: "bullets",
      text: "- eggs\n- milk\n- bread",
    });
  });

  it("builds a numbered list", () => {
    expect(resolveCommand("numbered list eggs. milk")).toEqual({
      id: "numbered",
      text: "1. eggs\n2. milk",
    });
  });

  it("returns an action with no text for a bare action command", () => {
    expect(resolveCommand("scratch that")).toEqual({
      id: "clear",
      text: "",
      action: "clear",
    });
  });

  it("emits paragraph and newline actions distinctly", () => {
    expect(resolveCommand("new paragraph")?.action).toBe("paragraph");
    expect(resolveCommand("new line")?.action).toBe("newline");
  });

  // The two cases below are what keep existing behaviour intact: anything the
  // table does not cover must fall through to the language model.
  it("returns null for an instruction the table does not cover", () => {
    expect(resolveCommand("reject him politely")).toBeNull();
  });

  it("returns null when a transform has nothing to act on", () => {
    expect(resolveCommand("all caps")).toBeNull();
    expect(resolveCommand("title case")).toBeNull();
  });

  it("returns null for an empty utterance", () => {
    expect(resolveCommand("")).toBeNull();
    expect(resolveCommand("   ")).toBeNull();
  });
});
