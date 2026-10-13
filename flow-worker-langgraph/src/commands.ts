/**
 * Deterministic voice command engine.
 *
 * Not every "Hey Flow" utterance needs a language model. Commands like
 * "all caps" or "scratch that" are mechanical: resolving them here means no
 * network call, no token spend, and no chance of the model editorialising.
 *
 * An utterance resolves to one of three things:
 * - a transform, applied to the text that follows the command
 * - an action, handed back to the client to perform locally
 * - nothing, in which case the caller falls through to the LLM, which keeps
 *   the previous behaviour intact for anything not listed here
 */

/** A side effect the client performs; the worker cannot do these itself. */
export type CommandAction = "clear" | "newline" | "paragraph";

interface CommandSpec {
  /** Stable identifier, surfaced in the response for debugging */
  id: string;
  /** Trigger phrases, matched word-for-word against the start of the utterance */
  phrases: string[];
  /** Applied to the text following the command */
  transform?: (text: string) => string;
  /** Emitted for the client to carry out */
  action?: CommandAction;
}

export interface ResolvedCommand {
  id: string;
  /** Text after the command, transformed when the command defines a transform */
  text: string;
  action?: CommandAction;
}

// ============ Transforms ============

function titleCase(text: string): string {
  return text.replace(
    /\p{L}[\p{L}\p{M}'’]*/gu,
    (word) => word[0].toUpperCase() + word.slice(1).toLowerCase()
  );
}

function sentenceCase(text: string): string {
  const lowered = text.toLowerCase();
  // Capitalise the first letter, and the first letter after . ! ?
  return lowered.replace(
    /(^\s*|[.!?]\s+)(\p{L})/gu,
    (_match, lead: string, letter: string) => lead + letter.toUpperCase()
  );
}

/** Split prose into list items on sentence terminators, falling back to " and ". */
function splitItems(text: string): string[] {
  const bySentence = text
    .split(/[.!?;]+\s*/u)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);

  const parts = bySentence.length > 1 ? bySentence : text.split(/\s+and\s+/iu);

  return parts.map((part) => part.trim()).filter((part) => part.length > 0);
}

function bulletList(text: string): string {
  return splitItems(text)
    .map((item) => `- ${item}`)
    .join("\n");
}

function numberedList(text: string): string {
  return splitItems(text)
    .map((item, i) => `${i + 1}. ${item}`)
    .join("\n");
}

// ============ Command table ============

const COMMANDS: CommandSpec[] = [
  {
    id: "upper",
    phrases: ["all caps", "in all caps", "uppercase", "in uppercase"],
    transform: (text) => text.toUpperCase(),
  },
  {
    id: "lower",
    phrases: ["all lowercase", "lowercase", "in lowercase"],
    transform: (text) => text.toLowerCase(),
  },
  {
    id: "title",
    phrases: ["title case", "in title case"],
    transform: titleCase,
  },
  {
    id: "sentence",
    phrases: ["sentence case", "capitalize that", "capitalise that"],
    transform: sentenceCase,
  },
  {
    id: "bullets",
    phrases: ["bullet list", "bullet point list", "as a bullet list", "as bullets"],
    transform: bulletList,
  },
  {
    id: "numbered",
    phrases: ["numbered list", "as a numbered list"],
    transform: numberedList,
  },
  {
    id: "clear",
    phrases: ["scratch that", "delete that", "undo that", "never mind", "nevermind"],
    action: "clear",
  },
  {
    id: "newline",
    phrases: ["new line"],
    action: "newline",
  },
  {
    id: "paragraph",
    phrases: ["new paragraph"],
    action: "paragraph",
  },
];

/**
 * Phrases sorted longest-first so "all lowercase" is tried before "lowercase"
 * and "bullet point list" before "bullet list".
 */
const PHRASE_INDEX: Array<{ words: string[]; spec: CommandSpec }> = COMMANDS.flatMap(
  (spec) => spec.phrases.map((phrase) => ({ words: phrase.split(" "), spec }))
).sort((a, b) => b.words.length - a.words.length);

// ============ Matching ============

interface Token {
  lower: string;
  /** Offset just past this token in the original string */
  end: number;
}

/**
 * Split into words, remembering where each one ends in the original string.
 *
 * Matching on tokens rather than raw offsets avoids any index arithmetic
 * against a lowercased copy, so irregular spacing and punctuation after the
 * command ("all caps,  hello") cannot shift the remainder.
 */
function tokenize(text: string): Token[] {
  const tokens: Token[] = [];
  const pattern = /[^\s]+/gu;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(text)) !== null) {
    tokens.push({
      lower: match[0].toLowerCase(),
      end: match.index + match[0].length,
    });
  }

  return tokens;
}

/** Trailing commas and periods on a spoken command word are not part of it. */
function stripEdgePunctuation(word: string): string {
  return word.replace(/^[,.;:!?]+|[,.;:!?]+$/gu, "");
}

/**
 * Resolve an utterance (the text after the wake phrase) to a command.
 * Returns null when nothing matches, or when a transform has no text to act on,
 * so the caller can hand it to the LLM instead.
 */
export function resolveCommand(utterance: string): ResolvedCommand | null {
  const tokens = tokenize(utterance);
  if (tokens.length === 0) {
    return null;
  }

  for (const { words, spec } of PHRASE_INDEX) {
    if (words.length > tokens.length) {
      continue;
    }

    const matches = words.every(
      (word, i) => stripEdgePunctuation(tokens[i].lower) === word
    );
    if (!matches) {
      continue;
    }

    const remainder = utterance.slice(tokens[words.length - 1].end).trim();

    if (spec.transform) {
      // A transform with nothing to transform is not a command; let the LLM try.
      if (remainder.length === 0) {
        return null;
      }
      return { id: spec.id, text: spec.transform(remainder) };
    }

    return { id: spec.id, text: remainder, action: spec.action };
  }

  return null;
}

/** Command ids, for tests and diagnostics. */
export function knownCommandIds(): string[] {
  return COMMANDS.map((c) => c.id);
}
