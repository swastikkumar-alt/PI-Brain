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

  if (
    request.method === "POST" &&
    (url.pathname === "/api/v1/images/generate" ||
      url.pathname === "/images/generate")
  ) {
    return handleImageGenerate(request, env);
  }

  return corsResponse({ error: "not_found" }, env, 404);
}

async function handleImageGenerate(request, env) {
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

  const prompt = String(payload.prompt ?? "").trim().slice(0, 4000);
  if (!prompt) {
    return corsResponse({ error: "prompt_required" }, env, 400);
  }

  if (env.IMAGE_ENDPOINT) {
    return handleExternalImageProvider(prompt, env);
  }

  if (!env.GEMINI_API_KEY) {
    return corsResponse(
      {
        error: "image_provider_not_configured",
        message:
          "Set GEMINI_API_KEY or IMAGE_ENDPOINT to enable image generation.",
      },
      env,
      501,
    );
  }

  try {
    const result = await runGeminiImage(prompt, env);
    return corsResponse(
      {
        ...result,
        provider: "gemini",
        model: env.GEMINI_IMAGE_MODEL || "gemini-2.5-flash-image",
        request_id: crypto.randomUUID(),
      },
      env,
    );
  } catch (error) {
    return corsResponse(
      {
        error: "image_generation_failed",
        message: error instanceof Error ? error.message : "unknown error",
      },
      env,
      502,
    );
  }
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

async function handleExternalImageProvider(prompt, env) {
  const response = await fetch(env.IMAGE_ENDPOINT, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(env.IMAGE_API_KEY ? { authorization: `Bearer ${env.IMAGE_API_KEY}` } : {}),
    },
    body: JSON.stringify({ prompt }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    return corsResponse(
      {
        error: "image_generation_failed",
        message: data.message || data.error || `upstream_${response.status}`,
      },
      env,
      502,
    );
  }
  return corsResponse(
    {
      image_url: data.image_url || data.url,
      image_base64: data.image_base64 || data.b64_json,
      mime_type: data.mime_type || "image/png",
      provider: "external",
      model: env.IMAGE_MODEL || data.model || "external-image-provider",
      request_id: crypto.randomUUID(),
    },
    env,
  );
}

async function runGeminiImage(prompt, env) {
  const model = env.GEMINI_IMAGE_MODEL || "gemini-2.5-flash-image";
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model,
  )}:generateContent?key=${encodeURIComponent(env.GEMINI_API_KEY)}`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      contents: [
        {
          role: "user",
          parts: [{ text: prompt }],
        },
      ],
      generationConfig: {
        responseModalities: ["TEXT", "IMAGE"],
      },
    }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.error?.message || `gemini_${response.status}`);
  }

  const parts = data.candidates?.[0]?.content?.parts || [];
  for (const part of parts) {
    const inline = part.inlineData || part.inline_data;
    if (inline?.data) {
      return {
        image_base64: inline.data,
        mime_type: inline.mimeType || inline.mime_type || "image/png",
      };
    }
  }

  const text = parts.map((part) => part.text).filter(Boolean).join("\n").trim();
  throw new Error(text || "Gemini returned no image data.");
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
