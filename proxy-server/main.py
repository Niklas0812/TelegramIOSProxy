import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

# --- Configuration ---

CONFIG_PATH = Path(__file__).parent / "config.json"
SYSTEM_PROMPT_PATH = Path(__file__).parent / "system_prompt.txt"
SYSTEM_PROMPT_OUTGOING_PATH = Path(__file__).parent / "system_prompt_outgoing.txt"
SYSTEM_PROMPT_INCOMING_PATH = Path(__file__).parent / "system_prompt_incoming.txt"

with open(CONFIG_PATH) as f:
    config = json.load(f)

OPENROUTER_API_KEY = config["openrouter_api_key"]
OPENROUTER_BASE_URL = config["openrouter_base_url"]
OPENROUTER_MODEL = config["openrouter_model"]
REQUEST_TIMEOUT = config.get("request_timeout_seconds", 15)
LOG_FILE = config.get("log_file", "server.log")
HOST = config.get("host", "0.0.0.0")
PORT = config.get("port", 8081)

# --- Logging (file-only — no console output to avoid Windows terminal freezing) ---

LOG_LEVEL = config.get("log_level", "INFO").upper()

logger = logging.getLogger("translation-proxy")
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

file_handler = logging.FileHandler(Path(__file__).parent / LOG_FILE, encoding="utf-8")
file_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(file_handler)

# --- Models ---


class ContextMessage(BaseModel):
    role: str  # "me" or "them"
    text: str


class TranslateRequest(BaseModel):
    text: str
    direction: str  # "incoming" or "outgoing"
    chat_id: str = ""
    context: list[ContextMessage] = Field(default_factory=list)


class TranslateResponse(BaseModel):
    translated_text: str
    original_text: str
    direction: str
    translation_failed: bool = False


class BatchTextItem(BaseModel):
    id: str
    text: str
    direction: str = "incoming"
    chat_id: str = ""


class BatchTranslateRequest(BaseModel):
    texts: list[BatchTextItem]


class BatchResultItem(BaseModel):
    id: str
    translated_text: str
    original_text: str
    translation_failed: bool = False


class BatchTranslateResponse(BaseModel):
    results: list[BatchResultItem]


# --- Translation Service ---


class TranslationService:
    def __init__(self):
        limits = httpx.Limits(max_connections=100, max_keepalive_connections=20)
        self.client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT, limits=limits)
        self.stats = {
            "total_requests": 0,
            "successful": 0,
            "failed": 0,
            "retries": 0,
            "fallbacks": 0,
            "total_response_time_ms": 0.0,
        }
        self.last_successful_translation: Optional[float] = None
        self._prompt_cache: dict[str, str] = {}
        self._load_prompts()

    def _load_prompts(self) -> None:
        """Load all system prompts from disk into memory cache."""
        for direction, path in [
            ("incoming", SYSTEM_PROMPT_INCOMING_PATH),
            ("outgoing", SYSTEM_PROMPT_OUTGOING_PATH),
            ("legacy", SYSTEM_PROMPT_PATH),
        ]:
            try:
                self._prompt_cache[direction] = path.read_text(encoding="utf-8").strip()
            except FileNotFoundError:
                pass

    def update_prompt_cache(self, direction: str, prompt: str) -> None:
        """Update cache immediately when user edits a prompt via the API."""
        self._prompt_cache[direction] = prompt.strip()

    def _read_system_prompt(self, direction: str = "outgoing") -> str:
        if direction in self._prompt_cache:
            return self._prompt_cache[direction]
        if "legacy" in self._prompt_cache:
            return self._prompt_cache["legacy"]
        return (
            "You are a translator. Translate the given text accurately. "
            "Only output the translation, nothing else."
        )

    def _build_messages(
        self,
        text: str,
        direction: str,
        context: list[ContextMessage],
        system_prompt: str,
    ) -> list[dict]:
        messages = [{"role": "system", "content": system_prompt}]

        if context:
            context_text = "Here is the recent conversation for context (do NOT translate these, only use them to understand the conversation flow):\n\n"
            for msg in context:
                label = "Me" if msg.role == "me" else "Them"
                context_text += f"{label}: {msg.text}\n"
            context_text += "\n---\n\n"

            if direction == "outgoing":
                user_content = (
                    f"{context_text}"
                    f"Now translate the following message from English to German. "
                    f"Output ONLY the German translation, nothing else:\n\n{text}"
                )
            else:
                user_content = (
                    f"{context_text}"
                    f"Now translate the following message from German to English. "
                    f"Output ONLY the English translation, nothing else:\n\n{text}"
                )
        else:
            if direction == "outgoing":
                user_content = (
                    f"Translate the following message from English to German. "
                    f"Output ONLY the German translation, nothing else:\n\n{text}"
                )
            else:
                user_content = (
                    f"Translate the following message from German to English. "
                    f"Output ONLY the English translation, nothing else:\n\n{text}"
                )

        messages.append({"role": "user", "content": user_content})
        return messages

    async def _call_openrouter(self, messages: list[dict]) -> str:
        headers = {
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://translategram.app",
            "X-Title": "TranslateGram",
        }
        payload = {
            "model": OPENROUTER_MODEL,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 4096,
            "reasoning": {"effort": "none"},
        }

        response = await self.client.post(
            OPENROUTER_BASE_URL, headers=headers, json=payload
        )

        if response.status_code == 402:
            raise PaymentError(f"Payment required: {response.text}")
        if response.status_code == 429:
            retry_after = response.headers.get("Retry-After", "5")
            raise RateLimitError(
                f"Rate limited", retry_after=float(retry_after)
            )
        if response.status_code >= 400:
            raise OpenRouterError(
                f"HTTP {response.status_code}: {response.text}"
            )

        data = response.json()

        if "error" in data:
            error_code = data["error"].get("code", 0)
            if error_code == 402:
                raise PaymentError(f"Payment required: {data['error']}")
            if error_code == 429:
                raise RateLimitError(f"Rate limited: {data['error']}")
            raise OpenRouterError(f"API error: {data['error']}")

        choices = data.get("choices", [])
        if not choices:
            raise EmptyResponseError("No choices in response")

        content = choices[0].get("message", {}).get("content", "").strip()
        if not content:
            raise EmptyResponseError("Empty content in response")

        return content

    async def translate(self, request: TranslateRequest) -> TranslateResponse:
        self.stats["total_requests"] += 1
        start_time = time.time()

        system_prompt = self._read_system_prompt(request.direction)
        messages = self._build_messages(
            request.text, request.direction, request.context, system_prompt
        )

        translated_text = None
        translation_failed = False

        try:
            translated_text = await self._retry_translate(messages)
        except TranslationExhaustedError:
            logger.error(
                f"EXHAUSTED chat_id={request.chat_id} "
                f"direction={request.direction} text_len={len(request.text)}"
            )
            translated_text = request.text
            translation_failed = True
            self.stats["failed"] += 1
            self.stats["fallbacks"] += 1

        elapsed_ms = (time.time() - start_time) * 1000
        self.stats["total_response_time_ms"] += elapsed_ms

        if not translation_failed:
            self.stats["successful"] += 1
            self.last_successful_translation = time.time()

        logger.info(
            f"chat_id={request.chat_id} dir={request.direction} "
            f"ctx={len(request.context)} len={len(request.text)} "
            f"ms={elapsed_ms:.0f} fail={translation_failed} "
            f"| {request.text[:80]} -> {translated_text[:80] if translated_text else 'NONE'}"
        )


        return TranslateResponse(
            translated_text=translated_text,
            original_text=request.text,
            direction=request.direction,
            translation_failed=translation_failed,
        )

    async def _retry_translate(self, messages: list[dict]) -> str:
        last_exception = None

        for attempt in range(3):
            try:
                return await self._call_openrouter(messages)
            except Exception as e:
                last_exception = e
                self.stats["retries"] += 1
                logger.warning(
                    f"Attempt {attempt + 1}/3 failed "
                    f"({type(e).__name__}: {e})"
                )

        raise TranslationExhaustedError(
            f"All 3 attempts failed. Last error: {last_exception}"
        )


# --- Custom Exceptions ---


class OpenRouterError(Exception):
    pass


class EmptyResponseError(OpenRouterError):
    pass


class PaymentError(OpenRouterError):
    pass


class RateLimitError(OpenRouterError):
    def __init__(self, message: str, retry_after: float = 5.0):
        super().__init__(message)
        self.retry_after = retry_after


class TranslationExhaustedError(Exception):
    pass


# --- FastAPI App ---

SERVER_START_TIME = time.time()
translation_service = TranslationService()

app = FastAPI(title="TranslateGram Proxy", version="1.0.0")


@app.post("/translate", response_model=TranslateResponse)
async def translate(request: TranslateRequest):
    if not request.text.strip():
        return TranslateResponse(
            translated_text=request.text,
            original_text=request.text,
            direction=request.direction,
            translation_failed=False,
        )
    return await translation_service.translate(request)


@app.post("/translate/batch", response_model=BatchTranslateResponse)
async def translate_batch(request: BatchTranslateRequest):
    if not request.texts:
        return BatchTranslateResponse(results=[])

    logger.info(f"batch items={len(request.texts)}")

    async def translate_one(item: BatchTextItem) -> BatchResultItem:
        if not item.text.strip():
            return BatchResultItem(
                id=item.id,
                translated_text=item.text,
                original_text=item.text,
            )
        req = TranslateRequest(
            text=item.text,
            direction=item.direction,
            chat_id=item.chat_id,
        )
        resp = await translation_service.translate(req)
        return BatchResultItem(
            id=item.id,
            translated_text=resp.translated_text,
            original_text=resp.original_text,
            translation_failed=resp.translation_failed,
        )

    results = await asyncio.gather(*(translate_one(item) for item in request.texts))
    return BatchTranslateResponse(results=list(results))


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "uptime_seconds": round(time.time() - SERVER_START_TIME, 1),
        "last_successful_translation": translation_service.last_successful_translation,
    }


class PromptUpdate(BaseModel):
    prompt: str


def _get_prompt_path(direction: str) -> Path:
    if direction == "incoming":
        return SYSTEM_PROMPT_INCOMING_PATH
    elif direction == "outgoing":
        return SYSTEM_PROMPT_OUTGOING_PATH
    return SYSTEM_PROMPT_PATH


@app.get("/prompt")
async def get_prompt():
    try:
        content = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        content = ""
    return {"prompt": content}


@app.post("/prompt")
async def set_prompt(update: PromptUpdate):
    stripped = update.prompt.strip()
    if len(stripped) < 10:
        raise HTTPException(status_code=400, detail="Prompt too short (min 10 chars)")
    SYSTEM_PROMPT_PATH.write_text(update.prompt, encoding="utf-8")
    translation_service.update_prompt_cache("legacy", update.prompt)
    logger.info(f"System prompt updated ({len(update.prompt)} chars)")
    return {"status": "ok", "length": len(update.prompt)}


@app.get("/prompt/{direction}")
async def get_prompt_by_direction(direction: str):
    path = _get_prompt_path(direction)
    try:
        content = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        # Fall back to legacy single file
        try:
            content = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8")
        except FileNotFoundError:
            content = ""
    return {"prompt": content, "direction": direction}


@app.post("/prompt/{direction}")
async def set_prompt_by_direction(direction: str, update: PromptUpdate):
    stripped = update.prompt.strip()
    if len(stripped) < 10:
        raise HTTPException(status_code=400, detail="Prompt too short (min 10 chars)")
    path = _get_prompt_path(direction)
    path.write_text(update.prompt, encoding="utf-8")
    translation_service.update_prompt_cache(direction, update.prompt)
    logger.info(f"System prompt ({direction}) updated ({len(update.prompt)} chars)")
    return {"status": "ok", "direction": direction, "length": len(update.prompt)}


@app.get("/")
async def root():
    return {"status": "ok"}


@app.get("/stats")
async def stats():
    s = translation_service.stats
    total = s["total_requests"]
    avg_ms = (s["total_response_time_ms"] / total) if total > 0 else 0
    return {
        "total_requests": total,
        "successful": s["successful"],
        "failed": s["failed"],
        "retries": s["retries"],
        "fallbacks": s["fallbacks"],
        "success_rate": round(s["successful"] / total, 4) if total > 0 else 0,
        "avg_response_time_ms": round(avg_ms, 1),
    }


# --- OTA Install ---

OTA_DIR = Path(__file__).parent / "ota"
OTA_BUNDLE_ID = "com.niklas.translategram"
OTA_APP_TITLE = "TranslateGram"
OTA_BUNDLE_VERSION = "11.13"


@app.head("/ota/app.ipa")
async def ota_ipa_head():
    ipa_path = OTA_DIR / "app.ipa"
    if not ipa_path.exists():
        raise HTTPException(status_code=404, detail="IPA not found")
    return Response(
        headers={"Content-Length": str(ipa_path.stat().st_size), "Content-Type": "application/octet-stream"},
    )


@app.get("/ota/app.ipa")
async def ota_ipa():
    ipa_path = OTA_DIR / "app.ipa"
    if not ipa_path.exists():
        raise HTTPException(status_code=404, detail="IPA not found")
    file_size = ipa_path.stat().st_size

    def iter_file():
        with open(ipa_path, "rb") as f:
            while chunk := f.read(1024 * 1024):  # 1MB chunks
                yield chunk

    return StreamingResponse(
        iter_file(),
        media_type="application/octet-stream",
        headers={
            "Content-Length": str(file_size),
            "Content-Disposition": "attachment; filename=TranslateGram.ipa",
        },
    )


@app.get("/ota/manifest.plist")
async def ota_manifest(request: Request):
    base_url = str(request.base_url).rstrip("/")
    ipa_url = f"{base_url}/ota/app.ipa"
    manifest = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>{ipa_url}</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>{OTA_BUNDLE_ID}</string>
                <key>bundle-version</key>
                <string>{OTA_BUNDLE_VERSION}</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>{OTA_APP_TITLE}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>"""
    return Response(content=manifest, media_type="application/xml")


@app.get("/ota", response_class=HTMLResponse)
async def ota_install_page(request: Request):
    base_url = str(request.base_url).rstrip("/")
    manifest_url = f"{base_url}/ota/manifest.plist"
    install_url = f"itms-services://?action=download-manifest&url={manifest_url}"
    html = f"""<!DOCTYPE html>
<html>
<head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Install {OTA_APP_TITLE}</title>
    <style>
        body {{ font-family: -apple-system, sans-serif; text-align: center; padding: 60px 20px; background: #f5f5f7; }}
        h1 {{ font-size: 24px; color: #1d1d1f; }}
        p {{ color: #6e6e73; margin: 10px 0 30px; }}
        a.btn {{ display: inline-block; padding: 16px 40px; background: #007aff; color: white;
                 text-decoration: none; border-radius: 12px; font-size: 18px; font-weight: 600; }}
        a.btn:active {{ background: #0056b3; }}
        .note {{ margin-top: 30px; font-size: 13px; color: #86868b; }}
    </style>
</head>
<body>
    <h1>{OTA_APP_TITLE}</h1>
    <p>Tap the button below to install on this device.</p>
    <a class="btn" href="{install_url}">Install App</a>
    <p class="note">Open this page in Safari on your iPhone.</p>
</body>
</html>"""
    return html


if __name__ == "__main__":
    import uvicorn

    logger.info(f"Starting TranslateGram backend on {HOST}:{PORT} model={OPENROUTER_MODEL}")
    uvicorn.run(app, host=HOST, port=8081, log_level="warning")
