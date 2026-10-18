import { PLANNER_PROMPT, validatePlan } from "./planner";

interface Env { AI: { run(model: string, input: unknown): Promise<{response?: unknown}> } }
export default {
  async fetch(request: Request, env: Env) {
    if (new URL(request.url).pathname !== "/probe" || request.method !== "POST") return new Response("Research probe", {status:200});
    const input = await request.json() as { transcript: string; mode: "dictation" | "assist" };
    if (typeof input.transcript !== "string" || input.transcript.length > 2000 || !["dictation", "assist"].includes(input.mode)) return Response.json({error:"invalid input"}, {status:400});
    const start = Date.now();
    // A hard mode boundary preserves ordinary dictation. The LLM cannot turn
    // a literal message into a filesystem request when assist was not invoked.
    if (input.mode === "dictation") return Response.json({plan:{message:input.transcript,requests:[],needs_clarification:false},model_called:false,milliseconds:Date.now()-start});
    try {
      const result = await env.AI.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
        messages:[{role:"system",content:PLANNER_PROMPT},{role:"user",content:JSON.stringify({transcript:input.transcript,recipient:"Alex"})}],
        temperature:0,max_tokens:500,
      });
      const text = typeof result.response === "string" ? result.response : JSON.stringify(result.response);
      const plan = validatePlan(JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/gu,"")));
      return Response.json({plan,model_called:true,milliseconds:Date.now()-start});
    } catch (error) { return Response.json({error:String(error),model_called:true,milliseconds:Date.now()-start},{status:502}); }
  },
};
