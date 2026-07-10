# PIE Mobile

Flutter client for the Personal Intelligence Engine. The app ingests local files
and selected Android notifications into an on-device knowledge graph, then uses
local retrieval to support a conversational agent.

## Development

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

## Runtime Configuration

The app does not ship cloud credentials in source. Configure environment-specific
values with `--dart-define`:

```powershell
flutter run `
  --dart-define=PIE_GATEWAY_URL=https://your-gateway.example.com/api/v1 `
  --dart-define=PIE_DEVICE_ID=android-device-id
```

Optional values:

- `PIE_GATEWAY_BEARER_TOKEN`: development-only bearer token fallback. Prefer
  storing a user session token in `flutter_secure_storage` under
  `gateway_access_token`.
- `PIE_OLLAMA_URL`: local Ollama generate endpoint when direct local inference is
  enabled.
- `PIE_AZURE_OPENAI_CHAT_ENDPOINT` and `PIE_AZURE_OPENAI_API_KEY`: supported for
  local development only. Production mobile builds should call a backend gateway
  instead of embedding provider keys in the app.
- `PIE_MAX_ATTACHMENT_BYTES`: maximum file size accepted for chat attachments
  and connector imports. Defaults to 10 MB.
- `PIE_MAX_EXTRACTED_TEXT_CHARS`: maximum extracted text retained from a single
  imported file. Defaults to 120,000 characters.
- `PIE_MAX_RAG_CONTEXT_CHARS`: maximum retrieved local context included in an
  agent request. Defaults to 24,000 characters.
- `PIE_MAX_INGEST_CHUNKS`: maximum chunks created from one connector import.
  Defaults to 500.

## Android Release Signing

Local release builds fall back to debug signing for developer convenience. CI
builds require `android/key.properties` so a production artifact cannot be
created unsigned or debug-signed by accident:

```properties
storePassword=...
keyPassword=...
keyAlias=...
storeFile=/absolute/path/to/upload-keystore.jks
```

## Production Notes

- Android notification listener access is highly sensitive. Keep the permission
  flow explicit and collect only allowlisted notification sources.
- Local graph storage uses SQLCipher via `sqflite_sqlcipher`. A one-time
  migration copies existing plaintext development data from
  `pie_local_secure_v2.db` into `pie_local_encrypted_v3.db`.
- Sync payloads use `pie-sync-v1`: P-256 ECDH, HKDF-SHA256 key derivation, and
  AES-256-GCM content encryption. Peer devices must publish P-256 public keys as
  JWK-style JSON with `kty`, `crv`, `x`, and `y` fields.
- Do not commit generated build output, JVM crash logs, heap dumps, signing keys,
  or local SDK configuration.
