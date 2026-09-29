import { createClient } from "npm:@supabase/supabase-js@2";

const allowedActions = new Set([
  "deepen",
  "summarize",
  "organize",
  "rewrite",
  "exegesis",
  "theology",
  "infographic",
]);

const prompts: Record<string, string> = {
  deepen: "Responde en español. Ayuda a profundizar en este aprendizaje bíblico con observaciones del contexto literario e histórico, preguntas para reflexionar y aplicaciones prudentes. Separa claramente lo que dice el pasaje de las inferencias.",
  summarize: "Resume en español el aprendizaje proporcionado en una síntesis clara y fiel, conservando las ideas y referencias bíblicas importantes. No añadas afirmaciones que no estén en el texto.",
  organize: "Organiza en español estas notas en: tema central, observaciones, ideas relacionadas, referencias bíblicas y aplicación. Conserva el sentido original y marca cualquier inferencia.",
  rewrite: "Corrige la redacción y ortografía en español, mejorando claridad y fluidez sin cambiar las ideas, el tono personal ni las referencias bíblicas.",
  exegesis: "Prepara una ayuda de estudio exegético en español. Explica contexto literario e histórico, estructura, términos relevantes solo cuando puedas sustentarlos, y distintas interpretaciones reconocidas. Distingue hechos, hipótesis y aplicaciones. No inventes datos de idiomas originales ni fuentes.",
  theology: "Revisa este aprendizaje teológicamente en español. Compara cada afirmación con el contexto bíblico citado, indica acuerdos, tensiones y posibles interpretaciones alternativas. No declares certeza donde haya desacuerdo entre tradiciones; incluye las referencias que deberían revisarse. Esto es una ayuda de estudio, no una autoridad pastoral.",
  infographic: "Diseña una infografía editorial en español que resuma fielmente el aprendizaje. Usa pocas frases legibles, jerarquía clara, referencias bíblicas exactas y una composición limpia. No inventes versículos ni añadas texto decorativo ilegible.",
};

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});

Deno.serve(async (request: Request) => {
  const configuredOrigin = Deno.env.get("APP_ORIGIN");
  const requestOrigin = request.headers.get("origin");
  const allowedOrigin = configuredOrigin || "";
  const headers = corsHeaders(allowedOrigin);

  if (!configuredOrigin) {
    return Response.json({ error: "The allowed app origin is not configured" }, { status: 503 });
  }

  if (request.method === "OPTIONS") {
    return new Response("ok", { headers });
  }
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405, headers });
  }
  if (configuredOrigin && requestOrigin !== configuredOrigin) {
    return Response.json({ error: "Origin not allowed" }, { status: 403, headers });
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return Response.json({ error: "Authentication required" }, { status: 401, headers });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKeys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") || publishableKeys.default;
  const openAiKey = Deno.env.get("OPENAI_API_KEY");
  if (!supabaseUrl || !supabaseAnonKey || !openAiKey) {
    return Response.json({ error: "The AI service is not configured" }, { status: 503, headers });
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await supabase.auth.getUser(authorization.slice("Bearer ".length));
  if (authError || !authData.user) {
    return Response.json({ error: "Invalid session" }, { status: 401, headers });
  }

  let body: { action?: string; text?: string; spaceId?: string };
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400, headers });
  }

  const action = body.action || "";
  const text = typeof body.text === "string" ? body.text.trim() : "";
  const spaceId = typeof body.spaceId === "string" ? body.spaceId : "";
  if (!allowedActions.has(action) || !text || text.length > 20000 || !spaceId) {
    return Response.json({ error: "Action, study text, or space is invalid" }, { status: 400, headers });
  }

  const { data: membership, error: membershipError } = await supabase
    .from("study_members")
    .select("space_id")
    .eq("space_id", spaceId)
    .eq("user_id", authData.user.id)
    .maybeSingle();
  if (membershipError || !membership) {
    return Response.json({ error: "You are not a member of this study space" }, { status: 403, headers });
  }

  const { error: quotaError } = await supabase.rpc("consume_ai_request");
  if (quotaError) {
    const status = quotaError.message.includes("Daily AI request limit") ? 429 : 503;
    return Response.json({ error: status === 429 ? "Daily AI limit reached" : "AI quota could not be checked" }, { status, headers });
  }

  const requestBody: Record<string, unknown> = {
    model: Deno.env.get("OPENAI_MODEL") || "gpt-4.1-mini",
    input: [
      { role: "system", content: prompts[action] },
      { role: "user", content: text },
    ],
    max_output_tokens: action === "infographic" ? 1200 : 2400,
    store: false,
  };
  if (action === "infographic") {
    requestBody.tools = [{
      type: "image_generation",
      model: Deno.env.get("OPENAI_IMAGE_MODEL") || "gpt-image-1-mini",
      size: "1024x1024",
      quality: "low",
    }];
    requestBody.tool_choice = { type: "image_generation" };
  }

  let openAiResponse: Response;
  try {
    openAiResponse = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
    });
  } catch {
    return Response.json({ error: "Could not reach the AI provider" }, { status: 502, headers });
  }

  if (!openAiResponse.ok) {
    return Response.json({ error: "The AI provider rejected the request" }, { status: 502, headers });
  }

  const result = await openAiResponse.json();
  const textOutput = Array.isArray(result.output)
    ? result.output.flatMap((item: { content?: Array<{ type?: string; text?: string }> }) => item.content || [])
      .filter((part: { type?: string }) => part.type === "output_text")
      .map((part: { text?: string }) => part.text || "")
      .join("\n")
    : "";
  const imageOutput = action === "infographic" && Array.isArray(result.output)
    ? result.output.find((item: { type?: string }) => item.type === "image_generation_call")?.result || null
    : null;

  if (!textOutput && !imageOutput) {
    return Response.json({ error: "The AI provider returned no result" }, { status: 502, headers });
  }

  return Response.json({ text: textOutput, image: imageOutput }, { headers });
});
