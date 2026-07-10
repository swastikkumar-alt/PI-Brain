# PIE Cloudflare LLM Gateway

This Worker is the production boundary for model inference only. The mobile app
keeps user data, connector data, profiles, reminders, and local retrieval on the
phone. The gateway accepts a bounded prompt/context payload and returns an LLM
response without storing user content.

## Local Test

```powershell
npm install
npm test
npm run dev
```

## Deploy

```powershell
npm install
npx wrangler login
npx wrangler secret put PIE_GATEWAY_BEARER_TOKEN
npm run deploy
```

Optional external LLM configuration:

```powershell
npx wrangler secret put LLM_API_KEY
npx wrangler secret put LLM_ENDPOINT
```

Optional image-generation configuration:

```powershell
npx wrangler secret put GEMINI_API_KEY
```

`GEMINI_IMAGE_MODEL` defaults to `gemini-2.5-flash-image`. For a non-Gemini
provider, set `IMAGE_ENDPOINT` and optionally `IMAGE_API_KEY`; the endpoint must
return `image_url` or `image_base64`.

If Workers AI is enabled in your Cloudflare account, the `AI` binding in
`wrangler.toml` is used automatically. The default model is configured in
`LLM_MODEL`.

Mobile build example:

```powershell
flutter build apk --release `
  --dart-define=PIE_GATEWAY_URL=https://pie-llm-gateway.<account>.workers.dev/api/v1
```
