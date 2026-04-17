import asyncio
import json
import logging
import re
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
    sender_account_id: str = ""  # The logged-in TG account's peer ID (for claim checking)
    # When true, iOS detected that both sender and target have at least one
    # message in this chat — i.e. an already-active conversation. In that case
    # the claim check is bypassed so the sender isn't locked out mid-chat by
    # a stale claim from a different account.
    has_two_sided_history: bool = False
    context: list[ContextMessage] = Field(default_factory=list)


class TranslateResponse(BaseModel):
    translated_text: str
    original_text: str
    direction: str
    translation_failed: bool = False
    user_claimed: bool = False  # Target user is claimed by a different account
    claimed_by: str = ""        # Which account claimed the target


class ClaimRequest(BaseModel):
    """Dedicated pre-flight claim registration call, independent of /translate.
    iOS fires this for EVERY outgoing send so the claim system isn't coupled
    to whether the message takes the translation path."""
    sender_account_id: str
    chat_id: str
    has_two_sided_history: bool = False


class ClaimResponse(BaseModel):
    allowed: bool  # True = send can proceed; False = blocked by another account's claim
    user_claimed: bool = False
    claimed_by: str = ""


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


# --- Claim Store (cross-account user claiming) ---


class ClaimStore:
    """In-memory dict + JSON file persistence for tracking which TG account
    has 'claimed' a target user. Ultra-fast O(1) lookups.

    Data model: { target_user_id: sender_account_id }
    """

    CLAIMS_PATH = Path(__file__).parent / "claims.json"

    def __init__(self):
        self._claims: dict[str, str] = {}
        self._load()

    def _load(self):
        try:
            data = json.loads(self.CLAIMS_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                self._claims = data
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        logger.info(f"Claims loaded: {len(self._claims)} entries")

    def _save(self):
        tmp = self.CLAIMS_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._claims, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.CLAIMS_PATH)

    def check_and_claim(self, target_id: str, sender_id: str) -> tuple[bool, str]:
        """Returns (is_blocked, claimed_by).
        If not blocked, claims the target for sender."""
        if not target_id or not sender_id:
            return (False, "")
        existing = self._claims.get(target_id)
        if existing and existing != sender_id:
            return (True, existing)
        if not existing:
            self._claims[target_id] = sender_id
            self._save()
            logger.info(f"CLAIM NEW: target={target_id} claimed_by={sender_id}")
        return (False, "")

    def register_if_unclaimed(self, target_id: str, sender_id: str) -> None:
        """Record a claim for sender only if the target is not already claimed.
        Never blocks, never overwrites — used on the two-sided-history bypass
        path so a new ongoing conversation gets tracked without locking anyone
        out when a prior claim exists from another account."""
        if not target_id or not sender_id:
            return
        if target_id not in self._claims:
            self._claims[target_id] = sender_id
            self._save()
            logger.info(f"CLAIM NEW (bypass): target={target_id} claimed_by={sender_id}")

    def get_all(self) -> dict[str, str]:
        return dict(self._claims)

    def release(self, target_id: str) -> bool:
        if target_id in self._claims:
            del self._claims[target_id]
            self._save()
            logger.info(f"CLAIM RELEASED: target={target_id}")
            return True
        return False

    def release_all_by_sender(self, sender_id: str) -> int:
        to_remove = [k for k, v in self._claims.items() if v == sender_id]
        for k in to_remove:
            del self._claims[k]
        if to_remove:
            self._save()
            logger.info(f"CLAIM RELEASED: {len(to_remove)} targets for sender={sender_id}")
        return len(to_remove)


# --- Translation Service ---


class TranslationService:
    # Static translation maps — skip AI, return known translation instantly.
    # Key: lowercased word. Value: translated word (lowercase).
    # Words mapping to themselves are identical in both languages.
    STATIC_OUTGOING: dict[str, str] = {
        # Actual translations EN→DE
        "hello": "hallo", "yes": "ja", "no": "nein",
        # Normalizations (same both directions)
        "okey": "okay", "oke": "okay", "okee": "okay", "oki": "okay",
        # Identical in both languages
        "hey": "hey", "hi": "hi", "ok": "ok", "okay": "okay", "okok": "okok",
        "hmm": "hmm", "hmmm": "hmmm", "hm": "hm", "mhm": "mhm", "mhh": "mhh",
        "haha": "haha", "hehe": "hehe", "lol": "lol",
        "wow": "wow", "nice": "nice", "cool": "cool", "super": "super",
        "fit": "fit", "standard": "standard", "premium": "premium", "basic": "basic",
        "cam": "cam", "chat": "chat", "start": "start", "done": "fertig",
        "moment": "moment", "min": "min",
        "baby": "baby", "babe": "babe", "bro": "bro", "daddy": "daddy", "honey": "honey",
        "paypal": "paypal", "paysafe": "paysafe", "sparkasse": "sparkasse",
        "telegram": "telegram", "screenshot": "screenshot",
        "cc": "cc", "pp": "pp",
    }

    STATIC_INCOMING: dict[str, str] = {
        # Actual translations DE→EN
        "hallo": "hello", "ja": "yes", "nein": "no", "fertig": "done",
        # Normalizations (same both directions)
        "okey": "okay", "oke": "okay", "okee": "okay", "oki": "okay",
        # Identical in both languages (same as outgoing)
        "hey": "hey", "hi": "hi", "ok": "ok", "okay": "okay", "okok": "okok",
        "hmm": "hmm", "hmmm": "hmmm", "hm": "hm", "mhm": "mhm", "mhh": "mhh",
        "haha": "haha", "hehe": "hehe", "lol": "lol",
        "wow": "wow", "nice": "nice", "cool": "cool", "super": "super",
        "fit": "fit", "standard": "standard", "premium": "premium", "basic": "basic",
        "cam": "cam", "chat": "chat", "start": "start", "done": "done",
        "moment": "moment", "min": "min",
        "baby": "baby", "babe": "babe", "bro": "bro", "daddy": "daddy", "honey": "honey",
        "paypal": "paypal", "paysafe": "paysafe", "sparkasse": "sparkasse",
        "telegram": "telegram", "screenshot": "screenshot",
        "hello": "hello", "yes": "yes", "no": "no", "done": "done",
        "cc": "cc", "pp": "pp",
    }

    @staticmethod
    def _apply_case(source: str, target: str) -> str:
        """Apply the case pattern of source to target."""
        if source.isupper():
            return target.upper()
        if source and source[0].isupper():
            return target[0].upper() + target[1:] if target else target
        return target

    @staticmethod
    def _try_static_translate(text: str, direction: str) -> str | None:
        """Try to translate using static maps. Returns translated text or None."""
        stripped = text.strip()
        if not stripped:
            return stripped

        # Pure punctuation, numbers, symbols, emoji — return as-is
        if re.fullmatch(r'[\W\d\s€$@#]+', stripped, re.UNICODE):
            return stripped

        # Split into: leading non-letters, single word (letters only), trailing non-letters
        # Multi-word text won't match → returns None → goes to AI
        match = re.fullmatch(r'([^a-zA-Z]*?)([a-zA-Z]+)([^a-zA-Z]*)', stripped)
        if not match:
            return None  # Multi-word or complex text — use AI

        prefix, word, suffix = match.group(1), match.group(2), match.group(3)
        word_lower = word.lower()

        word_map = (
            TranslationService.STATIC_OUTGOING if direction == "outgoing"
            else TranslationService.STATIC_INCOMING
        )

        # Exact match in static map
        if word_lower in word_map:
            translated = TranslationService._apply_case(word, word_map[word_lower])
            return prefix + translated + suffix

        # Regex: hey, heyy, heyyy, ... → return as-is
        if re.fullmatch(r'he(y+)', word_lower):
            return stripped

        # Regex: hi, hii, hiii, ... → return as-is
        if re.fullmatch(r'h(i+)', word_lower):
            return stripped

        # Regex: huhu, huhuhu, ... → return as-is
        if re.fullmatch(r'(hu){2,}', word_lower):
            return stripped

        return None  # Not a static translation — use AI

    CACHE_PATH = Path(__file__).parent / "translation_cache.json"

    def __init__(self):
        limits = httpx.Limits(max_connections=100, max_keepalive_connections=20)
        self.client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT, limits=limits)
        self.stats = {
            "total_requests": 0,
            "successful": 0,
            "failed": 0,
            "retries": 0,
            "fallbacks": 0,
            "cache_hits": 0,
            "inflight_dedup_hits": 0,
            "total_response_time_ms": 0.0,
        }
        self.last_successful_translation: Optional[float] = None
        self._prompt_cache: dict[str, str] = {}
        self._translation_cache: dict[str, str] = self._load_translation_cache()
        # In-flight request deduplication. When two identical (text, direction)
        # requests arrive within the AI-call window, the second awaits the first's
        # result instead of firing another OpenRouter call. Prevents pile-up on
        # duplicate traffic (observed in prod: same text fired 480ms apart, both
        # missed the cache and both hit the API).
        self._inflight: dict[str, asyncio.Future] = {}
        self._load_prompts()
        logger.info(f"Translation cache loaded: {len(self._translation_cache)} entries")

    def _load_translation_cache(self) -> dict[str, str]:
        try:
            data = json.loads(self.CACHE_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except (FileNotFoundError, json.JSONDecodeError, ValueError):
            pass
        return {}

    def _save_translation_cache(self) -> None:
        tmp = self.CACHE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._translation_cache, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.CACHE_PATH)

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

    FALLBACK_MODELS = [
        "deepseek/deepseek-v3.2",
        "z-ai/glm-4.7",
    ]

    async def _call_openrouter(self, messages: list[dict], model: str | None = None) -> str:
        headers = {
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://translategram.app",
            "X-Title": "TranslateGram",
        }
        payload = {
            "model": model or OPENROUTER_MODEL,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 4096,
        }
        if "grok" in (model or OPENROUTER_MODEL):
            payload["reasoning"] = {"effort": "none"}

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

        # Detect content_filter — don't retry same model, fall back immediately
        finish_reason = choices[0].get("finish_reason", "")
        if finish_reason == "content_filter":
            raise ContentFilterError(f"Content filter triggered on {model or OPENROUTER_MODEL}")

        content = (choices[0].get("message", {}).get("content") or "").strip()
        if not content:
            raise EmptyResponseError("Empty content in response")

        return content

    async def translate(self, request: TranslateRequest) -> TranslateResponse:
        self.stats["total_requests"] += 1

        # Static translation: skip API call for known words/patterns
        static_result = self._try_static_translate(request.text, request.direction)
        if static_result is not None:
            self.stats["successful"] += 1
            logger.info(
                f"chat_id={request.chat_id} dir={request.direction} "
                f"len={len(request.text)} STATIC "
                f"| {request.text[:80]} -> {static_result[:80]}"
            )
            return TranslateResponse(
                translated_text=static_result,
                original_text=request.text,
                direction=request.direction,
                translation_failed=False,
            )

        # Cache lookup: exact match on text + direction
        cache_key = request.text + "\x00" + request.direction
        cached = self._translation_cache.get(cache_key)
        if cached is not None:
            self.stats["cache_hits"] += 1
            self.stats["successful"] += 1
            logger.info(
                f"chat_id={request.chat_id} dir={request.direction} "
                f"len={len(request.text)} CACHE "
                f"| {request.text[:80]} -> {cached[:80]}"
            )
            return TranslateResponse(
                translated_text=cached,
                original_text=request.text,
                direction=request.direction,
                translation_failed=False,
            )

        # In-flight dedup: if an identical (text, direction) request is already
        # mid-flight, await its result instead of firing a second OpenRouter call.
        # The existing cache-race hole (two copies of the same text arriving
        # <500ms apart both missing the cache and both hitting the API) is closed
        # here — the second caller attaches to the first's future.
        inflight = self._inflight.get(cache_key)
        if inflight is not None:
            try:
                deduped = await inflight
                self.stats["inflight_dedup_hits"] += 1
                self.stats["successful"] += 1
                logger.info(
                    f"chat_id={request.chat_id} dir={request.direction} "
                    f"len={len(request.text)} INFLIGHT "
                    f"| {request.text[:80]} -> {deduped[:80]}"
                )
                return TranslateResponse(
                    translated_text=deduped,
                    original_text=request.text,
                    direction=request.direction,
                    translation_failed=False,
                )
            except Exception:
                # First request failed — fall through and try our own fresh call.
                pass

        # Register this request as in-flight so any later duplicate waits on us.
        loop = asyncio.get_running_loop()
        future: asyncio.Future = loop.create_future()
        self._inflight[cache_key] = future

        start_time = time.time()

        system_prompt = self._read_system_prompt(request.direction)
        messages = self._build_messages(
            request.text, request.direction, request.context, system_prompt
        )

        translated_text = None
        translation_failed = False

        try:
            translated_text = await self._retry_translate(
                messages,
                chat_id=request.chat_id,
                direction=request.direction,
                original_text=request.text,
            )
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
            # Store in persistent cache (skip identity translations where input == output)
            if translated_text != request.text:
                self._translation_cache[cache_key] = translated_text
                self._save_translation_cache()
            # Share result with any waiters on the in-flight future.
            if not future.done():
                future.set_result(translated_text)
        else:
            # Signal exhaustion so waiters fall through to their own attempt.
            if not future.done():
                future.set_exception(RuntimeError("translation exhausted"))

        # Clear in-flight slot last so new duplicates get the cached value instead
        # of attaching to a resolved future.
        self._inflight.pop(cache_key, None)

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

    async def _retry_translate(self, messages: list[dict], *, chat_id: str = "", direction: str = "", original_text: str = "") -> str:
        """Try primary model once, then each fallback model once.

        Universal fallback: ALL error types (not just ContentFilter) trigger
        the next model. PaymentError breaks immediately (no point retrying).
        """
        models = [OPENROUTER_MODEL] + self.FALLBACK_MODELS
        last_exception = None
        content_filter_count = 0

        for model in models:
            try:
                result = await self._call_openrouter(messages, model=model)
                if model != OPENROUTER_MODEL:
                    self.stats["fallbacks"] += 1
                return result
            except PaymentError as e:
                logger.error(f"PAYMENT chat_id={chat_id} dir={direction}: {e}")
                raise TranslationExhaustedError(f"Payment required: {e}")
            except ContentFilterError as e:
                content_filter_count += 1
                full_content = "\n".join(
                    f"  [{m['role']}]: {m['content']}" for m in messages
                )
                logger.warning(
                    f"CONTENT_FILTER [{model}] chat_id={chat_id} dir={direction} "
                    f"text={original_text!r}\n"
                    f"  Full request payload:\n{full_content}"
                )
                last_exception = e
                continue
            except Exception as e:
                self.stats["retries"] += 1
                logger.warning(
                    f"Model {model} failed ({type(e).__name__}: {e})"
                )
                last_exception = e
                continue

        if content_filter_count == len(models):
            logger.warning(
                f"ALL_MODELS_BLOCKED chat_id={chat_id} dir={direction} "
                f"text={original_text!r} — all {len(models)} models blocked"
            )

        raise TranslationExhaustedError(
            f"All models failed. Last error: {last_exception}"
        )


# --- Custom Exceptions ---


class OpenRouterError(Exception):
    pass


class EmptyResponseError(OpenRouterError):
    pass


class ContentFilterError(OpenRouterError):
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
claim_store = ClaimStore()

app = FastAPI(title="TranslateGram Proxy", version="1.0.0")


@app.post("/translate", response_model=TranslateResponse)
async def translate(request: TranslateRequest):
    # Claim check — ultra-fast O(1) dict lookup, runs BEFORE any translation.
    # Skipped when iOS has flagged the chat as two-sided (ongoing conversation).
    if request.direction == "outgoing" and request.sender_account_id and request.chat_id:
        if request.has_two_sided_history:
            # Record the claim opportunistically if unclaimed, but never block.
            claim_store.register_if_unclaimed(
                request.chat_id, request.sender_account_id
            )
            logger.info(
                f"CLAIM BYPASSED (two-sided history): "
                f"sender={request.sender_account_id} target={request.chat_id}"
            )
        else:
            is_blocked, claimed_by = claim_store.check_and_claim(
                request.chat_id, request.sender_account_id
            )
            if is_blocked:
                logger.info(
                    f"CLAIM BLOCKED: sender={request.sender_account_id} "
                    f"target={request.chat_id} claimed_by={claimed_by}"
                )
                return TranslateResponse(
                    translated_text="",
                    original_text=request.text,
                    direction=request.direction,
                    user_claimed=True,
                    claimed_by=claimed_by,
                )

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


# --- Claim Management Endpoints ---


@app.post("/claim", response_model=ClaimResponse)
async def claim(request: ClaimRequest):
    """Pre-flight claim registration — decoupled from /translate.

    iOS calls this BEFORE every outgoing send, regardless of whether the
    message will flow through translation, a passthrough, a forward, or a
    media-only path. This closes the gap where untranslated sends (bypass
    paths, per-chat toggle off, `.passthrough`, media-only templates, etc.)
    previously never registered a claim with the backend — leaving the
    first account that happened to use /translate as the "winner" even
    though a different account was the real active chatter.

    Same bypass semantics as /translate:
    - has_two_sided_history=True -> never block, record claim if unclaimed.
    - Otherwise -> check_and_claim: block on conflicting claim, else take ownership.
    """
    if not request.sender_account_id or not request.chat_id:
        return ClaimResponse(allowed=True)

    if request.has_two_sided_history:
        claim_store.register_if_unclaimed(
            request.chat_id, request.sender_account_id
        )
        logger.info(
            f"CLAIM GUARD (two-sided bypass): "
            f"sender={request.sender_account_id} target={request.chat_id}"
        )
        return ClaimResponse(allowed=True)

    is_blocked, claimed_by = claim_store.check_and_claim(
        request.chat_id, request.sender_account_id
    )
    if is_blocked:
        logger.info(
            f"CLAIM GUARD BLOCKED: sender={request.sender_account_id} "
            f"target={request.chat_id} claimed_by={claimed_by}"
        )
        return ClaimResponse(
            allowed=False, user_claimed=True, claimed_by=claimed_by
        )

    logger.info(
        f"CLAIM GUARD OK: sender={request.sender_account_id} "
        f"target={request.chat_id}"
    )
    return ClaimResponse(allowed=True)


@app.get("/claim/delete/{target_id}/{sender_id}")
async def delete_claim_pair(target_id: str, sender_id: str):
    """Hidden GET endpoint — delete a claim entry only when it matches BOTH
    the target user ID AND the currently-claiming sender ID. Usable from a
    browser by typing the URL manually. Not referenced anywhere in the app
    or linked from any other endpoint.

    Example: https://telegramtranslation.duckdns.org/claim/delete/6880888144/8621374012
    deletes the claim for target 6880888144 only if it is currently owned
    by sender 8621374012 — mismatch is reported, never silently overwritten.
    """
    claims = claim_store.get_all()
    current = claims.get(target_id)
    if current is None:
        logger.info(
            f"CLAIM DELETE-PAIR not_found: target={target_id} requested_sender={sender_id}"
        )
        return {
            "status": "not_found",
            "target_id": target_id,
            "sender_id": sender_id,
            "message": "No claim exists for this target.",
        }
    if current != sender_id:
        logger.info(
            f"CLAIM DELETE-PAIR mismatch: target={target_id} "
            f"actual_sender={current} requested_sender={sender_id}"
        )
        return {
            "status": "mismatch",
            "target_id": target_id,
            "actual_claimed_by": current,
            "requested_sender": sender_id,
            "message": "Claim is owned by a different sender — pair does not match.",
        }
    released = claim_store.release(target_id)
    logger.info(
        f"CLAIM DELETE-PAIR success: target={target_id} sender={sender_id}"
    )
    return {
        "status": "deleted" if released else "error",
        "target_id": target_id,
        "sender_id": sender_id,
    }


@app.get("/claims")
async def list_claims():
    """List all active user claims (target_user_id → sender_account_id)."""
    return claim_store.get_all()


@app.delete("/claims/{target_id}")
async def release_claim(target_id: str):
    """Release a specific claim by target user ID."""
    released = claim_store.release(target_id)
    return {"released": released, "target_id": target_id}


@app.delete("/claims/by-sender/{sender_id}")
async def release_sender_claims(sender_id: str):
    """Release ALL claims held by a specific sender account."""
    count = claim_store.release_all_by_sender(sender_id)
    return {"released_count": count, "sender_id": sender_id}


IOS_DEBUG_LOG = Path(__file__).parent / "ios_debug.log"


@app.post("/logs")
async def receive_ios_logs(request: Request):
    """Receive debug logs from the iOS app and save to ios_debug.log."""
    try:
        body = await request.json()
        entries = body.get("entries", [])
        device = body.get("device", "unknown")
        sent_at = body.get("sent_at", "")

        with open(IOS_DEBUG_LOG, "a", encoding="utf-8") as f:
            f.write(f"\n===== iOS Logs from '{device}' at {sent_at} ({len(entries)} entries) =====\n")
            for entry in entries:
                ts = entry.get("ts", "?")
                msg = entry.get("msg", "")
                f.write(f"  [{ts}] {msg}\n")
            f.write(f"===== END =====\n")

        logger.info(f"Received {len(entries)} iOS debug log entries from '{device}'")
        return {"status": "ok", "received": len(entries)}
    except Exception as e:
        logger.error(f"Failed to process iOS logs: {e}")
        return {"status": "error", "message": str(e)}


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
        "cache_hits": s["cache_hits"],
        "cache_size": len(translation_service._translation_cache),
        "success_rate": round(s["successful"] / total, 4) if total > 0 else 0,
        "avg_response_time_ms": round(avg_ms, 1),
    }


# --- OTA Install ---

OTA_DIR = Path(__file__).parent / "ota"
OTA_BUNDLE_ID = "com.niklas.translategram2"
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
    return FileResponse(
        path=ipa_path,
        media_type="application/octet-stream",
        filename="TranslateGram.ipa",
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
