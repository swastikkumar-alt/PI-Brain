# PI Brain

PI Brain is a privacy-first mobile intelligence system. The Android app keeps
personal data on the phone, builds a local encrypted knowledge graph, answers
grounded questions from local evidence, and uses a small Cloudflare Worker only
as the model/image gateway boundary.

## Repository Layout

```text
.
|-- mobile/                         # PIE Flutter Android app
|-- backend/cloudflare-gateway/      # Cloudflare Worker LLM/image gateway
|-- whatsapp_contact_exporter/       # Separate WA group contact exporter app
|-- docs/                            # Architecture, OpenAPI and schema notes
|-- .gitattributes                   # Line-ending and binary-file handling
`-- .gitignore                       # Generated files, local captures, secrets
```

## Current Capabilities

- Local encrypted storage with SQLCipher-backed entities, messages, sync
  events, action audits, contact profiles and financial transaction ledger.
- Grounded chat routing for spend, orders/packages, messages, emails, calls,
  health summaries and spam review before generic LLM wording.
- Spend answers from a deduped transaction ledger, with evidence citations and
  collapsed evidence UI.
- Android local connectors for SMS import, call logs, Health Connect summaries,
  notification context, contacts, speech recognition, TTS, WhatsApp automation
  and email compose.
- Image prompts use the backend image endpoint when configured. If not
  configured, PIE shows a device handoff flow for installed Gemini/ChatGPT apps.
- Cloudflare Worker gateway for LLM responses, sync push endpoint and optional
  image generation provider.
- Separate WhatsApp contact exporter app for user-approved local export flows.

## Privacy And Safety Rules

- Phone data stays local by default. SMS, payment/order messages, call logs and
  health records are not uploaded during automatic local refresh.
- Sensitive app actions require user approval inside PIE.
- WhatsApp send automation verifies the target UI/message before sending.
- PIE does not store app-lock PINs, silently bypass locked apps, scrape private
  app databases, or read other apps' private conversations.
- Real SMS deletion/blocking is available only through Android-supported SMS
  role/default-handler capability. Otherwise PIE shows a blocked/review state.
- Notification access only sees future delivered notifications after the user
  enables the listener. It cannot backfill historical Gmail/WhatsApp/app
  notifications.

## Development Prerequisites

- Flutter stable with Android tooling configured.
- Android SDK and a connected Android device for mobile smoke tests.
- Node.js 20+ for the Cloudflare Worker.
- Wrangler CLI, installed through `npm install` inside
  `backend/cloudflare-gateway`.
- Optional: Cloudflare account with Workers AI binding or external LLM/image
  provider credentials.

## Mobile Setup

```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Run with a deployed gateway:

```powershell
flutter run `
  --dart-define=PIE_GATEWAY_URL=https://<worker-url>/api/v1 `
  --dart-define=PIE_DEVICE_ID=<device-id>
```

Optional mobile defines:

- `PIE_GATEWAY_BEARER_TOKEN`: development fallback token. Prefer runtime
  secure-storage configuration through the app settings.
- `PIE_OLLAMA_URL`: local Ollama endpoint when direct local inference is used.
- `PIE_AZURE_OPENAI_CHAT_ENDPOINT` / `PIE_AZURE_OPENAI_API_KEY`: development
  only; production mobile builds should call the backend gateway.
- `PIE_MAX_ATTACHMENT_BYTES`, `PIE_MAX_EXTRACTED_TEXT_CHARS`,
  `PIE_MAX_RAG_CONTEXT_CHARS`, `PIE_MAX_INGEST_CHUNKS`: ingestion limits.

## Backend Setup And Deployment

```powershell
cd backend/cloudflare-gateway
npm install
npm test
npx wrangler login
npx wrangler secret put PIE_GATEWAY_BEARER_TOKEN
npm run deploy
```

Optional LLM/image secrets:

```powershell
npx wrangler secret put LLM_API_KEY
npx wrangler secret put LLM_ENDPOINT
npx wrangler secret put GEMINI_API_KEY
```

If Workers AI is enabled, the `AI` binding in `wrangler.toml` is used
automatically. For non-Gemini image providers, configure `IMAGE_ENDPOINT` and
optionally `IMAGE_API_KEY`; the endpoint must return either `image_url` or
`image_base64`.

## Local Intelligence Refresh Model

- App start/resume refreshes enabled local sources if stale.
- Relevant local questions trigger a pre-answer refresh for needed sources.
- While PIE is alive, a 4-hour foreground scheduler refreshes enabled local
  sources.
- WorkManager registers a best-effort 4-hour background maintenance task for
  ledger/index repair. Native SMS/call/health imports catch up on app
  start/resume or before answering because the current native data bridge is
  Activity-scoped.
- Per-source freshness state tracks last success, native cursor, imported count,
  duplicate count, last error and next scheduled refresh.

## Android Permissions

PIE asks for permissions only when the related feature is used:

- `RECORD_AUDIO`: push-to-talk command recognition.
- `READ_CONTACTS`: contact resolution and aliases.
- `READ_SMS`: local SMS import and spend/order/spam evidence.
- `READ_CALL_LOG`: missed/unanswered call summaries.
- `android.permission.health.READ_STEPS` and `READ_SLEEP`: Health Connect
  summaries.
- Notification listener: Gmail/WhatsApp/payment/order notification context.
- Accessibility service: user-approved WhatsApp execution and verification.

## Testing Checklist

```powershell
# Mobile
cd mobile
flutter analyze
flutter test
flutter build apk --debug

# Backend
cd ..\backend\cloudflare-gateway
npm test
```

Connected-device smoke tests:

```powershell
adb devices
adb install -r mobile\build\app\outputs\flutter-apk\app-debug.apk
adb shell monkey -p com.personalintelligence.pie -c android.intent.category.LAUNCHER 1
```

Manual QA questions after enabling SMS/notifications:

- `how much did I spend today`
- `how much did I spend on 8th July`
- `how much did I spend this month`
- `did I get any Amazon orders in last 48 hours`
- `how many messages did I receive yesterday`
- `did I get any important emails today`
- `missed calls from yesterday`
- `did I get spam messages today`

Use Settings -> Local QA Report for a redacted diagnostic pass.

## GitHub Hygiene

- Do not commit generated build output, APK/AAB files, heap dumps, signing keys,
  `.env` files, Wrangler local state, `node_modules`, device screenshots, XML
  dumps or local exports.
- Root `.gitignore` already excludes common Flutter, Android, Node,
  Cloudflare, signing and local QA artifacts.
- Root `.gitattributes` keeps source files normalized and binary artifacts out
  of text diffs.
- Keep backend secrets in Cloudflare Wrangler secrets, not in source.
- Keep Android release signing material outside the repository and provide
  `mobile/android/key.properties` only locally or in CI secret storage.

## Known Constraints

- Full Gmail mailbox access requires Gmail API OAuth and explicit scopes.
  Notification access only captures delivered notification summaries.
- Installed Gemini/ChatGPT handoff cannot return generated images to PIE
  automatically; Android keeps those apps' conversations private.
- Android background execution is best-effort and can be delayed by battery
  optimization, Doze, OEM restrictions or the app being force-stopped.
- Play Store distribution of Accessibility-driven cross-app control requires a
  separate policy/legal review.
