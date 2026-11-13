# Meet for Me: hướng dẫn sử dụng (tiếng Việt)

*[English version](README.md)*

**Meet for Me** nghe cuộc họp Zoom ngay trên máy Mac của bạn và chuyển lời nói thành văn bản
(transcript) ngay trên máy. Khi có người gọi tên và hỏi bạn, app hiện thông báo trên màn hình
kèm **câu trả lời gợi ý**, dựa trên nội dung cuộc họp và ghi chú của bạn. Bạn cũng có thể
**chat** để hỏi lại mọi chuyện đã diễn ra trong cuộc họp.

```
Zoom → BlackHole → Whisper (chạy trên máy) → nhận diện tên bạn → Claude → thông báo trên Mac
```

- **Miễn phí:** không tốn thêm chi phí. Câu trả lời dùng tài khoản Claude Code bạn đang có
  (lệnh `claude`). Muốn chạy hoàn toàn offline thì dùng Ollama (xem bên dưới).
- **Riêng tư:** âm thanh được chuyển thành chữ ngay trên máy. Chỉ phần transcript liên quan
  được gửi cho Claude khi cần soạn câu trả lời hoặc khi bạn chat.

> ⚠️ **Lưu ý:** việc ghi lại và chuyển lời người khác thành văn bản có thể cần sự đồng ý của
> họ, tuỳ quy định công ty và pháp luật. Hãy báo cho mọi người trong cuộc họp khi dùng app.

---

## 1. Yêu cầu

- Máy Mac chip Apple Silicon (M1/M2/M3/M4…).
- Python 3.9 trở lên. Máy đã cài Command Line Tools là có sẵn.
- Claude Code CLI (`claude`) đã đăng nhập.
- Homebrew, để cài BlackHole.

## 2. Cài đặt

Mở Terminal và chạy:

```bash
git clone https://github.com/hieudao0296-gif/meet-for-me.git ~/Documents/zoom-listener
cd ~/Documents/zoom-listener
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
app/build.sh
```

Lệnh cuối tạo ứng dụng **`app/build/Meet for Me.app`**. Bạn có thể kéo nó vào thư mục
Applications. App vẫn chạy phần lõi từ thư mục `~/Documents/zoom-listener`, nên **đừng
di chuyển hay xoá thư mục này**.

Lần chạy đầu, app tải model Whisper (khoảng 1,6 GB) nên sẽ hơi lâu.

## 3. Thiết lập âm thanh (chỉ làm một lần)

App cần "nghe" được âm thanh cuộc họp. Ta dùng **BlackHole**, một thiết bị âm thanh ảo miễn
phí, để sao chép âm thanh Zoom cho app, trong khi bạn vẫn nghe bình thường.

### 3.1. Cài BlackHole

```bash
brew install --cask blackhole-2ch
```

Máy sẽ hỏi mật khẩu. Cài xong, **khởi động lại Mac** hoặc chạy:

```bash
sudo killall coreaudiod
```

### 3.2. Tạo "Multi-Output Device"

1. Mở **Audio MIDI Setup**: nhấn ⌘ + Space rồi gõ "Audio MIDI Setup".
2. Bấm dấu **+** ở góc dưới bên trái, chọn **Create Multi-Output Device**.
3. Tick **loa hoặc tai nghe** của bạn (ví dụ *MacBook Air Speakers*) **trước**, sau đó
   tick **BlackHole 2ch**.
4. Ở dòng BlackHole, tick **Drift Correction**.

### 3.3. Cho âm thanh cuộc họp đi qua Multi-Output Device

- **Dùng Zoom app:** vào Zoom → **Settings → Audio → Speaker**, chọn **Multi-Output Device**.
  Giữ nguyên Microphone.
- **Dùng Zoom trên trình duyệt** (Chrome, Brave…): vào **System Settings → Sound → Output**,
  hoặc bấm biểu tượng loa trên thanh menu, rồi chọn **Multi-Output Device**.

> Nếu bạn cắm tai nghe hay đổi loa, macOS có thể tự đổi Output. Khi đó app sẽ hiện **dải
> cảnh báo màu cam**. Chỉ cần chọn lại Multi-Output Device.

## 4. Mở app lần đầu

1. Mở **Meet for Me.app**.
2. macOS sẽ hỏi hai quyền. Bấm **Allow** cho cả hai:
   - **Microphone**: để đọc âm thanh từ BlackHole (app không nghe mic của bạn).
   - **Documents**: để chạy phần lõi trong thư mục `~/Documents/zoom-listener`.
3. Cho phép **thông báo (Notifications)** của *Meet for Me* khi macOS hỏi.

> **Cảnh báo nổi:** ngoài thông báo của macOS, app còn hiện một **thẻ cảnh báo ở góc trên bên
> phải** màn hình (câu hỏi, câu trả lời gợi ý, nút copy). Thẻ này **vẫn hiện khi bật Focus/Do Not
> Disturb**, và **bị ẩn khi bạn chia sẻ màn hình hoặc ghi hình**, nên người khác trong cuộc họp
> không thấy được câu trả lời gợi ý của bạn. Thẻ câu hỏi giữ nguyên cho đến khi bạn bấm ✕.

> Mỗi lần build lại app (`app/build.sh`), macOS coi đó là app mới và **hỏi lại hai quyền
> trên**. Nếu không bấm Allow, app sẽ không bắt đầu nghe.

## 5. Đặt tên của bạn

Lần đầu mở, app tự chuyển sang tab **Settings**:

- **Name(s):** tên đồng nghiệp gọi bạn, **có dấu đầy đủ**, cách nhau bằng dấu phẩy.
  Ví dụ: `Hiếu, Trung Hiếu`.
- **Other names:** tên khác (tên tiếng Anh, biệt danh). Ví dụ: `Hugh`.
- **Project words:** thuật ngữ trong dự án để Whisper viết đúng. Ví dụ:
  `API, deploy, staging, sprint`.

Bấm **Save**.

Vì sao phải ghi **có dấu**? Vì tiếng Việt có nhiều từ chỉ khác nhau ở dấu: **Hiếu** (tên) khác
**hiểu** (hiểu biết) và **hiệu** (hiệu suất). App so khớp **giữ nguyên dấu**, nên câu
"mọi người hiểu chưa?" sẽ không bị nhầm là gọi bạn. Dạng không dấu (`Hieu`) được tự động
thêm vào, phòng khi có người gọi tên bạn kiểu tiếng Anh.

Mẹo:
- Nếu tên bạn cũng là một đại từ (**Anh**, **Em**, **Chị**…), app sẽ không chấp nhận tên
  đứng một mình, vì gần như câu nào cũng có các từ đó. Hãy dùng tên đầy đủ, ví dụ `Đức Anh`.
- Nếu trong nhóm có người **trùng tên** với bạn, hãy dùng tên đầy đủ (`Trung Hiếu`) và bỏ
  tên ngắn, để tránh báo nhầm.

Đặt tên bằng Terminal (không bắt buộc):
```bash
.venv/bin/python listener.py --set-name "Hiếu, Trung Hiếu" --aliases "Hugh"
```

## 6. Ghi chú cho câu trả lời (không bắt buộc)

Trong **Settings → Notes**, bạn có thể ghi: vai trò, tiến độ công việc, deadline, các
quyết định đã có… Khi cuộc họp chưa nhắc đến thông tin nào đó, app sẽ lấy từ đây để soạn
câu trả lời. Ghi chú được đọc lại mỗi lần có câu hỏi, nên sửa giữa buổi họp cũng có tác dụng.

## 7. Sử dụng

Bấm **Start listening** (phím tắt ⌘L). Đèn trạng thái có ba màu:
- 🟠 **Cam:** đang tải model. Đợi đèn xanh rồi hãy dựa vào app.
- 🟢 **Xanh:** đang nghe.
- 🔴 **Đỏ:** có lỗi. Đọc dòng thông báo bên cạnh đèn.

Đóng cửa sổ thì app **vẫn chạy** dưới biểu tượng 👂 trên thanh menu. Từ đó bạn có thể
Start/Stop hoặc mở lại cửa sổ.

### Tab Live
- **Questions for you** (bên trái): các câu hỏi dành cho bạn, kèm câu trả lời gợi ý và
  độ tin cậy (high / medium / low). Bấm 📋 để copy câu trả lời. Mở **"Based on…"** để xem
  câu trả lời dựa vào dòng transcript hay ghi chú nào.
- **Transcript** (bên phải): lời nói trong cuộc họp, theo thời gian thực. Dòng có tên bạn
  được tô vàng.
- **Rê chuột vào một dòng transcript**, biểu tượng 💬 sẽ hiện ra. Bấm vào để hỏi về dòng đó
  trong Chat: nếu là câu hỏi thì app trả lời, nếu không thì app giải thích ý nghĩa và
  bối cảnh.

### Tab Chat
Hỏi bất cứ điều gì về cuộc họp, ví dụ:
- "Tóm tắt cuộc họp"
- "Có ai hỏi mình gì không?"
- "Mình được giao việc gì?"
- "Có quyết định hay deadline nào?"

Câu trả lời dựa trên transcript (và ghi chú nếu có), kèm giờ như **(14:37)** để bạn đối
chiếu. Bạn có thể hỏi tiếp. Ô **Meeting** cho chọn *Today (all)* (mọi phiên hôm nay) hoặc một
phiên ghi cụ thể.

## 8. Khi nào app báo cho bạn?

Người ta thường gọi tên trước rồi mới hỏi, và câu hỏi nằm ở dòng sau:

> "Anh Hiếu ơi." … "Cho em hỏi là cái API ấy," … "khi nào xong để bên em test ạ?"

Vì vậy, sau khi nghe tên bạn, app **chờ người nói nói hết câu**: chờ họ ngừng khoảng 2,5 giây,
hoặc đến khi câu kết thúc kiểu câu hỏi ("?", *không, chưa, ạ, nhỉ, khi nào…*). Sau đó app gửi
cho Claude hai dòng trước tên bạn và tất cả các dòng sau. Câu hỏi đặt **trước** tên
("…chốt được chưa nhỉ? Hiếu nhỉ?") cũng được nhận ra.

| Tình huống | App làm gì |
|---|---|
| Có câu hỏi cho bạn | Thông báo kèm câu trả lời gợi ý |
| Mới chỉ gọi tên ("Hiếu ơi, cho em hỏi chút") | Nghe tiếp tối đa 30 giây. Nếu không có câu hỏi, báo **"Someone called you"** |
| Chỉ nhắc đến bạn, hỏi người khác, hoặc rút lại câu hỏi ("thôi, để sau") | Không báo |

## 9. Câu trả lời gợi ý lấy từ đâu?

1. **Transcript cuộc họp** (nguồn chính): những gì đã được nói trong buổi họp. Nếu khác
   với ghi chú, app tin transcript vì nó mới hơn.
2. **Ghi chú của bạn:** chỉ dùng cho phần cuộc họp chưa nhắc đến.
3. **Không nguồn nào có thông tin:** app soạn câu kiểu "để mình kiểm tra lại rồi báo sau",
   với độ tin cậy *low*. App **không bịa thông tin**.

Câu trả lời dùng cách xưng hô theo cách người hỏi gọi bạn. Ví dụ, bị gọi là "anh" thì trả lời
xưng "anh", gọi người hỏi là "em". Câu trả lời không nhắc đến nguồn, vì bạn sẽ nói nó thành lời.

## 10. Xử lý sự cố

| Vấn đề | Cách xử lý |
|---|---|
| Không thấy thông báo của macOS | Có thể đang bật **Focus / Do Not Disturb** (macOS cũng tự bật khi chia sẻ màn hình). Thẻ cảnh báo nổi của app vẫn hiện. Muốn thông báo macOS cũng hiện: thêm *Meet for Me* vào Allowed Apps của Focus. |
| Transcript trống | Âm thanh chưa vào BlackHole. Kiểm tra mục 3.3 (Output hoặc Speaker phải là **Multi-Output Device**). App hiện dải cam khi Output sai, và gửi thông báo nếu 45 giây không có âm thanh. |
| Không thấy giọng của chính mình | Bình thường. App chỉ nghe được người khác (Zoom không phát lại giọng của bạn). Muốn tự thử, hãy vào họp thêm bằng điện thoại và nói từ đó. |
| App mở nhưng không nghe | Có thể chưa cấp quyền Microphone/Documents. Xem System Settings → Privacy & Security → **Microphone** và **Files and Folders**. |
| Xuất hiện câu lạ như "Cảm ơn các bạn đã theo dõi", "Gi Gi Gi…" | Whisper "bịa" chữ khi chỉ có tiếng ồn. App tự lọc các câu này. Nếu gặp câu lạ khác, thêm vào `HALLUCINATION_PHRASES` trong `listener.py`. |
| Thuật ngữ tiếng Anh bị nghe sai ("ATI" thay vì "API") | Thêm từ đó vào **Project words** trong Settings. |
| Báo "Another listener is already running" | Đang có một bản khác chạy (app hoặc Terminal). Tắt bản đó trước. Hai bản chạy cùng lúc sẽ trả lời mỗi câu hỏi hai lần. |
| Muốn xem chi tiết app đang làm gì | Mở `logs/engine.log`. Các câu bị lọc ghi là `(dropped: …)`. |

## 11. Tuỳ chỉnh (file `config.json`)

- `silence_threshold`: app không bắt được câu nào thì **giảm** (ví dụ `0.003`). Câu bị cắt
  vụn quá nhiều thì **tăng**.
- `language`: `"vi"` (mặc định), `"en"` cho họp tiếng Anh, hoặc `null` để tự nhận diện.
- `claude_model`: `haiku` (nhanh nhất), `sonnet` (cân bằng, mặc định), `opus` (tốt nhất).
  Có thể chọn trong Settings.
- `question_settle_seconds` (2,5): chờ người nói ngừng bao lâu thì coi là hết câu.
- `question_wait_seconds` (30): sau khi bị gọi tên, chờ câu hỏi tối đa bao lâu.

## 12. Dùng bằng Terminal (không cần app)

```bash
cd ~/Documents/zoom-listener
.venv/bin/python listener.py                     # bắt đầu nghe
.venv/bin/python listener.py --setup             # đặt tên
.venv/bin/python listener.py --ask "Tóm tắt cuộc họp hôm nay"   # chat
.venv/bin/python listener.py --list-devices      # xem thiết bị âm thanh
.venv/bin/python listener.py --test-notify       # thử thông báo
```

## 13. Chạy hoàn toàn offline (Ollama)

```bash
brew install ollama && ollama serve &
ollama pull qwen3:8b
```

Sau đó vào **Settings → Answers → Engine**, chọn **Ollama (offline)**, hoặc đặt
`"llm_backend": "ollama"` trong `config.json`.

## 14. Dữ liệu được lưu ở đâu?

Tất cả nằm trong thư mục `~/Documents/zoom-listener` trên máy bạn, và **không được đưa lên
GitHub**:
- `transcripts/`: transcript từng phiên họp.
- `answers/`: các câu hỏi và câu trả lời gợi ý.
- `logs/engine.log`: nhật ký hoạt động.
- `config.json`: cài đặt và tên của bạn.
- `context.md`: ghi chú của bạn.

Muốn xoá dữ liệu một buổi họp, chỉ cần xoá file tương ứng trong `transcripts/` và `answers/`.
