# N07 HUBDNI 3.3.5-reviewed

Ngày khóa release candidate: 22/08/2026.

## Thay đổi chính

- Chuyển auto-update sang **Managed Stable release channel**.
- Manifest URL được pin trong code, người dùng/ADMIN không còn nhập URL update.
- Config cũ chứa URL/channel khác sẽ tự normalize về nguồn Stable chuẩn.
- Giữ updater helper tách riêng, không kéo GitHub SDK/framework vào main app.
- Giữ kiểm HTTPS + exact size + SHA-256 + queue safety + health-check + rollback hardened.
- Không đổi business schema/API. Supabase production tiếp tục API 4 / build `3.3.3-reviewed` / Edge version 5.
- Bổ sung continuity/handover governance để người kế nhiệm đọc được source + GitHub + Supabase state như tác giả dự án.

## SHA-256

Main `N07_HUBDNI_WINDOWS_B3.exe`:
`31fe17cea7b50ffd447aa13474a26791e3668edc1ad6a34ff171768e0464d4ac`

Updater `N07Updater.exe`:
`d9f8d1b7da255587dd00a060f0ef50478fbe70219de25e081bdf0ae6b2bf3dcb`

## Trạng thái phát hành

Release metadata đã được tạo trước. `stable/n07-update.json` chỉ được publish sau khi Main EXE thật đã có tại đường dẫn bất biến và được tải ngược để xác minh hash/size.
