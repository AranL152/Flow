import type { ShortcutDefinition } from "./types.js";

/** Literal, single-pass expansion: replacement text never triggers another snippet. */
export function expandSnippets(text: string, snippets: ShortcutDefinition[]) {
  const patterns = snippets.filter(s => s.trigger.length).map(s => ({ ...s,
    pattern: new RegExp(s.trigger.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), s.case_sensitive ? "gu" : "giu"),
  }));
  let cursor = 0;
  let output = "";
  const replacements: string[] = [];
  while (cursor < text.length) {
    let chosen: { start: number; end: number; replacement: string } | undefined;
    for (const snippet of patterns) {
      snippet.pattern.lastIndex = cursor;
      const match = snippet.pattern.exec(text);
      if (match && (!chosen || match.index < chosen.start ||
          (match.index === chosen.start && match[0].length > chosen.end - chosen.start))) {
        chosen = { start: match.index, end: match.index + match[0].length, replacement: snippet.replacement };
      }
    }
    if (!chosen) break;
    output += text.slice(cursor, chosen.start) + chosen.replacement;
    replacements.push(chosen.replacement);
    cursor = chosen.end;
  }
  return { text: output + text.slice(cursor), replacements };
}
