# N07 HUBDNI B3 3.3.6 RC1

Status: **REVIEW CANDIDATE — NOT STABLE**

Implemented in RC1:
- Background sync default changed to 300 seconds (5 minutes); manual `Đồng bộ ngay` remains immediate; online IMPORT/EXPORT remains immediate.
- Background sync skips warehouses the user cannot access.
- Intentional production `n07-system-metrics` drift is reconciled into authoritative source.
- ADMIN resource UI shows PostgreSQL database size, N07 user/activity counts and per-table sizes; it does not fake Supabase billing Egress.
- UI review changes: `Quản lý kho`, dashboard metrics split by motorcycle/car, QR tools removed from sidebar but retained as dashboard quick actions, Search simplified and Search Session removed, `Xuất Excel` exports the filtered search result.
- Archive policy documented: rolling 6 months plus safety trigger at 400 MB.

Safety gate: destructive auto-archive/delete is **not enabled in production in RC1** until local + Google Drive dual verification, restore UAT, archive catalog, and single-job locking are implemented and passed.

Production Supabase remains on the current ACTIVE metrics migration/function. Stable release metadata is unchanged until Windows UAT approval.
