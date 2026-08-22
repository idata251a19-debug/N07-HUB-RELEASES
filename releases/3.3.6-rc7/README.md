# N07 3.3.6 RC7 review

Review candidate only. Stable/main remains unchanged until exact Windows UAT and explicit approval.

RC7 is the strict visual-fidelity correction after RC6 review. The real N07 Windows client now uses a local embedded reference-derived Viettel wordmark and reference-derived motorcycle/car masks instead of generic font imitation or hand-drawn vehicle glyphs. The same vehicle assets are reused across topbar switches and vehicle KPI/type/capacity contexts. Classic Segoe UI is the primary Windows font, and semantic icons/badges were reviewed again across Dashboard, Search, Inventory, History, Audit, Excel, Queue and ADMIN.

Core behavior is unchanged: background Supabase sync minimum/default 300 seconds; manual/operation/resume/network-return sync immediate. RC3 startup/BOM hardening and intentional system metrics remain. Dynamic vehicle/PIN-type writes and destructive archive/delete remain gated.

Main Windows x64 SHA-256: `cc8d9f35707f2a960f85d6057c1508f98fc8be24fc5ef1fd230843ce741af19a`
Updater SHA-256: `d9f8d1b7da255587dd00a060f0ef50478fbe70219de25e081bdf0ae6b2bf3dcb`
AUTHOR COMPLETE ZIP SHA-256: `c3c1b1a411b822e21644e48f77bbf14f7211be96b49442a47fad5ddaa452c60e`

Final automated review PASS: go test/vet/race, security, SQL/migration, Edge, QR, code-health, strict RC7 visual checker 18/18, UI smoke with zero JS console errors, UI performance, two independent byte-identical Windows builds, staging package verification and extracted ZIP verification with 237/237 manifest entries matching. Exact Windows visual/UAT remains required before promotion.