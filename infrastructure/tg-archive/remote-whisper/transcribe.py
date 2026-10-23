"""tg-archive's remote whisper (CLAUDE.md "Telegram archive"): a 16 kHz mono WAV on stdin, whisper.cpp-style JSON on
stdout ({"result": {"language"}, "transcription": [{"offsets": {"from", "to"}, "text"}]}), faster-whisper on CUDA with
its silero VAD. Usage: run LANG (auto, uk, ru, en, ...)."""
import io
import json
import os
import sys
import wave

import numpy as np
from faster_whisper import WhisperModel

lang = sys.argv[1] if len(sys.argv) > 1 else 'auto'
name = os.environ.get('TG_WHISPER_MODEL') or 'deepdml/faster-whisper-large-v3-turbo-ct2'
with wave.open(io.BytesIO(sys.stdin.buffer.read())) as w:      # the samples as they are: no PyAV decoding
    audio = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
model = WhisperModel(name, device='cuda', compute_type='int8_float16')
segs, info = model.transcribe(audio, language=None if lang == 'auto' else lang, beam_size=5, vad_filter=True)
out = [{'offsets': {'from': int(s.start * 1000), 'to': int(s.end * 1000)}, 'text': s.text} for s in segs]
json.dump({'result': {'language': info.language}, 'model': name, 'transcription': out}, sys.stdout, ensure_ascii=False)
