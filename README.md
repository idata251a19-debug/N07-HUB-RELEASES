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
    N07Updater.exe        # chỉ khi updater thay đổi
    RELEASE_NOTES.md
    SHA256SUMS.txt
```

## Quy tắc phát hành

1. Mỗi version dùng đường dẫn bất biến dưới `releases/<version>/`.
2. Không ghi đè binary của version đã phát hành.
3. Binary phải có SHA-256 và byte size được ghi trong manifest.
4. `stable/n07-update.json` chỉ được cập nhật **sau khi** artifact version mới đã tồn tại và đã được xác minh.
5. N07 chỉ tải qua HTTPS, kiểm byte size + SHA-256 trước khi thay EXE.
6. Không được commit service-role key, password, Google secret, Supabase secret, source ZIP hay MASTER handoff vào repo này.
7. Lịch sử quyết định, trạng thái production và provenance nằm trong bộ bàn giao kỹ thuật của dự án N07, không nằm ở release repo này.

## Kênh stable

Manifest cố định mà app đọc:

`https://raw.githubusercontent.com/idata251a19-debug/N07-HUB-RELEASES/main/stable/n07-update.json`

Binary mỗi bản dùng URL bất biến, ví dụ:

`https://raw.githubusercontent.com/idata251a19-debug/N07-HUB-RELEASES/main/releases/3.3.5/N07_HUBDNI_WINDOWS_B3.exe`

## Rollback

Nếu bản mới không health-check được, `N07Updater.exe` tự restore file backup cục bộ. Nếu cần rollback toàn hệ thống, chỉ đổi manifest stable về một version đã được kiểm chứng và vẫn còn artifact bất biến trong `releases/`.

---

N07 release-channel governance. Không xóa lịch sử version đã phát hành.
