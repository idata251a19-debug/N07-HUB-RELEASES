# N07 3.3.6 RC5 review

Review candidate only. Stable/main remains unchanged.

RC5 refines the real Windows client to closely follow the supplied Viettel red/dark reference form while remaining lightweight: native HTML/CSS/JS, inline SVG icons, no React/Vue/Angular, no chart framework, no font/UI CDN, and duplicate old presentation is removed rather than layered underneath.

Reference-form coverage: Dashboard, Search, Inventory, History, Audit, Excel, Queue, ADMIN and Settings. Vehicle/PIN-type management shell is prepared visually, but write controls remain disabled until a real backend catalog migration/API/client contract exists.

Remote background Supabase sync remains minimum/default 300 seconds; manual sync, online operations and resume sync remain immediate. Destructive archive/delete remains disabled pending verified local + Google Drive copies and restore UAT.

Windows x64 main SHA-256: `2e710452397e76d3d392672701fe9709196531aa364cbe95370443360456b208`
Updater SHA-256: `d9f8d1b7da255587dd00a060f0ef50478fbe70219de25e081bdf0ae6b2bf3dcb`

Automated Go/race/security/SQL/Edge/QR/UI/performance/package verification passes. Exact Windows visual/UAT is still required before promotion.