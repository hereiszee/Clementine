#!/bin/bash
# End-to-end tests: generates sample files, runs real conversions/tools through the CLI and checks the outputs.
# Requires macOS and ffmpeg (brew install ffmpeg).
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build -c release --show-bin-path)/Clementine"
[[ -x "$BIN" ]] || { echo "Build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d)"
cd "$WORK"
echo "Working in $WORK"

FAILED=0
PASSED=0

# expect OUTPUT_FILE -- clementine args…
expect() {
  local out="$1"; shift; shift
  if "$BIN" "$@" >/tmp/clementine-test.log 2>&1 && [[ -s "$out" ]]; then
    PASSED=$((PASSED + 1)); echo "  ok   $* → $out"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $* → $out"; sed 's/^/       /' /tmp/clementine-test.log
  fi
}

# --- fixtures -------------------------------------------------------------
ffmpeg -loglevel error -f lavfi -i testsrc=duration=4:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=4 \
  -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac clip.mp4
ffmpeg -loglevel error -f lavfi -i "sine=frequency=330:duration=4" -af "adelay=1000|1000,apad=pad_dur=1" tone.wav
ffmpeg -loglevel error -f lavfi -i testsrc=size=640x480 -frames:v 1 photo.png
sips -s format jpeg photo.png --out photo.jpg >/dev/null
printf 'Hello Clementine\n\nThis is the second paragraph.\n' > note.txt
textutil -convert docx note.txt -output note.docx
printf '1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n' > subs.srt
mkdir -p folder && cp note.txt photo.png folder/
(cd folder && zip -q -r ../bundle.zip .)
cp photo.png photo2.png

echo "Images"
expect photo.webp   -- --convert WEBP photo.png
expect photo.heic   -- --convert HEIC photo.png
expect photo.avif   -- --convert AVIF photo.png
expect photo.gif    -- --convert GIF photo.png
expect photo.tiff   -- --convert TIFF photo.png
expect photo.bmp    -- --convert BMP photo.png
expect photo.svg    -- --convert SVG photo.png
expect photo.pdf    -- --convert PDF photo.png
expect "photo 2.png" -- --convert PNG photo.jpg
expect "photo compressed.jpg" -- --tool Compress photo.jpg
expect "photo 20 KB.jpg" -- --tool "Target Size" --answer "20 KB" photo.jpg
expect "photo 320x240.png" -- --tool Resize --answer "50%" photo.png
expect "photo background.png" -- --tool "Add BG" --answer "#ff8800" photo.png
expect "photo clean.jpg" -- --tool "Strip Metadata" photo.jpg
expect Collage.jpg  -- --tool Collage photo.png photo2.png
expect Images.pdf   -- --tool "Make PDF" photo.png photo2.png

echo "Video"
expect clip.mov     -- --convert MOV clip.mp4
expect clip.webm    -- --convert WEBM clip.mp4
expect clip.mkv     -- --convert MKV clip.mp4
expect clip.gif     -- --convert GIF clip.mp4
expect clip.mp3     -- --convert MP3 clip.mp4
expect "clip compressed.mp4" -- --tool Compress clip.mp4
expect "clip trimmed.mp4" -- --tool Trim --answer "0:01 - 0:03" clip.mp4
expect "clip 2x.mp4" -- --tool Speed --answer 2 clip.mp4
expect "clip part 2.mp4" -- --tool Split --answer 2 clip.mp4
expect "clip at 0.02.png" -- --tool Snapshot --answer "0:02" clip.mp4
expect "clip cropped.mp4" -- --tool Crop --answer "1:1" clip.mp4
expect "clip muted.mp4" -- --tool Mute clip.mp4
expect "clip 200 KB.mp4" -- --tool "Target Size" --answer "200 KB" clip.mp4
expect "clip clean.mp4" -- --tool "Strip Metadata" clip.mp4

echo "Audio"
expect tone.mp3     -- --convert MP3 tone.wav
expect tone.flac    -- --convert FLAC tone.wav
expect tone.ogg     -- --convert OGG tone.wav
expect tone.opus    -- --convert OPUS tone.wav
expect tone.m4a     -- --convert M4A tone.wav
expect tone.aiff    -- --convert AIFF tone.wav
expect "tone normalized.wav" -- --tool Normalize tone.wav
expect "tone trimmed.wav" -- --tool "Trim Silence" tone.wav
expect "tone bleeped.wav" -- --tool Bleep --answer "0:01-0:02" tone.wav
expect "tone mono.wav" -- --tool Mono tone.wav
expect "tone compressed.m4a" -- --tool Compress tone.wav

echo "PDF"
expect "Merged.pdf" -- --tool Merge photo.pdf Images.pdf
expect "Images page 1.png" -- --convert PNG Images.pdf
expect "Images page 2.pdf" -- --tool Split --answer "" Images.pdf
expect "Images reordered.pdf" -- --tool Reorder --answer reverse Images.pdf
expect "Images compressed.pdf" -- --tool Compress Images.pdf
expect "Images rotated.pdf" -- --tool Rotate Images.pdf

echo "Documents"
expect note.pdf     -- --convert PDF note.txt
expect "note 2.docx" -- --convert DOCX note.txt
expect note.epub    -- --convert EPUB note.docx
expect note.html    -- --convert HTML note.docx
expect note.rtf     -- --convert RTF note.docx
expect "note 2.txt" -- --convert TXT note.pdf
expect subs.vtt     -- --convert VTT subs.srt

echo "Archives"
expect folder.zip   -- --convert ZIP folder
expect folder.tar.gz -- --convert TAR.GZ folder
expect bundle.tar   -- --convert TAR bundle.zip
expect bundle       -- --convert Extract bundle.zip

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
