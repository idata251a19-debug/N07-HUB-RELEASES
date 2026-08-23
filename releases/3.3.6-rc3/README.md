# N07 3.3.6 RC3 review candidate

RC3 fixes the Windows startup failure caused by an existing `%APPDATA%\N07HubGo\config.json` saved as UTF-8 with BOM (`invalid character 'ï' looking for beginning of value`). The config loader now accepts BOM, rewrites canonical BOM-free JSON, and enforces the 300-second minimum background sync.

Main EXE SHA-256: `2b14786ed5bf25de102a9fe4249bf92476102eb93982d9c0823f07beebb0f9d0`

Status: review candidate only. `main` / Stable are intentionally unchanged. Archive delete remains gated pending dual local + Google Drive verification and restore UAT.
