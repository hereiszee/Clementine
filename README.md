# 🍊 Clementine

A free, local clone of the "drag-with-Shift" file converter idea for macOS.

Start dragging any file in Finder and **hold ⇧ Shift**: a wheel of output formats pops up around the pointer.
Drop the file on a format and the converted copy is saved **right beside the original**.
Hold **⌥ Option + ⇧ Shift** instead and the wheel fills with **tools** for that kind of file.
Drop in the middle of the wheel to cancel. Everything runs on your Mac; nothing is uploaded.

You can also pick files from the menu bar icon (**Convert Files…** / **Tools for Files…**) and click a slice.

## Install

Requirements: macOS 13 Ventura or later, Xcode Command Line Tools (`xcode-select --install`).
For video and audio, install ffmpeg with [Homebrew](https://brew.sh): `brew install ffmpeg`.

```bash
git clone https://github.com/hereiszee/Clementine.git
cd Clementine
scripts/build-app.sh --install     # builds Clementine.app, copies it to /Applications and launches it
```

Look for the citrus slice in the menu bar. Turn on **Open at Login** from its menu if you want it always running.
No Accessibility or Input Monitoring permission is needed. Clementine only watches the mouse button and the drag pasteboard.

Each push also gets a ready-built `Clementine.app` as an artifact on the repo's **Actions** tab (Build & Test → Clementine-app).

## What it does

### Convert (⇧ Shift)
| Files | Formats |
|---|---|
| Images | JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, PDF, Text (OCR). GIF → MP4/WebM |
| Video | MP4, MOV, MKV, AVI, WMV, WebM, GIF, MP3, M4A, WAV |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF |
| PDF | JPG / PNG / TIFF (every page), TXT, DOCX, RTF, HTML, EPUB |
| Documents (TXT, MD, RTF, DOC, DOCX, ODT, HTML) | PDF, DOCX, TXT, RTF, HTML, ODT, EPUB, Markdown |
| Pages / Keynote / Numbers | PDF, DOCX, TXT, RTF, EPUB / PPTX / XLSX, CSV (uses the iWork app) |
| Subtitles | SRT, VTT, TXT |
| Archives (ZIP, TAR, TGZ, GZ, BZ2, XZ, RAR, 7Z) | Extract, ZIP, TAR, TAR.GZ |
| Folders / anything else | ZIP, TAR, TAR.GZ, DMG (one folder) |

### Tools (⌥ Option + ⇧ Shift)
- **Images:** Compress, Target Size, Resize, Crop, Adjust (brightness/contrast/saturation/rotate), Annotate (pen, box, arrow, text), Redact (black box or pixelate), Remove Background (macOS 14+), Add Background, Metadata viewer/editor, Strip Metadata, Read QR/barcodes. With several images: Make PDF, Collage
- **Video:** Compress, Target Size (two-pass), Trim, Crop (aspect or pixels), Speed, Split, Snapshot, Mute, Rotate, Metadata, Strip Metadata. With several videos: Join
- **Audio:** Compress, Target Size, Normalize (loudness), Trim, Trim Silence, Bleep, Speed, Mono, Stereo, Metadata, Strip Metadata. With several files: Join
- **PDF:** Compress, Target Size, Split, Reorder/remove pages, Rotate, Metadata, Strip Metadata. With several PDFs: Merge. PDFs and images together: Merge PDF
- **Everything:** Strip Metadata (also clears macOS extended attributes such as "downloaded from"), Zip

Drag several files at once to process them in one go. Each job shows a small progress card (top right) with cancel and **Show in Finder**.

Optional extras that are used automatically if installed: `pngquant` (better PNG compression), `gs` / Ghostscript (better PDF compression), `cwebp`, `avifenc`.

## Command line
The same engine works from Terminal, which is also how the tests run:

```bash
BIN=$(swift build -c release --show-bin-path)/Clementine
$BIN --list photo.heic
$BIN --convert PNG photo.heic
$BIN --tool "Target Size" --answer "500 KB" photo.jpg
$BIN --tool Trim --answer "0:05 - 0:30" clip.mov
```

`scripts/test-conversions.sh` generates sample files and runs about 60 real conversions and tools against them.

## Layout
- `Sources/Clementine/DragMonitor.swift`: spots file drags and the Shift / Option keys
- `Wheel.swift`: the radial menu (drop target and click target)
- `ActionCatalog.swift`: which slices appear for which files
- `ImageTools`, `Media` (+ `FFmpeg`), `PDFTools`, `DocTools`, `Archive`, `Metadata`: the converters
- `ImageEditor.swift`: crop, adjust, annotate and redact window
- `Jobs.swift`: background jobs and progress cards
