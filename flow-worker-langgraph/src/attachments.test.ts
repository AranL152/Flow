import { describe, expect, it } from "vitest";
import { parseAttachmentCommand as parse } from "./attachments.js";

describe("explicit attachment boundary", () => {
  it.each([
    ["Here's the deck. Flow, attach the PDF I just downloaded.", "Here's the deck.", "recent_download", "pdf"],
    ["Here's the deck. Flow. Attach the PDF I just downloaded.", "Here's the deck.", "recent_download", "pdf"],
    ["Here's the deck Flow attach the pdf I just downloaded", "Here's the deck", "recent_download", "pdf"],
    ["Here it is. Flow attach the latest download", "Here it is.", "recent_download", "any"],
    ["Flow, attach the image on my clipboard", "", "clipboard", "image"],
    ["Here's the chart! Flow attach my clipboard", "Here's the chart!", "clipboard", "any"],
    ["Flow attach the last PDF from Downloads", "", "recent_download", "pdf"],
    ["Flow attach what I just copied", "", "clipboard", "any"],
  ])("separates %s", (text, message, source, kind) => {
    expect(parse(text)).toMatchObject({ message, request: { source, kind } });
  });
  it.each([
    "Please attach the invoice when you reply.", "Please attach the invoice.",
    'The tutorial says "Flow, attach my clipboard".',
    "I told Flow attach my clipboard", "Don't Flow attach my clipboard",
    "I said ‘Flow attach my clipboard’", "The phrase Flow attach is useful",
    "‘Flow attach my clipboard’", "Don’t Flow attach my clipboard",
  ])("doesn't execute recipient or reported speech: %s", text => {
    expect(parse(text)).toBeUndefined();
  });
  it.each([
    "Flow attach the one I meant earlier", "Flow attach yesterday's screenshot",
    "Flow attach the PDF I downloaded and send it", "Flow attach the second PDF from downloads",
    "Flow attach the invoice", "Flow attach", "Flow attach the latest downloaded zip",
  ])("asks instead of selecting a different file: %s", text => {
    expect(parse(text)?.clarification).toBeTruthy();
    expect(parse(text)?.request).toBeUndefined();
  });
});
