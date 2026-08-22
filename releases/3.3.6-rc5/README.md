# N07 3.3.6 RC5 review

Review candidate only. Stable/main remains unchanged until exact Windows UAT and explicit approval.

RC5 refines the real N07 Windows client UI to closely follow the user-provided Viettel red/dark reference form while keeping the client lightweight: native HTML/CSS/JS only, one authoritative stylesheet, no React/Vue/Angular, no chart engine, no font/UI CDN, and obsolete pre-RC5 embedded UI backup files removed.

Key retained behavior: background Supabase sync minimum/default 300 seconds; manual sync, operation sync and resume sync remain immediate. RC3 Windows BOM/startup hardening remains. Intentional 3.3.6 system metrics remain reconciled. Rolling 6-month / early ~400 MB archive policy remains documented, but destructive archive/delete is still disabled pending verified local + Google Drive copies and restore UAT.

Vehicle/PIN-type catalog controls are visually prepared to match the target form but write actions remain disabled until an authoritative backend catalog exists.

Main Windows x64 SHA-256: `73d839444963a6cd4a5a5c19bd6e6de90d60025ea430fe05ecf70c52dd45096a`
Updater SHA-256: `d9f8d1b7da255587dd00a060f0ef50478fbe70219de25e081bdf0ae6b2bf3dcb`
AUTHOR COMPLETE ZIP SHA-256: `e0f5064ba557270a4dbac09ea46d156119902f5f787b402437b303f3951923d1`

Automated final review: go test/vet/race, security, SQL/migration structure, Edge typecheck, QR smoke, code health, RC5 requirements, UI smoke and UI performance PASS. Source, frozen staging copy, and extracted package verifier all PASS with 205/205 manifest entries matching.
