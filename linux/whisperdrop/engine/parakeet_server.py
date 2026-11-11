"""Loopback server with the whisper-server interface, running Parakeet v3 through sherpa-onnx.

usage: python -m whisperdrop.engine.parakeet_server --model DIR --port N --inference-path /secret [--threads N]

GET /health answers once the model is loaded. A multipart POST to the inference path with a 16 kHz 16-bit WAV
`file` field returns `verbose_json` with sentences and word times, like the Mac app's parakeet-server.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

from ..core import SAMPLE_RATE
from ..core.audio import read_wav, windows
from ..core.transcript import ends_sentence


def parse_multipart(body: bytes, content_type: str) -> tuple[dict[str, str], dict[str, bytes]]:
    boundary = None
    for part in content_type.split(";"):
        part = part.strip()
        if part.startswith("boundary="):
            boundary = part[len("boundary="):].strip('"')
    if not boundary:
        raise ValueError("Missing multipart boundary.")
    fields: dict[str, str] = {}
    files: dict[str, bytes] = {}
    delimiter = b"--" + boundary.encode()
    for chunk in body.split(delimiter):
        if not chunk or chunk.startswith(b"--"):
            continue
        chunk = chunk.removeprefix(b"\r\n")
        header_end = chunk.find(b"\r\n\r\n")
        if header_end < 0:
            continue
        headers = chunk[:header_end].decode("utf-8", "replace")
        value = chunk[header_end + 4:].removesuffix(b"\r\n")
        name = filename = None
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-disposition"):
                for item in line.split(";"):
                    item = item.strip()
                    if item.startswith("name="):
                        name = item[5:].strip('"')
                    elif item.startswith("filename="):
                        filename = item[9:].strip('"')
        if name is None:
            continue
        if filename is not None:
            files[name] = value
        else:
            fields[name] = value.decode("utf-8", "replace")
    return fields, files


class Parakeet:
    def __init__(self, folder: str, threads: int):
        import sherpa_onnx

        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(folder, "encoder.int8.onnx"),
            decoder=os.path.join(folder, "decoder.int8.onnx"),
            joiner=os.path.join(folder, "joiner.int8.onnx"),
            tokens=os.path.join(folder, "tokens.txt"),
            model_type="nemo_transducer",
            num_threads=threads,
        )
        self.lock = threading.Lock()

    def pieces(self, samples: np.ndarray) -> list[tuple[str, float, float]]:
        stream = self.recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, samples)
        self.recognizer.decode_stream(stream)
        result = stream.result
        durations = list(getattr(result, "durations", []) or [])
        out = []
        for index, (token, start) in enumerate(zip(result.tokens, result.timestamps)):
            if index < len(durations) and durations[index] > 0:
                end = start + durations[index]
            elif index + 1 < len(result.timestamps):
                end = result.timestamps[index + 1]
            else:
                end = start + 0.08
            out.append((token, float(start), float(end)))
        return out

    def transcribe(self, samples: np.ndarray, language: str | None) -> dict:
        duration = samples.size / SAMPLE_RATE
        sentences: list[list[dict]] = []
        current: list[dict] = []
        with self.lock:
            for lo, hi in windows(samples):
                piece = samples[lo:hi]
                if piece.size == 0 or float(np.max(np.abs(piece))) < 1e-4:
                    continue
                offset = lo / SAMPLE_RATE
                for text, start, end in self.pieces(piece):
                    word = {"word": text, "start": round(start + offset, 3), "end": round(end + offset, 3)}
                    current.append(word)
                    if ends_sentence(text):
                        sentences.append(current)
                        current = []
                if current:
                    # A window never ends mid-sentence in the output; the next window starts a new segment.
                    sentences.append(current)
                    current = []
        segments = []
        for sentence in sentences:
            text = "".join(w["word"] for w in sentence).strip()
            if not text:
                continue
            segments.append({"id": len(segments), "start": sentence[0]["start"], "end": sentence[-1]["end"],
                             "text": " " + " ".join(text.split()), "words": sentence})
        return {"language": language, "duration": duration,
                "text": " ".join(s["text"].strip() for s in segments), "segments": segments}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--inference-path", default="/inference")
    parser.add_argument("--threads", type=int, default=max(2, min(8, (os.cpu_count() or 4) - 2)))
    options = parser.parse_args(argv)
    if options.host not in ("127.0.0.1", "localhost"):
        print("parakeet server only listens on the loopback interface.", file=sys.stderr)
        return 2
    started = time.monotonic()
    try:
        model = Parakeet(options.model, options.threads)
        model.pieces(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
    except Exception as error:  # noqa: BLE001
        print(f"Could not load the Parakeet model: {error}", file=sys.stderr)
        return 1
    print(f"parakeet server: model ready in {time.monotonic() - started:.2f} s", file=sys.stderr, flush=True)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):  # noqa: A002
            pass

        def reply(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            if self.path == "/health":
                self.reply(200, {"status": "ok"})
            else:
                self.reply(404, {"error": "Not found."})

        def do_POST(self):  # noqa: N802
            if self.path != options.inference_path:
                self.reply(404, {"error": "Not found."})
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            try:
                fields, files = parse_multipart(body, self.headers.get("Content-Type", ""))
                samples, rate = read_wav(files["file"])
                if rate != SAMPLE_RATE:
                    raise ValueError("Send 16 kHz audio.")
            except (KeyError, ValueError) as error:
                self.reply(400, {"error": str(error) or "Send the audio as the multipart field named file."})
                return
            language = fields.get("language")
            language = None if not language or language == "auto" else language
            try:
                self.reply(200, model.transcribe(samples, language))
            except Exception as error:  # noqa: BLE001
                self.reply(500, {"error": str(error)})

    server = ThreadingHTTPServer((options.host, options.port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
