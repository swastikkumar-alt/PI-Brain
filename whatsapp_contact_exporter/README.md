# PIE WhatsApp Contact Exporter

Separate Flutter Android app for user-approved WhatsApp group/contact export
workflows. This app is independent from PIE Mobile and is intended for the
owner's own device/session only.

## What It Does

- Imports local Android contacts with user permission.
- Provides WhatsApp Web and Android capture workflows for group/member review.
- Lets the user review captured group/member data before saving.
- Exports CSV, XLSX, JSON and vCard files.
- Supports admin/member filters and deduped global export modes.

## Safety Rules

- No hidden harvesting.
- No cross-account extraction.
- No bypassing WhatsApp privacy controls.
- No silent background sync into PIE.
- If phone numbers are not visible, the app stores visible names/IDs only and
  marks confidence accordingly.

## Development

```powershell
cd whatsapp_contact_exporter
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

## Android Notes

- Package: `com.personalintelligence.whatsappexporter`
- App label: `PIE WhatsApp Exporter`
- Web extraction uses a WebView-based WhatsApp Web session.
- Android capture uses explicit user review and Accessibility-style visible
  screen capture flows where applicable.

## Exports

Generated files are local user data and should not be committed. The root
`.gitignore` excludes common screenshots, XML dumps, APKs and local export
artifacts.
