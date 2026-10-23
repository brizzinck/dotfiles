#!/usr/bin/env bash
# Offline test of tg-archive: a FAKE MCP gateway (fake_gateway.py: bearer token, session id, list_chats, export_history in two
# slices), a fake mcp-gateway command, fake whisper-cli and tesseract first on PATH, the real ffmpeg for frames and contact
# sheets, a private HOME / archive root / export dir. No display variables: nothing can open a window or reach Telegram.
#   infrastructure/tests/tg-archive/run.sh [--quick] [--keep]
# --quick is the same suite (it takes a few seconds); doctor runs it.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
TGA="$REPO/.local/bin/tg-archive"
KEEP=0
for a in "$@"; do case $a in --quick) ;; --keep) KEEP=1 ;; *) echo "usage: run.sh [--quick] [--keep]" >&2; exit 2 ;; esac; done
PASS=0 FAILS=0 SKIPS=0
check() { # check NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAILS=$((FAILS + 1)); echo "FAIL: $name"; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/tg-archive-test.XXXXXX")
cleanup() {
  [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null
  [ "$KEEP" = 1 ] && { echo "kept $T"; return; }
  rm -rf "$T"
}
trap cleanup EXIT
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/home/.local/state" XDG_CONFIG_HOME="$T/home/.config"
export PYTHONDONTWRITEBYTECODE=1 TZ=UTC
export TG_ARCHIVE_ROOT="$T/archive" TG_ARCHIVE_EXPORT="$T/export" FAKE_EXPORT_SRC="$T/src" FAKE_LOG="$T/fake.log"
mkdir -p "$HOME/.local/share/voxtype/models" "$XDG_RUNTIME_DIR" "$T/fakes" "$TG_ARCHIVE_EXPORT"
: >"$FAKE_LOG"
: >"$HOME/.local/share/voxtype/models/ggml-large-v3-turbo.bin"
if ! command -v ffmpeg >/dev/null; then echo "SKIP: tg-archive tests need ffmpeg"; echo "tg-archive tests: 0 passed, 0 failed, 1 skipped"; exit 0; fi

# fakes: whisper-cli writes the JSON whisper.cpp writes (-oj -of BASE); tesseract prints a line for every image
cat >"$T/fakes/whisper-cli" <<'EOF'
#!/usr/bin/env bash
printf 'whisper %s\n' "$*" >>"$FAKE_LOG"
while [ $# -gt 0 ]; do case $1 in -of) base=$2; shift ;; esac; shift; done
cat >"$base.json" <<'J'
{"result": {"language": "ru"}, "transcription": [
 {"offsets": {"from": 0, "to": 4000}, "text": " Это расшифровка номер один."},
 {"offsets": {"from": 4000, "to": 5000}, "text": " Субтитры сделал DimaTorzok"},
 {"offsets": {"from": 5000, "to": 6000}, "text": " Thank you."},
 {"offsets": {"from": 6000, "to": 7000}, "text": " да да да да да да да понял"},
 {"offsets": {"from": 9000, "to": 12000}, "text": " Смотрите на синий слайд."},
 {"offsets": {"from": 12000, "to": 13000}, "text": " Смотрите на синий слайд!"}]}
J
EOF
printf '#!/usr/bin/env bash\nprintf "tesseract %%s\\n" "$1" >>"$FAKE_LOG"\necho "Слайд архитектуры сервиса"\n' >"$T/fakes/tesseract"
printf '#!/usr/bin/env bash\necho "pdftotext should not run" >>"$FAKE_LOG"\nexit 1\n' >"$T/fakes/pdftotext"
TOKEN=tok-$RANDOM$RANDOM
cat >"$T/fakes/mcp-gateway" <<EOF
#!/usr/bin/env bash
case "\$1" in
  url) [ "\$2" = telegram ] && echo "http://127.0.0.1:\$(cat "$T/port")/telegram/mcp" ;;
  headers) echo '{"Authorization": "Bearer $TOKEN"}' ;;
esac
EOF
chmod +x "$T/fakes/"*
export PATH="$T/fakes:$PATH" TG_ARCHIVE_GATEWAY="$T/fakes/mcp-gateway"
export XDG_DATA_HOME="$T/home/.local/share" TG_ARCHIVE_VAD_MODEL="$T/vad.bin"   # never downloads in the suite
: >"$TG_ARCHIVE_VAD_MODEL"

# source data: what the real export_history would have written (two chats)
C1=-1001234 C2=-1005678 C3=-1009999
mkdir -p "$T/src/$C1/media" "$T/src/$C2/media" "$T/src/$C3/media"
ff() { ffmpeg -nostdin -v error -y "$@"; }
ff -f lavfi -i "sine=frequency=300:duration=3" "$T/src/$C1/media/2-voice.ogg"
ff -f lavfi -i "testsrc=size=320x240:rate=1:duration=1" -frames:v 1 "$T/src/$C1/media/3-photo.jpg"
ff -f lavfi -i "testsrc=size=320x240:rate=10:duration=8,format=yuv420p" -f lavfi -i "color=c=blue:size=320x240:rate=10:duration=8" \
  -f lavfi -i "sine=frequency=440:duration=16" -filter_complex "[0:v][1:v]concat=n=2:v=1[v]" -map "[v]" -map 2:a -c:v libx264 \
  -c:a aac -shortest -metadata creation_time=2026-01-07T08:58:00Z "$T/src/$C1/media/4-lecture.mp4"
printf 'секретный план релиза\n' >"$T/src/$C1/media/5-notes.txt"
cat >"$T/src/$C1/messages.jsonl" <<'EOF'
{"id": 1, "date": "2026-01-05T10:00:00+00:00", "text": "Привет **мир**", "views": 10}
{"id": 2, "date": "2026-01-05T10:05:00+00:00", "media": {"kind": "voice", "file": "2-voice.ogg", "duration": 3, "mime": "audio/ogg"}}
{"id": 3, "date": "2026-01-06T09:00:00+00:00", "text": "Схема", "media": {"kind": "photo", "file": "3-photo.jpg"}}
{"id": 4, "date": "2026-01-07T09:00:00+00:00", "text": "Лекция 1", "media": {"kind": "video", "file": "4-lecture.mp4", "duration": 16, "name": "lecture.mp4"}}
{"id": 5, "date": "2026-01-07T09:30:00+00:00", "media": {"kind": "document", "file": "5-notes.txt", "name": "notes.txt", "mime": "text/plain", "size": 30}}
{"id": 6, "date": "2026-01-08T09:00:00+00:00", "text": "читать", "media": {"kind": "webpage", "url": "https://example.org/a", "title": "Статья"}}
{"id": 7, "date": "2026-01-08T10:00:00+00:00", "text": "Ответ", "reply_to": 1, "forwarded": {"name": "Другой канал", "date": "2025-12-01T00:00:00+00:00"}, "reactions": [{"emoji": "👍", "count": 3}]}
{"id": 99, "date": "2026-01-09T10:00:00+00:00", "media": {"kind": "video", "file": "99-big.mkv", "name": "big.mkv", "duration": 7200, "size": 4718592000}}
{"id": 100, "date": "2026-02-01T10:00:00+00:00", "text": "февраль ```{\n  \"a\": 1\n}``` и ```python\nprint(1)```"}
{"id": 101, "date": "2026-02-01T11:00:00+00:00", "text": "https://youtu.be/x", "media": {"kind": "other"}}
EOF
cat >"$T/src/$C2/messages.jsonl" <<'EOF'
{"id": 1, "date": "2026-03-01T10:00:00+00:00", "from": {"id": 5, "name": "Анна"}, "text": "всем привет"}
{"id": 2, "date": "2026-03-01T10:01:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "привет", "reply_to": 1}
{"id": 3, "date": "2026-03-01T10:02:00+00:00", "from": {"id": 5, "name": "Анна"}, "media": {"kind": "photo", "file": "3-pic.jpg"}}
EOF
printf 'x' >"$T/src/$C2/media/9-should-not-come.jpg"
ff -f lavfi -i "testsrc=size=160x120:rate=1:duration=1" -frames:v 1 "$T/src/$C2/media/3-pic.jpg"
# a forum group: topics are TopicCreate service messages, a message in a topic carries its id, General ones none
cat >"$T/src/$C3/messages.jsonl" <<'EOF'
{"id": 10, "date": "2026-04-01T10:00:00+00:00", "action": {"type": "TopicCreate", "title": "Челенджі"}}
{"id": 11, "date": "2026-04-01T10:01:00+00:00", "from": {"id": 5, "name": "Анна"}, "text": "перший челендж", "reply_to": 10, "topic": 10}
{"id": 12, "date": "2026-04-01T10:02:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "загальне питання"}
{"id": 13, "date": "2026-04-01T10:03:00+00:00", "action": {"type": "TopicCreate", "title": "AI"}}
{"id": 14, "date": "2026-04-01T10:04:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "нейромережі", "reply_to": 13, "topic": 13}
{"id": 15, "date": "2026-04-02T10:00:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "відповідь у челенджі", "reply_to": 11, "topic": 10}
{"id": 16, "date": "2026-04-03T10:00:00+00:00", "action": {"type": "TopicEdit", "title": "Челенджі 2026"}, "reply_to": 10, "topic": 10}
{"id": 17, "date": "2026-04-03T11:00:00+00:00", "from": {"id": 5, "name": "Анна"}, "media": {"kind": "photo", "file": "17-pic.jpg"}, "reply_to": 13, "topic": 13}
{"id": 18, "date": "2026-04-06T09:00:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "Матеріали: [гайд](https://www.notion.so/Gaid-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?source=copy_link), закрита https://www.notion.so/cccccccccccccccccccccccccccccccc, стрім https://youtube.com/live/abcdefghijk?feature=share і https://youtu.be/zzzzzzzzzzz"}
EOF
# linked content: Notion's public API (fake_gateway.py /notion, page A in two chunks with a sub-page, an image, a YouTube
# block and a database; page C closed) and yt-dlp (one stream, one private video)
A=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa NB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb NC=cccccccc-cccc-cccc-cccc-cccccccccccc
blk() { printf '"%s": {"value": {"value": %s, "role": "reader"}}' "$1" "$2"; }
cat >"$T/notion.json" <<EOF
{"$A": [{"block": {$(blk $A '{"id": "'$A'", "type": "page", "properties": {"title": [["Гайд"]]}, "format": {"page_icon": "📘"}, "content": ["n-h", "n-t", "n-l", "n-img", "n-vid", "'$NB'", "n-db", "n-end"]}'),
   $(blk n-h '{"id": "n-h", "type": "sub_header", "properties": {"title": [["Розділ"]]}}'),
   $(blk n-t '{"id": "n-t", "type": "text", "properties": {"title": [["Це "], ["жирний", [["b"]]], [" і "], ["посилання", [["a", "https://example.org/x"]]]]}}'),
   $(blk n-l '{"id": "n-l", "type": "bulleted_list", "properties": {"title": [["пункт"]]}, "content": ["n-l2"]}'),
   $(blk n-l2 '{"id": "n-l2", "type": "bulleted_list", "properties": {"title": [["вкладений"]]}}'),
   $(blk n-img '{"id": "n-img", "type": "image", "space_id": "s1", "properties": {"source": [["attachment:x:schema.png"]], "caption": [["Схема"]]}}'),
   $(blk n-vid '{"id": "n-vid", "type": "video", "properties": {"source": [["https://www.youtube.com/watch?v=abcdefghijk"]]}}')}},
  {"block": {$(blk $NB '{"id": "'$NB'", "type": "page", "parent_table": "block", "parent_id": "'$A'", "properties": {"title": [["Глава 2"]]}}'),
   $(blk n-db '{"id": "n-db", "type": "collection_view", "collection_id": "coll-1", "view_ids": ["view-1"], "space_id": "s1"}'),
   $(blk n-end '{"id": "n-end", "type": "text", "properties": {"title": [["Кінець гайду"]]}}')},
   "collection": {"coll-1": {"value": {"value": {"id": "coll-1", "name": [["Задачі"]], "schema": {"title": {"name": "Назва", "type": "title"}, "st": {"name": "Статус", "type": "select"}}}}}},
   "collection_view": {"view-1": {"value": {"value": {"id": "view-1", "format": {"table_properties": [{"property": "title", "visible": true}, {"property": "st", "visible": true}]}}}}}}],
 "$NB": [{"block": {$(blk $NB '{"id": "'$NB'", "type": "page", "parent_table": "block", "parent_id": "'$A'", "properties": {"title": [["Глава 2"]]}, "content": ["b-t"]}'),
   $(blk b-t '{"id": "b-t", "type": "text", "properties": {"title": [["Текст глави"]]}}')}}],
 "$NC": [{"block": {"$NC": {"value": {"role": "none"}}}}],
 "rows": {"coll-1": {$(blk row-1 '{"id": "row-1", "type": "page", "parent_table": "collection", "properties": {"title": [["Перша"]], "st": [["готово"]]}}')}}}
EOF
ff -f lavfi -i "testsrc=size=80x60:rate=1:duration=1" -frames:v 1 "$T/notion-image.png"
cat >"$T/fakes/yt-dlp" <<'EOF'
#!/usr/bin/env bash
printf 'yt-dlp %s\n' "$*" >>"$FAKE_LOG"
url=${!#}
case $url in *zzzzzzzzzzz*) echo "ERROR: [youtube] zzzzzzzzzzz: Private video" >&2; exit 1 ;; esac
for a in "$@"; do
  [ "$a" = -J ] && { printf '{"title": "Стрім про AI", "channel": "Test TV", "webpage_url": "%s", "duration": 16, "live_status": "was_live", "upload_date": "20260405", "release_timestamp": 1775412000, "description": "Опис стріму", "chapters": [{"start_time": 0, "title": "Вступ"}, {"start_time": 8, "title": "Слайди"}]}\n' "$url"; exit 0; }
done
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
cp "$FAKE_YT_VIDEO" "${out%.*}.mp4"
EOF
chmod +x "$T/fakes/yt-dlp"
export FAKE_NOTION="$T/notion.json" FAKE_NOTION_IMAGE="$T/notion-image.png" FAKE_YT_VIDEO="$T/src/$C1/media/4-lecture.mp4"
ff -f lavfi -i "testsrc=size=160x120:rate=1:duration=1" -frames:v 1 "$T/src/$C3/media/17-pic.jpg"
export FAKE_TIMEOUT_ONCE=1   # the first export_history call times out on the server: tg-archive must just call again
export FAKE_CHATS='[{"chat_id": -1001234, "title": "Курс Rust", "type": "Channel"}, {"chat_id": -1005678, "title": "Команда‮", "type": "Group"}, {"chat_id": -1009999, "title": "Спільнота", "type": "Forum"}, {"chat_id": -1004444, "title": "Обговорення", "type": "Group"}]'
python3 -I -B "$HERE/fake_gateway.py" "$T/port" "$TOKEN" &
GW_PID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export TG_ARCHIVE_NOTION="http://127.0.0.1:$(cat "$T/port")/notion"

# links: every relative Markdown link of the archive points at an existing file, every #mID anchor exists in its target
cat >"$T/links.py" <<'EOF'
import re, sys
from pathlib import Path
root, bad = Path(sys.argv[1]), []
for md in root.rglob('*.md'):
    for target in re.findall(r'\]\(([^)\s]+)\)', md.read_text()):
        if re.match(r'[a-z]+://', target):
            continue
        path, _, anchor = target.partition('#')
        f = (md.parent / path).resolve() if path else md
        if not f.exists():
            bad.append(f'{md.relative_to(root)} -> {target}')
        elif anchor and f.suffix == '.md' and f'<a id="{anchor}">' not in f.read_text():   # #t=83 on media: a time
            bad.append(f'{md.relative_to(root)} -> {target} (anchor)')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
EOF

# --- usage and refusals ---
check "usage: no command exits 2" bash -c '"$1" >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"
check "usage: a bad --lang exits 2" bash -c '"$1" run x --lang "ru;rm" >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"
check "gateway down: exit 3 with the hint" bash -c 'out=$(TG_ARCHIVE_GATEWAY=/bin/false "$1" chats 2>&1); [ $? -eq 3 ] && grep -q "mcp-telegram-setup\|gateway" <<<"$out"' _ "$TGA"

# --- chats ---
out=$("$TGA" chats 2>&1)
check "chats: both allowlisted chats listed" bash -c 'grep -q "^-1001234	channel	Курс Rust$" <<<"$1" && grep -q "^-1005678	group" <<<"$1"' _ "$out"
check "chats: a bidi control character in a title is shown as <U+202E>" grep -q 'Команда<U+202E>' <<<"$out"
check "chats: the gateway saw the bearer token and a session id" grep -q '"session": "sess-1"' "$FAKE_LOG"
check "unknown title: exit 4 and the steps to connect it" bash -c 'out=$("$1" run "Нет такого" 2>&1); [ $? -eq 4 ] && grep -q "not connected" <<<"$out" && grep -q "join the chat" <<<"$out" && grep -q "mcp-telegram-setup chats" <<<"$out" && grep -q "tg-archive run Нет такого" <<<"$out"' _ "$TGA"
check "usage: --max-file-mb outside 1..4000 exits 2" bash -c '"$1" run x --max-file-mb 0 >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"

# --- run by title ---
"$TGA" run "курс" >"$T/run1.out" 2>&1
check "run: exit 0" bash -c 'grep -q "ready:" "$1"' _ "$T/run1.out"
A=$(ls -d "$TG_ARCHIVE_ROOT"/*-1001234 2>/dev/null | head -1)
check "run: archive folder named after the title and the id" test -n "$A" -a -d "$A"
A=${A:-$T/none}
check "export: a server timeout is retried" grep -q "slice timed out on the server, continuing (1/5)" "$T/run1.out"
check "export: called until done (one timeout + two slices), 40 s slices, media on, no restart" bash -c '[ "$(grep -c "\"tool\": \"export_history\".*-1001234" "$1")" = 3 ] && grep -q "\"max_seconds\": 40" "$1" && ! grep -q "\"restart\"" "$1" && grep -q "\"media\": true" "$1"' _ "$FAKE_LOG"
check "chat outside the allowlist (upstream's plain privacy-policy text): exit 4 with the steps" bash -c 'out=$("$1" run @nobody_here 2>&1); [ $? -eq 4 ] && grep -q "@nobody_here is not connected" <<<"$out" && grep -q "mcp-telegram-setup chats" <<<"$out"' _ "$TGA"
check "import: the export folder is emptied (messages and files moved, none left)" bash -c '[ ! -e "$1/messages.jsonl" ] && [ -z "$(ls -A "$1/media")" ] && [ -z "$(ls "$1" | grep importing)" ]' _ "$TG_ARCHIVE_EXPORT/$C1"
check "import: every message once in .raw/messages.jsonl" bash -c '[ "$(wc -l <"$1/.raw/messages.jsonl")" = 10 ]' _ "$A"
check "import: files are copies owned by you" bash -c '[ "$(stat -c %U "$1/media/4-lecture.mp4")" = "$(id -un)" ] && cmp -s "$1/media/4-lecture.mp4" "$2/media/4-lecture.mp4"' _ "$A" "$T/src/$C1"
check "process: whisper ran on voice and video with the large-v3-turbo model, language auto, VAD on" bash -c '[ "$(grep -c "^whisper .*ggml-large-v3-turbo.bin.* -l auto .*--vad -vm .*vad.bin" "$1")" = 2 ]' _ "$FAKE_LOG"
check "process: invented text (subtitle credits, a lone thank you) dropped, loops and repeats collapsed" bash -c 'python3 -I -B -c "import json,sys; t=[x[2] for x in json.load(open(sys.argv[1]))[\"segments\"]]; sys.exit(0 if t == [\"Это расшифровка номер один.\", \"да, да, да… понял\", \"Смотрите на синий слайд.\"] else 1)" "$1/.raw/asr/4.json" && python3 -I -B -c "import json,sys; j=json.load(open(sys.argv[1])); sys.exit(0 if j[\"v\"] == 2 and j[\"vad\"] else 1)" "$1/.raw/asr/4.json"' _ "$A"
check "process: OCR on the photo and on the video frame candidates" bash -c 'grep -q "^tesseract .*3-photo.jpg" "$1" && grep -q "^tesseract .*frames/4/c0001.jpg" "$1"' _ "$FAKE_LOG"
check "--files default: photo, video, video note and voice only; the text document is not downloaded and says why" bash -c '[ ! -e "$1/media/5-notes.txt" ] && grep -q "\"kinds\": \"photo,video,video_note,voice\"" "$2" && grep -q "notes.txt (файл не скачан: этот тип файлов не выбран)" "$1/messages/2026-01.md"' _ "$A" "$FAKE_LOG"
check "--files: an unknown kind exits 2" bash -c '"$1" run x --files photo,apk >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"
"$TGA" run -1001234 --refresh --files all >/dev/null 2>&1
check "--refresh --files all: the document comes, its text is read without pdftotext" bash -c '[ "$(cat "$1/.raw/text/5.txt")" = "секретный план релиза" ] && ! grep -q pdftotext "$2"' _ "$A" "$FAKE_LOG"
check "frames: candidates at the start and at the cut, a contact sheet" bash -c 'python3 -I -B -c "import json,sys; c=json.load(open(sys.argv[1])); t=[x[\"t\"] for x in c[\"candidates\"]]; sys.exit(0 if t[0]==0 and any(7<x<9 for x in t) and c[\"sheets\"] else 1)" "$1/.raw/frames/4/candidates.json" && [ -s "$1/.raw/frames/4/sheet-01.jpg" ]' _ "$A"
M1="$A/messages/2026-01.md"
check "render: month files, text kept as Markdown" bash -c 'grep -q "Привет \*\*мир\*\*" "$1" && grep -q "февраль" "$2"' _ "$M1" "$A/messages/2026-02.md"
check "render: short voice transcript inline" grep -q "Это расшифровка номер один" "$M1"
check "times: a voice message was recorded right before sending (sent - duration); every paragraph links its second and says the clock time" bash -c 'grep -q "Расшифровка (записано 2026-01-05 10:04–10:05):" "$1" && grep -q "> \*\*\[0:00\](../media/2-voice.ogg#t=0) · 10:04\*\* Это расшифровка номер один" "$1"' _ "$M1"
check "times: a video's start comes from its creation_time; the transcript page says when and how it is known" bash -c 'grep -q "^Записано: 2026-01-07 08:58 (по метаданным файла, приблизительно)" "$1/transcripts/4.md" && grep -q "^\*\*\[0:00\](../media/4-lecture.mp4#t=0) · 08:58\*\*" "$1/transcripts/4.md"' _ "$A"
check "times: a video in the month page and the index carries the recording time and stamped paragraphs too" bash -c 'grep -q "Расшифровка (записано 2026-01-07 08:58):" "$1/messages/2026-01.md" && grep -q "> \*\*\[0:00\](../media/4-lecture.mp4#t=0) · 08:58\*\*" "$1/messages/2026-01.md" && grep -q "(transcripts/4.md) · записано 2026-01-07 08:58" "$1/index.md"' _ "$A"
check "times: a creation_time after sending is not a start, Apple's creationdate with a zone is" python3 -I -B -c '
import importlib.machinery as m, importlib.util as u, sys
l = m.SourceFileLoader("t", sys.argv[1]); s = u.spec_from_loader("t", l); t = u.module_from_spec(s); l.exec_module(t)
rec = {"date": "2026-01-07T09:00:00+00:00", "media": {"kind": "video", "duration": 60}}
assert t.recorded(rec, ["2026-01-07T09:30:00.000000Z"]) == (None, None)
start, how = t.recorded(rec, ["2026-01-07T10:57:00+0200", "2026-01-07T08:59:30Z"])
assert how == "meta" and start.isoformat() == "2026-01-07T10:57:00+02:00", start
fwd = {"date": "2026-02-01T00:00:00+00:00", "forwarded": {"date": "2026-01-01T12:00:10+00:00"}, "media": {"kind": "voice", "duration": 10}}
assert t.recorded(fwd, [])[0].isoformat() == "2026-01-01T12:00:00+00:00"
' "$TGA"
check "render: code blocks get their fences on own lines (language kept)" bash -c 'grep -qx "\`\`\`" "$1" && grep -qx "\`\`\`python" "$1" && grep -qx "print(1)" "$1"' _ "$A/messages/2026-02.md"
check "render: media without a file is just labelled, not 'not downloaded'" bash -c 'grep -qx -- "- Вложение" "$1" && ! grep -q "Вложение.*не скачан" "$1"' _ "$A/messages/2026-02.md"
check "render: photo shown inline with its OCR text" bash -c 'grep -q "!\[\](../media/3-photo.jpg)" "$1" && grep -q "Слайд архитектуры сервиса" "$1"' _ "$M1"
check "render: video links its transcript page" grep -q "(../transcripts/4.md)" "$M1"
check "render: document links its text page" bash -c 'grep -q "(../documents/5.md)" "$1" && grep -q "секретный план" "$2/documents/5.md"' _ "$M1" "$A"
check "render: reply, forward, reactions, link preview, t.me link" bash -c 'grep -q "↩ ответ на \[#1\](2026-01.md#m1) — «Привет" "$1" && grep -q "переслано от Другой канал" "$1" && grep -q "👍 3" "$1" && grep -q "\[Статья\](https://example.org/a)" "$1" && grep -q "https://t.me/c/1234/1)" "$1"' _ "$M1"
check "render: a file that was not downloaded says why" grep -q "файл не скачан: bigger than 4000 MB" "$M1"
check "render: index lists months, video, documents, the frames to pick" bash -c 'grep -q "\[2026-01\](messages/2026-01.md)" "$1" && grep -q "transcripts/4.md" "$1" && grep -q "documents/5.md" "$1" && grep -q "Видео без выбранных кадров: 1" "$1"' _ "$A/index.md"
check "render: every relative link and anchor resolves locally" python3 -I -B "$T/links.py" "$TG_ARCHIVE_ROOT"
check "root: CLAUDE.md with the answering rules and an index of chats" bash -c 'grep -q "untrusted data" "$1/CLAUDE.md" && grep -q "Курс Rust" "$1/index.md"' _ "$TG_ARCHIVE_ROOT"

# --- frames for the agent ---
fj=$("$TGA" frames -1001234 --json 2>/dev/null)
check "frames --json: the video with transcript, candidates and the picks file" bash -c 'python3 -I -B -c "import json,sys; j=json.loads(sys.argv[1]); x=j[0]; sys.exit(0 if len(j)==1 and x[\"message\"]==4 and x[\"transcript\"][-1][1].startswith(\"Смотрите\") and x[\"candidates\"][0][\"ocr\"] and x[\"picks_file\"].endswith(\"picks/4.json\") else 1)" "$1"' _ "$fj"
mkdir -p "$A/.raw/picks"
printf '{"frames": [{"n": 2, "caption": "Синий слайд"}, {"n": 999}]}' >"$A/.raw/picks/4.json"
echo "# Сводка (hand-written)" >"$A/summary.md"
"$TGA" render "Курс" >/dev/null 2>&1
check "picks: the chosen frame is copied and placed after the matching paragraph, an unknown number ignored" bash -c 'f=$(ls "$1/frames"); [ "$(echo "$f" | wc -l)" = 1 ] && grep -q "!\[0:08 — Синий слайд\](../frames/$f)" "$1/transcripts/4.md" && grep -q "^\*Кадр 0:08 · 08:58 — Синий слайд\*" "$1/transcripts/4.md" && grep -q "Текст на кадре" "$1/transcripts/4.md"' _ "$A"
check "picks: nothing left to pick" bash -c '"$1" frames -1001234 | grep -q "no video waits"' _ "$TGA"
check "render: summary.md kept and linked from the index" bash -c 'grep -q "hand-written" "$1/summary.md" && grep -q "(summary.md)" "$1/index.md"' _ "$A"
check "render: links still resolve with frames" python3 -I -B "$T/links.py" "$TG_ARCHIVE_ROOT"

# --- repeat, refresh, no-media ---
python3 -I -B -c "import json,sys; j=json.load(open(sys.argv[1])); j.pop('v'); json.dump(j, open(sys.argv[1], 'w'))" "$A/.raw/asr/2.json"
"$TGA" process -1001234 >/dev/null 2>&1
check "process: a transcript of an older version (no VAD, no filter) is redone, the others are kept" bash -c '[ "$(grep -c "^whisper" "$1")" = 3 ] && grep -q "\"v\": 2" "$2/.raw/asr/2.json"' _ "$FAKE_LOG" "$A"
n_whisper=$(grep -c '^whisper' "$FAKE_LOG")
"$TGA" run -1001234 >/dev/null 2>&1
check "repeat: no duplicate messages, whisper not run again" bash -c '[ "$(wc -l <"$1/.raw/messages.jsonl")" = 10 ] && [ "$(grep -c "^whisper" "$2")" = "$3" ]' _ "$A" "$FAKE_LOG" "$n_whisper"
n_restart=$(grep "export_history" "$FAKE_LOG" | grep -c '"restart": true')
"$TGA" export -1001234 --refresh >/dev/null 2>&1
check "--refresh: restart only on the first call" bash -c '[ "$(grep "export_history" "$1" | grep -c "\"restart\": true")" = $(($2 + 1)) ]' _ "$FAKE_LOG" "$n_restart"
"$TGA" run -1005678 --no-media >/dev/null 2>&1
B=$(ls -d "$TG_ARCHIVE_ROOT"/*-1005678 2>/dev/null | head -1)
check "--no-media: export asked without files, none imported" bash -c 'grep -q "\"chat_id\": -1005678, \"media\": false" "$1" && [ -z "$(ls -A "$2/media")" ]' _ "$FAKE_LOG" "${B:-$T/none}"
check "group: authors and the participants list" bash -c 'grep -q "· Анна · #1" "$1/messages/2026-03.md" && grep -q "Участники" "$1/index.md"' _ "${B:-$T/none}"
check "list and path" bash -c '"$1" list | grep -q -- "-1005678" && [ "$("$1" path Команда)" = "$2" ]' _ "$TGA" "${B:-$T/none}"
echo "# mine" >"$TG_ARCHIVE_ROOT/CLAUDE.md"
"$TGA" render --all >/dev/null 2>&1
check "root: a hand-written CLAUDE.md is never overwritten" grep -qx "# mine" "$TG_ARCHIVE_ROOT/CLAUDE.md"
check "hygiene: no tg-archive .pyc in the repo" bash -c '[ -z "$(find "$1/.local/bin" "$2" -name "tg*archive*.pyc" -o -path "$2/*.pyc" 2>/dev/null)" ]' _ "$REPO" "$HERE"

# --- review fixes: damaged files, odd metadata, link text, back-off ---
big="$T/src/$C1/media/8-big.mp4"
python3 -I -B -c "import sys; open(sys.argv[1], 'wb').write(b'x' * (1 << 20) + bytes(512 * 1024) + b'y' * (8 << 20))" "$big"
cat >>"$T/src/$C1/messages.jsonl" <<'EOF2'
{"id": 8, "date": "2026-02-02T10:00:00+00:00", "text": "big [one]", "media": {"kind": "document", "file": "8-big.mp4", "name": "big]x.mp4", "mime": "video/mp4", "size": 9961472}}
EOF2
"$TGA" run -1001234 --files all --no-process >"$T/run-big.out" 2>&1
check "holes: a big file with a zero-filled 512 KiB block is not imported, it is queued for a fresh download" bash -c '[ ! -e "$1/media/8-big.mp4" ] && grep -q "damaged files queued" "$2" && grep -q "\"pending\": \[" "$1/.raw/refetch.json" && grep -q 8 "$1/.raw/refetch.json"' _ "$A" "$T/run-big.out"
python3 -I -B -c "import sys; open(sys.argv[1], 'wb').write(b'x' * (10 << 20))" "$big"
"$TGA" run -1001234 --files all --no-process >/dev/null 2>&1
check "holes: the next run sends refetch once and imports the good copy" bash -c 'grep "export_history" "$1" | grep -q "\"refetch\": \"8\"" && [ -s "$2/media/8-big.mp4" ] && [ "$(grep "export_history" "$1" | grep -c "\"refetch\"")" = 1 ]' _ "$FAKE_LOG" "$A"
check "md: brackets in a file name or caption do not break the link" bash -c 'grep -q "\[big\\\]x.mp4\](../media/8-big.mp4)" "$1/messages/2026-02.md"' _ "$A"
python3 -I -B -c "import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[(1<<20):(1<<20)+(512*1024)] = bytes(512*1024); open(sys.argv[1],'wb').write(d)" "$A/media/8-big.mp4"
"$TGA" verify -1001234 >"$T/verify.out" 2>&1
check "verify: a damaged file in the archive is removed with what was made from it and queued again" bash -c '[ ! -e "$1/media/8-big.mp4" ] && grep -q "1 damaged files removed" "$2" && grep -q 8 "$1/.raw/refetch.json"' _ "$A" "$T/verify.out"
printf '\xff\xfe' >"$T/fakes/badbytes"
cat >"$T/fakes/ffmpeg" <<'EOF2'
#!/usr/bin/env bash
for x in "$@"; do case $x in *.wav) printf 'title: \xff\xfe broken\n' >&2; exit 1 ;; esac; done
exec /usr/bin/ffmpeg "$@"
EOF2
chmod +x "$T/fakes/ffmpeg"
rm -f "$A/.raw/asr/2.json"
"$TGA" process -1001234 >"$T/proc-bad.out" 2>&1
check "process: non-UTF-8 ffmpeg output does not crash; the file is recorded and render still runs" bash -c '[ $? -eq 0 ] && grep -q "\"2\"" "$1/.raw/process-failed.json" && [ -s "$1/index.md" ]' _ "$A"
rm -f "$T/fakes/ffmpeg"
: >"$T/idle"     # the fake gateway reports no progress while this file exists
TG_ARCHIVE_BACKOFF=0.001 timeout 20 "$TGA" export -1005678 --no-media >"$T/idle.out" 2>&1
rc=$?
rm -f "$T/idle"
check "back-off: no progress makes tg-archive wait between calls, doubling, then give up with exit 1" bash -c 'grep -q "no progress, waiting 0.001 s" "$1" && grep -q "no progress, waiting 0.002 s" "$1" && grep -q "no progress for 12 export calls" "$1" && [ "$2" = 1 ]' _ "$T/idle.out" "$rc"

# --- the choices of a chat (.raw/settings.json), files queued again without --refresh, a restarting service ---
ff -f lavfi -i "sine=frequency=500:duration=2" "$T/src/$C1/media/9-talk.ogg"
cat >>"$T/src/$C1/messages.jsonl" <<'EOF2'
{"id": 9, "date": "2026-02-03T10:00:00+00:00", "text": "long talk", "media": {"kind": "audio", "file": "9-talk.ogg", "name": "talk.ogg", "size": 943718400}}
EOF2
"$TGA" run -1001234 --max-file-mb 500 --no-process >/dev/null 2>&1
check "--max-file-mb: sent to the service, the 900 MB file is skipped and the choice saved" bash -c 'grep "export_history" "$1" | tail -1 | grep -q "\"max_file_mb\": 500" && [ ! -e "$2/media/9-talk.ogg" ] && grep -q "\"max_file_mb\": 500" "$2/.raw/settings.json" && grep -q "\"files\": \"all\"" "$2/.raw/settings.json"' _ "$FAKE_LOG" "$A"
check "status: the choice and the files skipped as too big" bash -c 'out=$("$1" status -1001234); grep -q "up to 500 MB each" <<<"$out" && grep -q "skipped as too big: 1 files, 900.0 MB" <<<"$out"' _ "$TGA"
n_calls=$(grep -c export_history "$FAKE_LOG")
"$TGA" run -1001234 --no-process >/dev/null 2>&1
check "update: a plain run keeps the saved choice (all kinds, 500 MB) and asks for nothing again" bash -c 'grep "export_history" "$1" | tail -n +$(($2 + 1)) | grep -q "\"kinds\": \"all\", \"max_file_mb\": 500" && ! grep "export_history" "$1" | tail -n +$(($2 + 1)) | grep -q "\"refetch\"" && [ ! -e "$3/media/9-talk.ogg" ]' _ "$FAKE_LOG" "$n_calls" "$A"
: >"$T/http503"
TG_ARCHIVE_RECONNECT=10 TG_ARCHIVE_BACKOFF=0.01 "$TGA" run -1001234 --max-file-mb 2000 --no-process >"$T/run-raise.out" 2>&1
check "--max-file-mb larger: the skipped file is asked for again (refetch, no history re-read) and imported" bash -c 'grep "export_history" "$1" | grep -q "\"refetch\": \"9\"" && ! grep "export_history" "$1" | tail -2 | grep -q "\"restart\"" && [ -s "$2/media/9-talk.ogg" ]' _ "$FAKE_LOG" "$A"
check "restarting service: HTTP 503 makes tg-archive reconnect and go on" bash -c 'grep -q "gateway answered HTTP 503; waiting up to 10 s for the gateway (1/5)" "$1" && grep -q "ready:" "$1" && [ ! -e "$2" ]' _ "$T/run-raise.out" "$T/http503"
"$TGA" run -1005678 --files photo --no-process >/dev/null 2>&1
check "--files after --no-media: files turn on, the never-queued photo is asked for without --refresh" bash -c 'grep "export_history" "$1" | grep -q "\"chat_id\": -1005678, \"media\": true, \"max_seconds\": 40, \"kinds\": \"photo\", \"refetch\": \"3\"" && [ -s "$2/media/3-pic.jpg" ]' _ "$FAKE_LOG" "${B:-$T/none}"

# --- folders of chats, forum topics ---
check "folder: a path as --folder exits 2" bash -c '"$1" run x --folder ../x >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"
"$TGA" run -1009999 --folder Community >/dev/null 2>&1
F=$(ls -d "$TG_ARCHIVE_ROOT"/Community/*-1009999 2>/dev/null | head -1)
F=${F:-$T/none}
check "folder: --folder keeps the archive in ROOT/FOLDER/; list, path and both indexes see it" bash -c '[ -d "$1" ] && "$2" list | grep -q -- "-1009999" && [ "$("$2" path Спільнота)" = "$1" ] && grep -q "^## \[Community\](Community/index.md)" "$3/index.md" && grep -q "(Community/${1##*/}/index.md)" "$3/index.md" && grep -q "(${1##*/}/index.md)" "$3/Community/index.md" && [ ! -e "$3/Community/CLAUDE.md" ]' _ "$F" "$TGA" "$TG_ARCHIVE_ROOT"
check "forum: one folder per topic (a renamed topic under its latest title), General for the rest" bash -c 'grep -q "перший челендж" "$1/messages/челенджі-2026/2026-04.md" && grep -q "нейромережі" "$1/messages/ai/2026-04.md" && grep -q "загальне питання" "$1/messages/general/2026-04.md" && [ ! -e "$1/messages/2026-04.md" ]' _ "$F"
check "forum: a reply links inside its topic, a photo two folders up" bash -c 'grep -q "↩ ответ на \[#11\](2026-04.md#m11)" "$1/messages/челенджі-2026/2026-04.md" && grep -q "(../../media/17-pic.jpg)" "$1/messages/ai/2026-04.md"' _ "$F"
check "forum: the index lists the topics, every topic has its month index" bash -c 'grep -q "^## Темы" "$1/index.md" && grep -q "\[Челенджі 2026\](messages/челенджі-2026/index.md) — 4," "$1/index.md" && grep -q "\[2026-04\](2026-04.md) — 3" "$1/messages/ai/index.md"' _ "$F"
check "forum: every relative link and anchor resolves" python3 -I -B "$T/links.py" "$TG_ARCHIVE_ROOT"
NP="$F/notion/гайд-aaaaaaaa.md"
check "notion: a linked public page becomes notion/<title>-<id>.md (both chunks, heading, bold, link, nested list)" bash -c 'grep -q "^# 📘 Гайд" "$1" && grep -q "^### Розділ" "$1" && grep -q "Це \*\*жирний\*\* і \[посилання\](https://example.org/x)" "$1" && grep -q "^  - вкладений" "$1" && grep -q "Кінець гайду" "$1"' _ "$NP"
check "notion: image downloaded beside it, sub-page fetched and linked both ways, database as a table" bash -c 'grep -q "!\[Схема\](media/n-img.png)" "$1" && [ -s "$2/notion/media/n-img.png" ] && grep -q "📄 \[Глава 2\](глава-2-bbbbbbbb.md)" "$1" && grep -q "Текст глави" "$2/notion/глава-2-bbbbbbbb.md" && grep -q "раздел: \[Гайд\](гайд-aaaaaaaa.md)" "$2/notion/глава-2-bbbbbbbb.md" && grep -q "^| Назва | Статус |" "$1" && grep -q "^| Перша | готово |" "$1"' _ "$NP" "$F"
check "notion: the page names the message, the message links the page, a closed page is said to be closed" bash -c 'grep -q "в чате: \[2026-04 #18\](../messages/general/2026-04.md#m18)" "$1" && grep -q -- "- Notion: \[Гайд\](../../notion/гайд-aaaaaaaa.md)" "$2/messages/general/2026-04.md" && grep -q -- "- Notion: страница закрыта" "$2/messages/general/2026-04.md" && grep -q "закрыта, нет доступа" "$2/index.md"' _ "$NP" "$F"
YT="$F/transcripts/yt-abcdefghijk.md"
check "youtube: the linked stream is downloaded, transcribed, timed from its live start, ↗ to the same second" bash -c '[ -s "$2/media/yt-abcdefghijk.mp4" ] && grep -q "^# YouTube: Стрім про AI" "$1" && grep -q "^Записано: 2026-04-05 18:00 (начало стрима на YouTube)" "$1" && grep -q "^\*\*\[0:00\](../media/yt-abcdefghijk.mp4#t=0) · 18:00\*\* \[↗\](https://www.youtube.com/watch?v=abcdefghijk&t=0s) Это расшифровка номер один" "$1" && grep -q "Слайди" "$1"' _ "$YT" "$F"
check "youtube: page and message link each other, the Notion block too, a private video is named" bash -c 'grep -q "Ссылки в чате: \[2026-04 #18\](../messages/general/2026-04.md#m18), \[Notion: Гайд\](../notion/гайд-aaaaaaaa.md)" "$1" && grep -q -- "- YouTube 0:16: \[Стрім про AI\](../../transcripts/yt-abcdefghijk.md)" "$2/messages/general/2026-04.md" && grep -q -- "- YouTube: недоступно (\[youtube\] zzzzzzzzzzz: Private video)" "$2/messages/general/2026-04.md" && grep -q "../transcripts/yt-abcdefghijk.md" "$3" && grep -q "^## YouTube по ссылкам из чата" "$2/index.md"' _ "$YT" "$F" "$NP"
check "youtube: its frames wait for the agent like a video message" bash -c '"$1" frames -1009999 --json | grep -q "\"message\": -1,.*picks/-1.json"' _ "$TGA"
check "linked: every relative link resolves with Notion and YouTube pages" python3 -I -B "$T/links.py" "$TG_ARCHIVE_ROOT"

# --- a remote whisper over ssh (fake ssh: "up" answers like remote-whisper/run, "down" cannot connect) ---
cat >"$T/fakes/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$FAKE_LOG"
case "$*" in
  *down*) echo "ssh: connect to host down port 22: No route to host" >&2; exit 255 ;;
  *tg-whisper/run*) cat >/dev/null; printf '{"result": {"language": "uk"}, "model": "org/faster-whisper-fake", "transcription": [{"offsets": {"from": 0, "to": 3000}, "text": " Віддалена розшифровка."}]}' ;;
esac
EOF
chmod +x "$T/fakes/ssh"
rm -f "$F/.raw/asr/-1.json"
TG_ARCHIVE_REMOTE_WHISPER=user@up TG_ARCHIVE_REMOTE_MIN=10 "$TGA" process -1009999 >"$T/remote.out" 2>&1
check "remote whisper: a long file goes over ssh to the remote GPU, the transcript says so" bash -c 'grep -q "\"model\": \"faster-whisper-fake (remote)\"" "$1/.raw/asr/-1.json" && grep -q "ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 user@up tg-whisper/run auto" "$2" && grep -q "Віддалена розшифровка" "$1/transcripts/yt-abcdefghijk.md" && grep -q "remote" "$3"' _ "$F" "$FAKE_LOG" "$T/remote.out"
rm -f "$F/.raw/asr/-1.json"
TG_ARCHIVE_REMOTE_WHISPER=user@down TG_ARCHIVE_REMOTE_MIN=10 "$TGA" process -1009999 >"$T/remote-down.out" 2>&1
check "remote whisper down: its job goes back to the local whisper" bash -c 'grep -q "goes on alone" "$2" && grep -q "\"model\": \"ggml-large-v3-turbo.bin\"" "$1/.raw/asr/-1.json"' _ "$F" "$T/remote-down.out"
rm -f "$F/.raw/asr/-1.json"
TG_ARCHIVE_REMOTE_WHISPER=user@up TG_ARCHIVE_REMOTE_ALL=1 "$TGA" process -1009999 >"$T/remote-all.out" 2>&1
check "remote all: a short file goes to the remote whisper too" bash -c 'grep -q "every file on the remote whisper" "$2" && grep -q "\"model\": \"faster-whisper-fake (remote)\"" "$1/.raw/asr/-1.json"' _ "$F" "$T/remote-all.out"
check "remote: a bad target exits 2" bash -c '"$1" remote setup "a b;rm" >/dev/null 2>&1; [ $? -eq 2 ]' _ "$TGA"

# --- a channel's discussion group: its copy of post 4 (the lecture, archived in C1) and the comments on it ---
C4=-1004444 PORT=$(cat "$T/port")
mkdir -p "$T/src/$C4/media"
cp "$T/src/$C1/media/4-lecture.mp4" "$T/src/$C4/media/1-lecture.mp4"
cat >"$T/src/$C4/messages.jsonl" <<EOF
{"id": 1, "date": "2026-01-07T09:00:05+00:00", "from": {"id": -1001234, "name": "Курс Rust"}, "forwarded": {"id": -1001234, "name": "Курс Rust", "post": 4, "date": "2026-01-07T09:00:00+00:00"}, "text": "Лекция 1", "media": {"kind": "video", "file": "1-lecture.mp4", "duration": 16, "size": 9000}}
{"id": 2, "date": "2026-01-07T09:10:00+00:00", "from": {"id": 5, "name": "Анна"}, "text": "дякую за лекцію", "reply_to": 1}
{"id": 3, "date": "2026-01-07T09:11:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "а слайди будуть?", "reply_to": 2, "topic": 1}
{"id": 4, "date": "2026-01-08T10:00:00+00:00", "from": {"id": 6, "name": "Борис"}, "text": "просто розмова, стаття http://127.0.0.1:$PORT/web/article і гайд http://127.0.0.1:$PORT/files/guide.pdf"}
EOF
"$TGA" run $C4 --no-media >/dev/null 2>&1
n_calls=$(grep -c export_history "$FAKE_LOG")
"$TGA" run $C4 --files all --no-process >"$T/c4.out" 2>&1
"$TGA" render --all >/dev/null 2>&1
G4=$(ls -d "$TG_ARCHIVE_ROOT"/*-1004444 2>/dev/null | head -1)
G4=${G4:-$T/none}
check "comments: the channel copy's file is never asked for (it is in the channel's archive)" bash -c '! grep "export_history" "$1" | tail -n +$(($2 + 1)) | grep -q "\"refetch\": \"1\"" && [ -z "$(ls "$3/media" | grep "^1-")" ]' _ "$FAKE_LOG" "$n_calls" "$G4"
check "comments: a thread page per post with the comments, linking the original post in the channel archive" bash -c 'grep -q "комментарии к посту Курс Rust #4" "$1/comments/4.md" && grep -q "Оригинал: \[Курс Rust #4\](../../${2##*/}/messages/2026-01.md#m4)" "$1/comments/4.md" && grep -q "дякую за лекцію" "$1/comments/4.md" && grep -q "а слайди будуть" "$1/comments/4.md" && ! grep -q "дякую за лекцію" "$1/messages/2026-01.md" && grep -q "просто розмова" "$1/messages/2026-01.md"' _ "$G4" "$A"
check "comments: the channel post links its comments, the group index lists the threads" bash -c 'grep -q "💬 \[комментарии: 2\](../../${2##*/}/comments/4.md)" "$1/messages/2026-01.md" && grep -q "^## Комментарии к постам канала (1)" "$2/index.md" && grep -q "(comments/4.md) — комментариев 2" "$2/index.md"' _ "$A" "$G4"
"$TGA" links $C4 >/dev/null 2>&1
check "web: a linked article is kept as text (no page chrome) and linked from its message" bash -c 'f=$(grep -l "Стаття про гроші" "$1"/web/*.md) && grep -q "Перший абзац статті про \*\*гроші\*\*" "$f" && ! grep -q "меню меню" "$f" && grep -q -- "- Страница по ссылке: \[Стаття про гроші\](../web/" "$1/messages/2026-01.md"' _ "$G4"
check "files: a linked PDF is downloaded into media/ and linked from its message" bash -c 'ls "$1"/media/gd-pdf*.pdf >/dev/null 2>&1 && grep -q -- "- Файл по ссылке: \[guide.pdf\](../media/gd-pdf" "$1/messages/2026-01.md"' _ "$G4"
check "comments: every relative link resolves across the archives" python3 -I -B "$T/links.py" "$TG_ARCHIVE_ROOT"
"$TGA" run -1005678 --folder Community --no-process >/dev/null 2>&1
check "folder: --folder moves an archive that is elsewhere into the folder" bash -c '[ ! -e "$1" ] && [ -d "$2/Community/${1##*/}" ] && "$3" list | grep -q "Community/${1##*/}"' _ "${B:-$T/none}" "$TG_ARCHIVE_ROOT" "$TGA"

echo "tg-archive tests: $PASS passed, $FAILS failed, $SKIPS skipped"
[[ $FAILS -eq 0 ]]
