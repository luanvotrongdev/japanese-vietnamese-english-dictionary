# javi: Từ điển Nhật → Việt cho Kobo và Yomitan

**Tiếng Việt** | [English](README.en.md)

Công cụ này tạo từ điển Nhật → Việt (kèm tiếng Anh) từ danh sách từ của JMdict, lấy nghĩa tiếng Việt từ **Mazii** và nghĩa tiếng Anh từ **Jisho**, rồi xuất ra:

- từ điển **Kobo** (`dicthtml-ja.zip`), để tra từ khi đọc sách tiếng Nhật trên máy đọc sách Kobo
- từ điển **Yomitan** (`lulujv.zip`), để tra từ bằng cửa sổ bật lên trên trình duyệt

Mọi bước đều chạy trong một chương trình Zig duy nhất, `javi-transform`, không cần cài thêm công cụ nào khác.

> Đây là dự án cá nhân làm cho vui, để đọc sách tiếng Nhật với nghĩa tiếng Việt. Bạn tự chịu rủi ro khi sử dụng.

## Một mục từ trông như thế nào

```
食べる 【たべる】 [2]  N5 · thông dụng
Cách viết khác: 喰べる
Động từ nhóm 2 · tha động từ
 1. ăn
    食べるほど食欲がでる。
    Tôi càng ăn nhiều thì sự thèm ăn của tôi càng lớn.
English
 1. Ichidan verb, Transitive verb
    to eat
 2. to live on (e.g. a salary); to live off; to subsist on
```

Khi tra một chữ Hán đơn lẻ, bạn còn thấy thẻ chữ Hán: âm Hán Việt, giải nghĩa tiếng Việt, âm On/Kun, bộ thủ, thành phần, mẹo nhớ và từ ví dụ.

Bạn có thể tra một từ bằng bất kỳ cách viết chữ Hán nào của nó, bằng cách đọc hiragana hoặc dạng katakana.

## Không kèm dữ liệu từ điển

Kho mã này không chứa dữ liệu từ điển. Nghĩa tiếng Việt và tiếng Anh lấy từ Mazii và Jisho; nội dung đó thuộc về họ nên không thể phát hành lại. Bạn tự tạo bản của mình theo các bước bên dưới: nhập JMdict, thu thập dữ liệu từ Mazii và Jisho, tạo cơ sở dữ liệu, rồi xuất từ điển.

## Yêu cầu

- [Zig](https://ziglang.org/download/) đúng phiên bản **0.16.0** (thư viện chuẩn của Zig thay đổi giữa các phiên bản)
- Kết nối Internet cho các bước đầu: tải JMdict và thu thập dữ liệu từ Mazii và Jisho
- Với Kobo: firmware **4.24.15672 trở lên**, hỗ trợ từ điển tùy chỉnh mà không cần vá

## Cách dùng

### 1. Biên dịch chương trình

```bash
zig build -Doptimize=ReleaseFast
```

Chương trình nằm ở `zig-out/bin/javi-transform` (trên Windows là `javi-transform.exe`).

### 2. Nhập JMdict

```bash
zig-out/bin/javi-transform jmdict jmdict-cache.sqlite
```

Lệnh này tải JMdict (`JMdict_e_examp.gz`, khoảng 13 MB, từ máy chủ của EDRDG) và lưu cách viết và cách đọc của mọi mục từ vào `jmdict-cache.sqlite`, tệp bộ nhớ đệm mà các bước sau dùng. Nếu tệp chưa có, lệnh sẽ tạo mới.

Bạn có thể chạy lại bất cứ lúc nào để cập nhật JMdict mới hơn. Các mục từ đã có vẫn giữ dữ liệu đã thu thập, chỉ những từ mới hoặc đã thay đổi mới cần thu thập lại. Những từ JMdict đã xóa sẽ được báo lại; thêm `--prune` để xóa chúng cùng dữ liệu đã thu thập. Nếu bạn đã có sẵn tệp JMdict, dùng `--file JMdict_e_examp.gz` (tệp `.gz` hoặc `.xml`).

### 3. Thu thập dữ liệu từ Mazii và Jisho

```bash
zig-out/bin/javi-transform crawl jmdict-cache.sqlite --dry-run
```

```bash
zig-out/bin/javi-transform crawl jmdict-cache.sqlite
```

Bước này lấy nghĩa tiếng Việt và tiếng Anh cho mọi từ và chữ Hán. `--dry-run` chỉ đếm số mục từ và chữ Hán chưa có dữ liệu Mazii/Jisho. Khi bỏ tùy chọn đó, chương trình sẽ tải dữ liệu và lưu từng mục vào bộ nhớ đệm ngay khi tải xong. Bạn có thể dừng bất cứ lúc nào bằng Ctrl+C; chạy lại sẽ tiếp tục từ chỗ đã dừng. Chương trình chờ 0,5–1,5 giây giữa các yêu cầu. Xin đừng giảm thời gian chờ: hãy nhẹ tay với Mazii và Jisho. Thu thập toàn bộ mất nhiều giờ. Tùy chọn: `--limit N`, `--min-sleep MS`, `--max-sleep MS`.

### 4. Tạo cơ sở dữ liệu từ điển

```bash
zig-out/bin/javi-transform build jmdict-cache.sqlite javi.sqlite
```

Bước này chuyển dữ liệu thô đã thu thập thành một cơ sở dữ liệu gọn gàng, `javi.sqlite` (khoảng một phút). Cả hai lệnh xuất đều đọc từ tệp này.

### 5a. Xuất từ điển Kobo

```bash
zig-out/bin/javi-transform kobo javi.sqlite dicthtml-ja.zip
```

Cách cài đặt:

1. Kết nối Kobo với máy tính.
2. Chép `dicthtml-ja.zip` vào `KOBOeReader/.kobo/custom-dict/`. Tạo thư mục nếu chưa có; `.kobo` là thư mục ẩn.
3. Ngắt kết nối (eject) Kobo.
4. Trong sách, nhấn giữ một từ, rồi chọn **日本語 (Custom)** trong cửa sổ từ điển.

**Nếu bị mất chữ tiếng Việt** (ví dụ "CHIẾN" hiện thành "CHIN"), nghĩa là Kobo đang hiển thị từ điển bằng phông Georgia có sẵn, vốn thiếu các chữ như ư ơ ạ ế ự. Các mục từ có yêu cầu một phông có đủ chữ (Kobo Nickel), nhưng một số máy Kobo bỏ qua yêu cầu này. Hãy cài bản sửa phông tiếng Việt của **[lelinhtinh/kobo-tieng-viet](https://github.com/lelinhtinh/kobo-tieng-viet)**. Bản sửa thay phông Georgia và Avenir Next của Kobo bằng phiên bản hỗ trợ tiếng Việt, giúp hiển thị đúng cả từ điển lẫn chữ tiếng Việt ở mọi nơi khác trên máy. Tóm tắt: tải `KoboRoot.tgz` từ bản phát hành mới nhất của dự án, chép vào `KOBOeReader/.kobo/`, rồi ngắt kết nối; Kobo sẽ tự cài và khởi động lại. Hãy làm theo README của dự án đó để có hướng dẫn mới nhất. Bản sửa thay đổi tệp hệ thống, và cập nhật firmware có thể xóa mất nó.

### 5b. Xuất từ điển Yomitan

```bash
zig-out/bin/javi-transform yomitan javi.sqlite lulujv.zip
```

Trong Yomitan, mở **Settings → Dictionaries → Import** và chọn `lulujv.zip`. Bạn sẽ có:

- nhãn từ loại, các nghĩa tiếng Việt được đánh số kèm câu ví dụ, và một phần tiếng Anh riêng
- biểu đồ trọng âm (pitch accent)
- nhãn **★** (từ thông dụng) và cấp độ **JLPT**
- mọi cách viết của một từ được gộp vào một kết quả
- tra được cả dạng đã chia (食べた → 食べる)
- thẻ chữ Hán với âm Hán Việt, giải nghĩa và bảng thông tin

Mỗi phần của mục từ có thuộc tính `data-sc-content` (`vietnamese`, `english`, `example`, `word-types`, `section-label`), nên bạn có thể đổi giao diện bằng CSS tùy chỉnh của Yomitan.

## Tất cả các lệnh

| Lệnh | Chức năng |
| --- | --- |
| `jmdict <cache.sqlite> [--file PATH] [--url URL] [--prune]` | Tải JMdict và nhập cách viết, cách đọc vào bộ nhớ đệm (tạo mới nếu chưa có) |
| `crawl <cache.sqlite> [--dry-run] [--limit N] [--min-sleep MS] [--max-sleep MS]` | Lấy dữ liệu Mazii/Jisho cho các mục từ và chữ Hán chưa có |
| `check <cache.sqlite>` | Kiểm tra mọi phản hồi đã thu thập có đọc được không, và báo những mục bị lỗi |
| `build <cache.sqlite> <javi.sqlite>` | Tạo cơ sở dữ liệu từ điển gọn gàng |
| `kobo <javi.sqlite> <dicthtml-ja.zip>` | Xuất từ điển Kobo |
| `yomitan <javi.sqlite> <lulujv.zip>` | Xuất từ điển Yomitan |

Chạy kiểm thử bằng `zig build test`. `docs/schema.md` mô tả cơ sở dữ liệu, còn `docs/known-issues.md` liệt kê các lỗi dữ liệu đã biết (cả hai bằng tiếng Anh).

## Ghi công

- **[Mazii](https://mazii.net)**, từ điển Nhật–Việt: toàn bộ nghĩa tiếng Việt, câu ví dụ, trọng âm và thông tin chữ Hán (âm Hán Việt, giải nghĩa, thành phần, mẹo nhớ).
- **[Jisho](https://jisho.org)**, từ điển Nhật–Anh: nghĩa tiếng Anh, từ loại, cấp độ JLPT, nhãn từ thông dụng, cùng cách đọc, bộ thủ và số nét của chữ Hán.
- **[lelinhtinh/kobo-tieng-viet](https://github.com/lelinhtinh/kobo-tieng-viet)** của lelinhtinh: bản sửa phông chữ giúp hiển thị tiếng Việt trên Kobo.
- [JMdict](https://www.edrdg.org/jmdict/edict.html) của Electronic Dictionary Research and Development Group: danh sách từ (mục từ, cách viết và cách đọc), theo [giấy phép EDRDG](https://www.edrdg.org/edrdg/licence.html).
- [cessen/kobo_jp_dict](https://github.com/cessen/kobo_jp_dict), đã chỉ ra cách Kobo tra từ tiếng Nhật; [pgaskin/dictutil](https://github.com/pgaskin/dictutil), đã ghi lại định dạng từ điển của Kobo; và [marisa-trie](https://github.com/s-yata/marisa-trie) của Susumu Yata, định dạng trie mà Kobo dùng cho chỉ mục từ (được chuyển sang Zig trong dự án này).
- Viết bởi Vo Trong Luan, với sự hỗ trợ của [Claude Code](https://claude.com/claude-code).

Mazii và Jisho không liên quan đến dự án này. Nội dung của họ thuộc về họ, và dữ liệu JMdict theo giấy phép EDRDG.
