# N07 3.3.6 RC6 review

Review candidate only. Stable/main remains unchanged until exact Windows UAT and explicit approval.

RC6 is the high-fidelity UI refinement requested after RC5 visual review. Generic Unicode/glyph-style product icons were replaced with dedicated SVG iconography across Dashboard, Search, Inventory, History, Queue, Excel, ADMIN and the top bar. Viettel branding, typography, card/table/button/badge spacing were refined against the supplied reference screenshots. The author explicitly accepts a 20–30 MB client if future local assets require it; visual fidelity now has priority over saving a few MB.

Core behavior is retained: background Supabase sync minimum/default 300 seconds; manual sync, operation sync and resume/network-return sync remain immediate. RC3 Windows BOM/startup hardening and intentional 3.3.6 system metrics remain. Dynamic vehicle/PIN-type mutations and destructive archive/delete remain gated pending real backend/verification/UAT.

Main Windows x64 SHA-256: `42802015f16be5516022ee76c9d02ed23178569944bf7cc7825b5dd63f5740fc`
Updater SHA-256: `d9f8d1b7da255587dd00a060f0ef50478fbe70219de25e081bdf0ae6b2bf3dcb`
AUTHOR COMPLETE ZIP SHA-256: `0da3c540cec86765e99d6711545d3ef97ba6f1b820a24935b08365bec326661b`

Final automated review PASS: go test/vet/race, security, SQL/migration, Edge, QR, code-health, RC6 requirements, UI smoke, UI performance, reproducible Windows builds, and extracted package verification with 213/213 manifest entries matching.
