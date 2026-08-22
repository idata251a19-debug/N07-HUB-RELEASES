# N07 HUB RELEASES

Kho phát hành công khai cho cơ chế tự cập nhật N07 HUBDNI.

## Mục đích duy nhất

Repo này chỉ chứa **artifact phát hành** và **manifest cập nhật**. Đây **không phải** source repository và **không phải** nơi lưu secret, database dump hay bộ MASTER handoff.

## Cấu trúc chuẩn

```text
stable/
  n07-update.json
releases/
  <version>/
    N07_HUBDNI_WINDOWS_B3.exe
    N07Updater.exe
    RELEASE_NOTES.md
    SHA256SUMS.txt
    RELEASE_METADATA.json   # khi có
```

## Quy tắc phát hành bắt buộc

1. Mỗi version có folder riêng dưới `releases/<version>/` và **không ghi đè binary đã phát hành**.
2. Binary phải có exact byte size + SHA-256 đã đối chiếu với artifact build authoritative.
3. Upload/move artifact trước, verify trước, rồi mới cắt `stable/n07-update.json`.
4. URL binary trong manifest Stable phải pin tới **Git commit SHA chứa artifact**, không trỏ `main`, để byte của release là bất biến thật.
5. N07 chỉ tải qua HTTPS, kiểm exact size + SHA-256 trước khi thay EXE, sau đó health-check và rollback nếu bản mới lỗi.
6. Không commit service-role key, password, Google secret, Supabase secret, source ZIP hay MASTER handoff vào repo này.
7. Lịch sử quyết định, trạng thái production, QA/UAT và provenance nằm trong MASTER handoff của dự án N07.
8. `stable/n07-update.json` là pointer duy nhất được phép thay đổi để chuyển Stable sang version khác.

## Kênh stable

Manifest cố định mà app đọc:

`https://raw.githubusercontent.com/idata251a19-debug/N07-HUB-RELEASES/main/stable/n07-update.json`

Ví dụ artifact production **đúng chuẩn commit-pinned**:

`https://raw.githubusercontent.com/idata251a19-debug/N07-HUB-RELEASES/<ARTIFACT_COMMIT>/releases/3.3.5/N07_HUBDNI_WINDOWS_B3.exe`

Không dùng `.../main/releases/<version>/...` trong manifest Stable production.

## Rollback

- Rollback cục bộ: `N07Updater.exe` restore backup nếu health-check fail.
- Rollback Stable toàn hệ thống: đổi `stable/n07-update.json` về artifact commit/version đã được kiểm chứng.
- Không xóa artifact version cũ đã từng được Stable trỏ tới.

## Giới hạn hiện tại

Manifest schema 1 của 3.3.5 quản lý **Main EXE**. `N07Updater.exe` đi cùng release nhưng 3.3.5 chưa tự rotate helper này qua manifest. Main release kế tiếp nên bổ sung helper-rotation trước khi cần thay updater production.

---

N07 release-channel governance. Repo này là distribution plane, không phải source-of-truth của code hay dữ liệu nghiệp vụ.
