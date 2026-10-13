/**
 * LangGraph state machine for the Flow worker.
 *
 * Graph structure:
 *
 *            ┌────────────┐
 *            │ transcribe │  (Whisper)
 *            └─────┬──────┘
 *                  │ error? ──────────────► END
 *                  ▼
 *            ┌──────────┐
 *            │  detect  │  (wake phrase + command table)
 *            └────┬─────┘
 *                 │
 *      ┌──────────┼──────────┐
 *      ▼          ▼          ▼
 * ┌────────┐ ┌─────────┐ ┌──────────┐
 * │ format │ │ execute │ │ instruct │
 * │  (LLM) │ │ (local) │ │   (LLM)  │
 * └────┬───┘ └────┬────┘ └────┬─────┘
 *      └──────────┼───────────┘
 *                 ▼
 *                END
 *
 * `execute` is the path that needs no model: a recognised command runs here,
 * which is why it costs nothing and returns immediately.
 */

import { Annotation, StateGraph, END } from "@langchain/langgraph";
import type { CommandAction, ResolvedCommand } from "./commands.js";
import type { Env, FlowConfigurable, FlowState } from "./types.js";
import {
  transcribeNode,
  detectWakePhraseNode,
  routeAfterTranscribe,
  routeByCommand,
  formatNode,
  executeNode,
  instructNode,
} from "./nodes.js";

/**
 * State schema. Note there is no env field: secrets reach nodes through the
 * runtime config so they stay out of anything LangGraph serialises.
 */
const FlowStateAnnotation = Annotation.Root({
  // Input
  audioB64: Annotation<string>(),
  audioLanguage: Annotation<string>(),
  promptHint: Annotation<string | undefined>(),
  mode: Annotation<string>(),
  appContext: Annotation<string | undefined>(),
  shortcutsTriggered: Annotation<string[]>(),
  voiceInstruction: Annotation<string | undefined>(),

  // Intermediate
  transcription: Annotation<string | undefined>(),
  detectedCommand: Annotation<string | undefined>(),
  resolvedCommand: Annotation<ResolvedCommand | undefined>(),

  // Output
  formattedText: Annotation<string | undefined>(),
  command: Annotation<string | undefined>(),
  action: Annotation<CommandAction | undefined>(),
  error: Annotation<string | undefined>(),
});

function buildFlowGraph() {
  const graph = new StateGraph(FlowStateAnnotation)
    .addNode("transcribe", transcribeNode)
    .addNode("detect", detectWakePhraseNode)
    .addNode("format", formatNode)
    .addNode("execute", executeNode)
    .addNode("instruct", instructNode)
    .addEdge("__start__", "transcribe")
    .addConditionalEdges("transcribe", routeAfterTranscribe, {
      detect: "detect",
      end: END,
    })
    .addConditionalEdges("detect", routeByCommand, {
      format: "format",
      execute: "execute",
      instruct: "instruct",
    })
    .addEdge("format", END)
    .addEdge("execute", END)
    .addEdge("instruct", END);

  return graph.compile();
}

// Compile once per isolate
export const flowGraph = buildFlowGraph();

export interface FlowGraphInput {
  audioB64: string;
  audioLanguage: string;
  promptHint?: string;
  mode: string;
  appContext?: string;
  shortcutsTriggered?: string[];
  voiceInstruction?: string;
  env: Env;
}

/**
 * Run the graph. A thrown error is mapped onto the state's error field so the
 * HTTP layer has one failure shape to handle.
 */
export async function runFlowGraph(input: FlowGraphInput): Promise<FlowState> {
  const { env, ...rest } = input;

  const initialState: FlowState = {
    ...rest,
    shortcutsTriggered: rest.shortcutsTriggered ?? [],
  };

  const configurable: FlowConfigurable = { env };

  try {
    const result = await flowGraph.invoke(initialState, { configurable });
    return result as FlowState;
  } catch (err) {
    return {
      ...initialState,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
