const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
};

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, ctx);
  },
};

export async function handleRequest(request, env = {}) {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") return corsResponse(null, env);

  if (request.method === "GET" && url.pathname === "/health") {
    return corsResponse(
      {
        ok: true,
        service: "pie-llm-gateway",
        stores_user_data: false,
      },
      env,
    );
  }

  if (
    request.method === "POST" &&
    (url.pathname === "/api/v1/agent/respond" ||
      url.pathname === "/agent/respond" ||
      url.pathname === "/api/v1/llm/respond")
  ) {
    return handleAgentRespond(request, env);
  }

  return corsResponse({ error: "not_found" }, env, 404);
}

async function handleAgentRespond(request, env) {
  const auth = authorize(request, env);
  if (!auth.ok) return corsResponse({ error: auth.error }, env, auth.status);

  const maxBytes = Number(env.PIE_MAX_BODY_BYTES ?? 131072);
  const bodyText = await request.text();
  if (bodyText.length > maxBytes) {
    return corsResponse({ error: "payload_too_large" }, env, 413);
  }

  let payload;
  try {
    payload = JSON.parse(bodyText || "{}");
  } catch {
    return corsResponse({ error: "invalid_json" }, env, 400);
  }

  const messages = normalizeMessages(payload.messages);
  if (messages.length === 0) {
    return corsResponse({ error: "messages_required" }, env, 400);
  }

  try {
    const result = await runLlm(messages, env);
    return corsResponse(
      {
        response: result.text,
        provider: result.provider,
        model: result.model,
        request_id: crypto.randomUUID(),
      },
      env,
    );
  } catch (error) {
    return corsResponse(
      {
        error: "llm_unavailable",
        message: error instanceof Error ? error.message : "unknown error",
      },
      env,
      502,
    );
  }
}

export function authorize(request, env = {}) {
  const expected = env.PIE_GATEWAY_BEARER_TOKEN;
  if (!expected) return { ok: true };
  const actual = request.headers.get("authorization") ?? "";
  if (actual === `Bearer ${expected}`) return { ok: true };
  return { ok: false, status: 401, error: "unauthorized" };
}

export function normalizeMessages(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((message) => ({
      role: ["system", "user", "assistant"].includes(message?.role)
        ? message.role
        : "user",
      content: String(message?.content ?? "").slice(0, 24000),
    }))
    .filter((message) => message.content.trim().length > 0)
    .slice(-12);
}

async function runLlm(messages, env) {
  const model = env.LLM_MODEL || "@cf/meta/llama-3.1-8b-instruct";

  if (env.AI?.run) {
    const output = await env.AI.run(model, { messages });
    return {
      provider: "workers_ai",
      model,
      text: extractText(output),
    };
  }

  if (env.LLM_ENDPOINT) {
    const response = await fetch(env.LLM_ENDPOINT, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(env.LLM_API_KEY
          ? { authorization: `Bearer ${env.LLM_API_KEY}` }
          : {}),
      },
      body: JSON.stringify({
        model,
        messages,
        temperature: Number(env.LLM_TEMPERATURE ?? 0.2),
        max_tokens: Number(env.LLM_MAX_TOKENS ?? 700),
      }),
    });
    if (!response.ok) {
      throw new Error(`upstream_${response.status}`);
    }
    const data = await response.json();
    return {
      provider: "external",
      model,
      text: extractText(data),
    };
  }

  throw new Error("No LLM provider configured.");
}

export function extractText(output) {
  if (!output) return "";
  if (typeof output === "string") return output;
  if (typeof output.response === "string") return output.response;
  if (typeof output.result?.response === "string") return output.result.response;
  if (typeof output.choices?.[0]?.message?.content === "string") {
    return output.choices[0].message.content;
  }
  if (typeof output.text === "string") return output.text;
  return JSON.stringify(output);
}

function corsResponse(body, env, status = 200) {
  const headers = {
    ...JSON_HEADERS,
    "access-control-allow-origin": env.PIE_ALLOWED_ORIGIN ?? "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization,content-type",
    "cache-control": "no-store",
  };
  if (body === null) return new Response(null, { status: 204, headers });
  return new Response(JSON.stringify(body), { status, headers });
}
