#!/usr/bin/python3 -I
# PreToolUse hook for claude-unlocked: gateway models receive an image as its
# base64 text, so one screenshot costs 100k+ tokens and the model cannot see it.
# Blocks Read on image files; exit 2 sends stderr back to the model as the reason.
import json
import os
import sys

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".ico", ".heic", ".avif"}

try:
    event = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

path = str((event.get("tool_input") or {}).get("file_path") or "")
if os.path.splitext(path)[1].lower() not in IMAGE_EXTENSIONS:
    sys.exit(0)

print(
    f"Reading {path} is blocked: this model cannot see images. The file would reach it as "
    "base64 text costing 100k+ tokens and overflowing the context. Inspect it with text "
    "instead: tesseract for OCR, identify/exiftool for size and metadata, or python (PIL) "
    "to sample pixel colors or crop and OCR a region.",
    file=sys.stderr,
)
sys.exit(2)
