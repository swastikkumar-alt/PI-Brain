import test from "node:test";
import assert from "node:assert/strict";
import { authorize, extractText, handleRequest, normalizeMessages } from "../src/index.js";

test("requires bearer token when configured", () => {
  const request = new Request("https://example.test/api/v1/agent/respond");
  assert.equal(authorize(request, { PIE_GATEWAY_BEARER_TOKEN: "secret" }).ok, false);
});

test("normalizes messages and drops empty content", () => {
  const messages = normalizeMessages([
    { role: "system", content: "keep local" },
    { role: "bad", content: "hello" },
    { role: "user", content: "" },
  ]);
  assert.deepEqual(messages, [
    { role: "system", content: "keep local" },
    { role: "user", content: "hello" },
  ]);
});

test("health endpoint reports no storage", async () => {
  const response = await handleRequest(new Request("https://example.test/health"));
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.stores_user_data, false);
});

test("agent endpoint can use Workers AI binding", async () => {
  const response = await handleRequest(
    new Request("https://example.test/api/v1/agent/respond", {
      method: "POST",
      body: JSON.stringify({ messages: [{ role: "user", content: "hi" }] }),
    }),
    {
      AI: {
        run: async () => ({ response: "hello" }),
      },
    },
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.response, "hello");
  assert.equal(body.provider, "workers_ai");
});

test("extracts OpenAI-compatible text", () => {
  assert.equal(
    extractText({ choices: [{ message: { content: "ok" } }] }),
    "ok",
  );
});
