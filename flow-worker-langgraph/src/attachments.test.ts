import { describe, expect, it } from "vitest";
import { parseAttachmentCommand as parse } from "./attachments.js";

describe("explicit attachment boundary", () => {
  it.each(["Q2", "Q two", "second quarter", "quarter two"])
    ("accepts %s as a calendar period, preserving the spoken boundary", period => {
      const text = `Here's the report. Flow, find the PDF for the quarterly report from ${period} 2026.`;
      expect(parse(text, true)).toMatchObject({
        message: "Here's the report.", command: text.slice(text.indexOf("Flow")),
        request: { source: "file_search", kind: "pdf", query: "quarterly report from Q2 2026" },
      });
      expect(parse("Flow, find the second PDF from downloads", true)?.request).toBeUndefined();
      expect(parse(`Flow find the PDF from ${period} 2026 and send it`, true)?.request).toBeUndefined();
    });
  it.each(["attach", "add", "include", "insert", "paste", "append", "enclose", "upload", "find", "locate", "fetch", "retrieve", "grab", "get", "select", "pick", "pick out", "search", "search for", "look for", "look up", "pull", "pull up", "pull in", "bring", "bring up", "bring in", "drop", "drop in", "put"])
    ("supports %s consistently for clipboard, downloads and search", verb => {
      expect(parse(`Here's the issue. Flow, ${verb} the image on my clipboard.`)).toMatchObject({message: "Here's the issue.", request: {source: "clipboard", kind: "image"}});
      expect(parse(`Flow ${verb} the PDF I just downloaded`)).toMatchObject({request: {source: "recent_download", kind: "pdf"}});
      expect(parse(`Flow ${verb} the screenshot showing payment error`, true)).toMatchObject({request: {source: "file_search", kind: "image", query: "showing payment error"}});
      expect(parse(`Don't Flow ${verb} my clipboard`)).toBeUndefined();
      expect(parse(`The tutorial says "Flow ${verb} my clipboard"`)).toBeUndefined();
    });
  it("supports polite phrasing and an explicit draft destination", () => {
    expect(parse("Flow, could you please add the image on my clipboard to this message.")).toMatchObject({request: {source: "clipboard", kind: "image"}});
    expect(parse("Flow please insert the PDF I just downloaded into the draft")).toMatchObject({request: {source: "recent_download", kind: "pdf"}});
    expect(parse("Flow additionally explains the image")).toBeUndefined();
  });
  it.each([
    ["Hey Alex, here's the slideshow. Flow, find my robotics presentation.", "Hey Alex, here's the slideshow.", "robotics", "presentation"],
    ["Flow attach the beach trip photo", "", "beach trip", "image"],
    ["Flow search my files for invoice", "", "invoice", "any"],
    ["Flow find the PDF called Final Report", "", "Final Report", "pdf"],
    ["Here's the issue. Flow, find the screenshot showing payment error.", "Here's the issue.", "showing payment error", "image"],
    ["Flow attach the screenshot with card declined", "", "with card declined", "image"],
  ])("offers filename search for %s only to capable clients", (text, message, query, kind) => {
    expect(parse(text, true)).toMatchObject({ message, request: { source: "file_search", query, kind } });
    expect(parse(text)?.request).toBeUndefined();
  });
  it.each(["Flow find my image", "Flow find /etc/passwd", "Flow find invoice and send it", "Don't Flow find invoice", 'The tutorial says "Flow find invoice"'])
    ("doesn't turn ambiguous, path or reported content into a search: %s", text => {
      expect(parse(text, true)?.request).toBeUndefined();
    });
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
