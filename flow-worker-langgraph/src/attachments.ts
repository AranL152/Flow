/** No model chooses files. This parser returns a local source request only. */
export interface AttachmentRequest {
  source: "clipboard" | "recent_download" | "file_search";
  kind: "any" | "image" | "pdf" | "presentation";
  query?: string;
}
export interface AttachmentPlan {
  message: string;
  command: string;
  request?: AttachmentRequest;
  clarification?: string;
}

// Keep aligned with FlowCommandCaption.commandVerbPattern on the native client.
export const attachmentVerbPattern = String.raw`(?:attach|add|include|insert|paste|append|enclose|upload|find|locate|fetch|retrieve|grab|get|select|pick(?:\s+out)?|search(?:\s+for)?|look\s+(?:for|up)|pull(?:\s+(?:up|in))?|bring(?:\s+(?:up|in))?|drop(?:\s+in)?|put)`;
const politenessPattern = String.raw`(?:(?:please|(?:can|could|would)\s+you)\s+)?(?:please\s+)?`;
const attachmentCue = new RegExp(String.raw`\b(?:hey\s+)?flow\s*[,;:.!?]*\s+${politenessPattern}${attachmentVerbPattern}\b`, "iu");

/** One terminal explicit Flow attachment instruction, after the message. */
export function parseAttachmentCommand(text: string, fileSearchEnabled = false): AttachmentPlan | undefined {
  const cue = attachmentCue.exec(text);
  if (!cue) return;
  const prefix = text.slice(0, cue.index);
  // Reported/quoted speech is recipient content. Apostrophes in "here's" aren't quotes.
  const quoted = (prefix.match(/"/gu)?.length ?? 0) % 2 !== 0 ||
    ((prefix.match(/“/gu)?.length ?? 0) > (prefix.match(/”/gu)?.length ?? 0)) ||
    /(?:^|[\s([{])['‘][^'’]*$/u.test(prefix);
  if (quoted || /\b(?:said|says|say|told|tell|quote|quoted|phrase|tutorial|example|type|write|don['’]t|do\s+not|never)\b[^.!?]*$/iu.test(prefix)) return;
  const message = prefix.trim().replace(/[,;:]\s*$/u, "").trim();
  const command = text.slice(cue.index).trim();
  const object = text.slice(cue.index + cue[0].length).trim().replace(/[.!?]+$/u, "")
    .replace(/\s+(?:to|into|in)\s+(?:(?:this|the|my)\s+)?(?:message|chat|draft)$/iu, "").trim();
  const choose = (clarification: string): AttachmentPlan => ({ message, command, clarification });
  // Never guess across extra instructions, negation, versions or missing context.
  if (!object || /\b(?:and|then|except|instead|not|don't|without|yesterday|earlier|second|another|other|one\s+i\s+meant|flow)\b/iu.test(object)) {
    return choose("Say ‘Flow, attach the image on my clipboard’ or ‘Flow, attach the PDF I just downloaded.’");
  }
  const kind: AttachmentRequest["kind"] = /\bpdf\b/iu.test(object) ? "pdf" :
    /\b(?:image|photo|picture|screenshot)\b/iu.test(object) ? "image" :
    /\b(?:presentation|slides|slideshow|deck|powerpoint)\b/iu.test(object) ? "presentation" : "any";
  if (/^(?:(?:the|my|a)\s+)?(?:(?:image|photo|picture|screenshot|file|pdf|presentation)\s+(?:on|from|in)\s+)?(?:(?:my|the)\s+)?clipboard(?:\s+(?:image|photo|picture|file))?$/iu.test(object) ||
      /^(?:what|the\s+file|the\s+image)\s+i\s+just\s+copied$/iu.test(object)) {
    return { message, command, request: { source: "clipboard", kind } };
  }
  const fileKind = "(?:file|pdf|image|photo|picture|screenshot|presentation|slides|deck|powerpoint|zip)";
  const downloaded = new RegExp(`^(?:(?:the|my)\\s+)?(?:(?:latest|last|newest|most\\s+recent)\\s+)?${fileKind}\\s+(?:(?:that\\s+)?i\\s+(?:just\\s+)?downloaded|from\\s+(?:(?:my|the)\\s+)?downloads)$`, "iu");
  const latest = new RegExp(`^(?:(?:the|my)\\s+)?(?:latest|last|newest|most\\s+recent)\\s+(?:download|downloaded\\s+${fileKind})$`, "iu");
  if (downloaded.test(object) || latest.test(object)) {
    // A ZIP request needs exact filtering, which isn't a supported kind yet.
    if (/\bzip\b/iu.test(object)) return choose("ZIP selection isn't available yet. Choose a file manually.");
    return { message, command, request: { source: "recent_download", kind } };
  }
  if (fileSearchEnabled) {
    // Filename terms only. No model-generated paths, semantic file reads or sends.
    const query = object.replace(/^(?:(?:my|the)\s+)?files?\s+for\s+/iu, "")
      .replace(/\b(?:the|my|a|an|file|document|image|photo|picture|screenshot|pdf|presentation|slides|slideshow|deck|powerpoint|named|called|containing|of|for)\b/giu, " ")
      .replace(/^[“”"'‘’]+|[“”"'‘’]+$/gu, "").replace(/\s+/gu, " ").trim();
    if (query && query.length <= 160 && /[\p{L}\p{N}]/u.test(query) &&
        !/[\/\\\u0000-\u001f]/u.test(query) && query.split(/\s+/u).length <= 12) {
      return { message, command, request: { source: "file_search", kind, query } };
    }
    return choose("Name part of the filename, for example ‘Flow, find my robotics presentation.’");
  }
  return choose("I couldn't identify a clipboard or recent-download request. Choose the file, or name one of those sources.");
}
