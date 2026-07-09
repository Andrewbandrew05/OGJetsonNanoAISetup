#!/usr/bin/env python3
"""Wyoming-protocol ASR bridge in front of an existing whisper.cpp HTTP
server.

This does NOT load its own whisper model. It forwards whatever audio a
Wyoming client (e.g. Home Assistant) streams to it straight to the
already-running whisper.cpp `server` binary's own /inference endpoint
(installed by whisper.cppSetup), and relays the transcription back. That's
deliberate: it exists so there's exactly one whisper model/process on the
box, not a second one loaded by this bridge too.
"""

import argparse
import asyncio
import io
import logging
import wave
from functools import partial

import requests
from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import AsrModel, AsrProgram, Attribution, Describe, Info
from wyoming.server import AsyncEventHandler, AsyncServer

_LOGGER = logging.getLogger(__name__)


class WhisperCppBridgeHandler(AsyncEventHandler):
    def __init__(self, *args, whisper_url: str, wyoming_info_event, **kwargs):
        super().__init__(*args, **kwargs)
        self.whisper_url = whisper_url
        self.wyoming_info_event = wyoming_info_event
        self._audio_buffer = bytearray()
        self._rate = 16000
        self._width = 2
        self._channels = 1

    async def handle_event(self, event: Event) -> bool:
        if AudioStart.is_type(event.type):
            start = AudioStart.from_event(event)
            self._rate = start.rate
            self._width = start.width
            self._channels = start.channels
            self._audio_buffer = bytearray()
            return True

        if AudioChunk.is_type(event.type):
            chunk = AudioChunk.from_event(event)
            self._audio_buffer.extend(chunk.audio)
            return True

        if AudioStop.is_type(event.type):
            text = await self._transcribe()
            await self.write_event(Transcript(text=text).event())
            return True

        if Transcribe.is_type(event.type):
            # Nothing to configure per-request right now (single model,
            # whisper.cpp server picks its own language handling) - just
            # acknowledge so clients that send this don't stall.
            return True

        if Describe.is_type(event.type):
            await self.write_event(self.wyoming_info_event)
            return True

        return True

    async def _transcribe(self) -> str:
        wav_bytes = self._to_wav_bytes()
        loop = asyncio.get_running_loop()
        try:
            return await loop.run_in_executor(
                None, partial(self._post_to_whisper, wav_bytes)
            )
        except Exception:
            _LOGGER.exception(
                "Failed to reach whisper.cpp server at %s - is "
                "whisper-cpp-server.service running?",
                self.whisper_url,
            )
            return ""

    def _to_wav_bytes(self) -> bytes:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wav_file:
            wav_file.setnchannels(self._channels)
            wav_file.setsampwidth(self._width)
            wav_file.setframerate(self._rate)
            wav_file.writeframes(bytes(self._audio_buffer))
        return buf.getvalue()

    def _post_to_whisper(self, wav_bytes: bytes) -> str:
        response = requests.post(
            self.whisper_url,
            files={"file": ("audio.wav", wav_bytes, "audio/wav")},
            data={"response_format": "text"},
            timeout=120,
        )
        response.raise_for_status()
        text = response.text.strip()
        # whisper.cpp's server doesn't always honor response_format=text and
        # falls back to its default JSON body ({"text": "..."}) instead -
        # unwrap that rather than passing the raw JSON through as the
        # transcript when that happens.
        content_type = response.headers.get("content-type", "")
        if "json" in content_type or text.startswith("{"):
            try:
                text = str(response.json().get("text", text)).strip()
            except ValueError:
                pass
        return text


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--uri", required=True, help="Wyoming server URI, e.g. tcp://0.0.0.0:10300"
    )
    parser.add_argument(
        "--whisper-url",
        required=True,
        help="whisper.cpp server /inference URL, e.g. http://127.0.0.1:8080/inference",
    )
    parser.add_argument("--model-name", default="whisper.cpp")
    parser.add_argument("--language", default="en")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    wyoming_info = Info(
        asr=[
            AsrProgram(
                name="wyoming-whisper-cpp-bridge",
                description=(
                    "Bridges an existing whisper.cpp server to the Wyoming "
                    "protocol - forwards audio to it directly, no separate "
                    "model loaded here."
                ),
                attribution=Attribution(
                    name="OGJetsonNanoAISetup",
                    url="https://github.com/Andrewbandrew05/OGJetsonNanoAISetup",
                ),
                installed=True,
                version="1.0.0",
                models=[
                    AsrModel(
                        name=args.model_name,
                        description=args.model_name,
                        attribution=Attribution(
                            name="ggerganov/whisper.cpp",
                            url="https://github.com/ggerganov/whisper.cpp",
                        ),
                        installed=True,
                        languages=[args.language],
                        version="1.0.0",
                    )
                ],
            )
        ],
    )
    wyoming_info_event = wyoming_info.event()

    server = AsyncServer.from_uri(args.uri)
    _LOGGER.info("Listening on %s, forwarding to %s", args.uri, args.whisper_url)
    await server.run(
        partial(
            WhisperCppBridgeHandler,
            whisper_url=args.whisper_url,
            wyoming_info_event=wyoming_info_event,
        )
    )


if __name__ == "__main__":
    asyncio.run(main())
