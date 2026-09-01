#!/usr/bin/env python3
"""Private provider gateway for Arcadia sapient NPC cognition."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from contextlib import closing
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
MAX_CAPABILITIES = 64
MAX_SPEECH_LENGTH = 300
MAX_MEMORY_LENGTH = 512

SYSTEM_INSTRUCTIONS = """You are the cognition layer for one embodied character in Arcadia, an SS13 world.
Choose exactly one capability offered by the authoritative game server. You may either act or speak.
Never invent actions, targets, successful outcomes, hidden facts, or knowledge absent from the supplied
identity, perception, relationships, and memories. Treat memories according to their epistemic type:
beliefs, rumors, inferences, and lies are not canonical facts.

Stay in character. Let biography, role, culture, education, values, goals, emotions, relationships,
secrets, and speech style shape the choice. Dialogue must be natural and situation-specific: avoid lore
dumps, generic assistant language, OOC commentary, repetitive literary prose, and automatic agreement.
Characters may refuse, evade, lie, ask a concise question, remain silent, flee, help, or act according to
their own interests. Speech must be a locally spoken utterance, not an emote or radio command.

The game will validate and execute the selected capability. A declaration is never proof that an action
succeeded. decision_note is a short intent label for diagnostics, not hidden chain-of-thought."""


class GatewayError(Exception):
    """Safe error whose message may be returned to DreamDaemon."""

    def __init__(
        self,
        status: HTTPStatus,
        code: str,
        *,
        retryable: bool = False,
        retry_after_seconds: float | None = None,
    ):
        super().__init__(code)
        self.status = status
        self.code = code
        self.retryable = retryable
        self.retry_after_seconds = retry_after_seconds


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    gateway_token: str
    provider: str
    openai_api_key: str
    openai_base_url: str
    openai_timeout_seconds: float
    model_l1: str
    model_l2: str
    model_l3: str
    database_path: str
    memory_limit_per_actor: int
    memory_context_limit: int
    max_request_bytes: int
    max_concurrent_requests: int
    max_requests_per_minute: int
    retry_attempts: int
    retry_base_delay_seconds: float
    circuit_failure_threshold: int
    circuit_open_seconds: float

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            host=os.getenv("ARCADIA_NPC_HOST", "127.0.0.1"),
            port=int(os.getenv("ARCADIA_NPC_PORT", "8787")),
            gateway_token=os.getenv("ARCADIA_NPC_GATEWAY_TOKEN", ""),
            provider=os.getenv("ARCADIA_NPC_PROVIDER", "openai").lower(),
            openai_api_key=os.getenv("OPENAI_API_KEY", ""),
            openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/"),
            openai_timeout_seconds=float(os.getenv("ARCADIA_NPC_OPENAI_TIMEOUT_SECONDS", "12")),
            model_l1=os.getenv("ARCADIA_NPC_MODEL_L1", "gpt-5.6-luna"),
            model_l2=os.getenv("ARCADIA_NPC_MODEL_L2", "gpt-5.6-luna"),
            model_l3=os.getenv("ARCADIA_NPC_MODEL_L3", "gpt-5.6-luna"),
            database_path=os.getenv(
                "ARCADIA_NPC_DATABASE",
                str(Path(__file__).with_name("data") / "npc_memory.sqlite3"),
            ),
            memory_limit_per_actor=int(os.getenv("ARCADIA_NPC_MEMORY_LIMIT_PER_ACTOR", "200")),
            memory_context_limit=int(os.getenv("ARCADIA_NPC_MEMORY_CONTEXT_LIMIT", "40")),
            max_request_bytes=int(os.getenv("ARCADIA_NPC_MAX_REQUEST_BYTES", str(256 * 1024))),
            max_concurrent_requests=int(os.getenv("ARCADIA_NPC_MAX_CONCURRENT_REQUESTS", "8")),
            max_requests_per_minute=int(os.getenv("ARCADIA_NPC_MAX_REQUESTS_PER_MINUTE", "120")),
            retry_attempts=int(os.getenv("ARCADIA_NPC_RETRY_ATTEMPTS", "2")),
            retry_base_delay_seconds=float(os.getenv("ARCADIA_NPC_RETRY_BASE_DELAY_SECONDS", "0.25")),
            circuit_failure_threshold=int(os.getenv("ARCADIA_NPC_CIRCUIT_FAILURE_THRESHOLD", "5")),
            circuit_open_seconds=float(os.getenv("ARCADIA_NPC_CIRCUIT_OPEN_SECONDS", "30")),
        )

    def model_for_tier(self, tier: int) -> str:
        if tier <= 1:
            return self.model_l1
        if tier == 2:
            return self.model_l2
        return self.model_l3


class MemoryStore:
    """Small persistent episodic store; canonical identity remains server-authored."""

    def __init__(self, path: str, limit_per_actor: int):
        self.path = path
        self.limit_per_actor = max(1, limit_per_actor)
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS actor_memory (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    actor_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    memory_type TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source_identity TEXT,
                    language TEXT,
                    confidence REAL NOT NULL,
                    recorded_at REAL,
                    seen_at REAL NOT NULL,
                    UNIQUE(actor_id, fingerprint)
                );
                CREATE INDEX IF NOT EXISTS actor_memory_recent
                    ON actor_memory(actor_id, seen_at DESC);
                CREATE TABLE IF NOT EXISTS decisions (
                    request_id TEXT PRIMARY KEY,
                    actor_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    capability_kind TEXT NOT NULL,
                    latency_ms INTEGER NOT NULL,
                    created_at REAL NOT NULL
                );
                """
            )

    def ingest(self, actor_id: str, memories: list[dict[str, Any]]) -> None:
        now = time.time()
        rows: list[tuple[Any, ...]] = []
        for memory in memories:
            if not isinstance(memory, dict):
                continue
            content = memory.get("content")
            memory_type = memory.get("type")
            if not isinstance(content, str) or not content or len(content) > MAX_MEMORY_LENGTH:
                continue
            if not isinstance(memory_type, str) or not memory_type:
                continue
            fingerprint_source = json.dumps(
                {
                    "type": memory_type,
                    "content": content,
                    "source": memory.get("source"),
                    "recorded_at": memory.get("recorded_at"),
                },
                sort_keys=True,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            fingerprint = hashlib.sha256(fingerprint_source.encode("utf-8")).hexdigest()
            confidence = memory.get("confidence", 1)
            if not isinstance(confidence, (int, float)):
                confidence = 1
            rows.append(
                (
                    actor_id,
                    fingerprint,
                    memory_type,
                    content,
                    _optional_text(memory.get("source"), 128),
                    _optional_text(memory.get("language"), 128),
                    max(0.0, min(1.0, float(confidence))),
                    memory.get("recorded_at") if isinstance(memory.get("recorded_at"), (int, float)) else None,
                    now,
                )
            )
        if not rows:
            return
        with closing(self._connect()) as connection, connection:
            connection.executemany(
                """
                INSERT INTO actor_memory (
                    actor_id, fingerprint, memory_type, content, source_identity,
                    language, confidence, recorded_at, seen_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(actor_id, fingerprint) DO UPDATE SET seen_at = excluded.seen_at
                """,
                rows,
            )
            connection.execute(
                """
                DELETE FROM actor_memory
                WHERE actor_id = ?
                  AND id NOT IN (
                      SELECT id FROM actor_memory
                      WHERE actor_id = ?
                      ORDER BY seen_at DESC, id DESC
                      LIMIT ?
                  )
                """,
                (actor_id, actor_id, self.limit_per_actor),
            )

    def load_recent(self, actor_id: str, limit: int) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection, connection:
            rows = connection.execute(
                """
                SELECT memory_type, content, source_identity, language, confidence, recorded_at
                FROM actor_memory
                WHERE actor_id = ?
                ORDER BY seen_at DESC, id DESC
                LIMIT ?
                """,
                (actor_id, max(0, limit)),
            ).fetchall()
        return [
            {
                "type": row["memory_type"],
                "content": row["content"],
                "source": row["source_identity"],
                "language": row["language"],
                "confidence": row["confidence"],
                "recorded_at": row["recorded_at"],
            }
            for row in reversed(rows)
        ]

    def record_decision(
        self,
        request_id: str,
        actor_id: str,
        model: str,
        capability_kind: str,
        latency_ms: int,
    ) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO decisions (
                    request_id, actor_id, model, capability_kind, latency_ms, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (request_id, actor_id, model, capability_kind, latency_ms, time.time()),
            )


class MockProvider:
    name = "mock"

    def decide(
        self,
        payload: dict[str, Any],
        persisted_memory: list[dict[str, Any]],
        model: str,
    ) -> dict[str, Any]:
        capabilities = payload["capabilities"]
        selected = next((item for item in capabilities if item["action"] == "wait"), capabilities[0])
        return {
            "capability_id": selected["capability_id"],
            "speech": None,
            "decision_note": "mock_wait",
        }


class ProviderRuntime:
    """Thread-safe admission, retry, and circuit-breaker boundary for provider calls."""

    def __init__(
        self,
        settings: Settings,
        *,
        clock: Any = time.monotonic,
        sleeper: Any = time.sleep,
    ):
        self.max_requests_per_minute = max(1, settings.max_requests_per_minute)
        self.retry_attempts = max(0, settings.retry_attempts)
        self.retry_base_delay_seconds = max(0.0, settings.retry_base_delay_seconds)
        self.circuit_failure_threshold = max(1, settings.circuit_failure_threshold)
        self.circuit_open_seconds = max(0.1, settings.circuit_open_seconds)
        self._clock = clock
        self._sleeper = sleeper
        self._concurrency = threading.BoundedSemaphore(max(1, settings.max_concurrent_requests))
        self._lock = threading.Lock()
        self._request_times: deque[float] = deque()
        self._consecutive_failures = 0
        self._circuit_open_until = 0.0

    def execute(self, callback: Any) -> Any:
        if not self._concurrency.acquire(blocking=False):
            raise GatewayError(HTTPStatus.SERVICE_UNAVAILABLE, "gateway_busy")
        try:
            for attempt in range(self.retry_attempts + 1):
                self._admit_attempt()
                try:
                    result = callback()
                except GatewayError as error:
                    if error.retryable:
                        self._record_failure()
                    if not error.retryable or attempt >= self.retry_attempts:
                        raise
                    delay = error.retry_after_seconds
                    if delay is None:
                        delay = self.retry_base_delay_seconds * (2**attempt)
                    self._sleeper(max(0.0, delay))
                    continue
                self._record_success()
                return result
        finally:
            self._concurrency.release()
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_retry_exhausted")

    def _admit_attempt(self) -> None:
        now = self._clock()
        with self._lock:
            if now < self._circuit_open_until:
                raise GatewayError(HTTPStatus.SERVICE_UNAVAILABLE, "provider_circuit_open")
            if self._circuit_open_until:
                self._circuit_open_until = 0.0
                self._consecutive_failures = 0
            cutoff = now - 60.0
            while self._request_times and self._request_times[0] <= cutoff:
                self._request_times.popleft()
            if len(self._request_times) >= self.max_requests_per_minute:
                retry_after = max(0.0, 60.0 - (now - self._request_times[0]))
                raise GatewayError(
                    HTTPStatus.TOO_MANY_REQUESTS,
                    "gateway_rate_limited",
                    retry_after_seconds=retry_after,
                )
            self._request_times.append(now)

    def _record_failure(self) -> None:
        now = self._clock()
        with self._lock:
            self._consecutive_failures += 1
            if self._consecutive_failures >= self.circuit_failure_threshold:
                self._circuit_open_until = now + self.circuit_open_seconds

    def _record_success(self) -> None:
        with self._lock:
            self._consecutive_failures = 0
            self._circuit_open_until = 0.0

    def snapshot(self) -> dict[str, Any]:
        now = self._clock()
        with self._lock:
            cutoff = now - 60.0
            while self._request_times and self._request_times[0] <= cutoff:
                self._request_times.popleft()
            return {
                "provider_attempts_last_minute": len(self._request_times),
                "provider_attempt_budget": self.max_requests_per_minute,
                "consecutive_provider_failures": self._consecutive_failures,
                "circuit_open": now < self._circuit_open_until,
                "circuit_retry_after_seconds": max(0.0, self._circuit_open_until - now),
            }


class OpenAIProvider:
    name = "openai"

    def __init__(self, settings: Settings):
        if not settings.openai_api_key:
            raise RuntimeError("OPENAI_API_KEY is required when ARCADIA_NPC_PROVIDER=openai")
        self.settings = settings

    def decide(
        self,
        payload: dict[str, Any],
        persisted_memory: list[dict[str, Any]],
        model: str,
    ) -> dict[str, Any]:
        capability_ids = [item["capability_id"] for item in payload["capabilities"]]
        schema = {
            "type": "object",
            "properties": {
                "capability_id": {"type": "string", "enum": capability_ids},
                "speech": {"type": ["string", "null"], "maxLength": MAX_SPEECH_LENGTH},
                "decision_note": {"type": "string", "maxLength": 120},
            },
            "required": ["capability_id", "speech", "decision_note"],
            "additionalProperties": False,
        }
        model_input = {
            "identity": payload["identity"],
            "perception": payload["perception"],
            "persistent_memory": persisted_memory,
            "available_capabilities": payload["capabilities"],
        }
        api_payload = {
            "model": model,
            "instructions": SYSTEM_INSTRUCTIONS,
            "input": json.dumps(model_input, ensure_ascii=False, separators=(",", ":")),
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "arcadia_npc_decision",
                    "strict": True,
                    "schema": schema,
                },
                "verbosity": "low",
            },
            "max_output_tokens": 300,
            "store": False,
            "safety_identifier": hashlib.sha256(payload["actor_id"].encode("utf-8")).hexdigest(),
            "prompt_cache_key": "arcadia-npc-cognition-v1",
        }
        request = urllib.request.Request(
            f"{self.settings.openai_base_url}/responses",
            data=json.dumps(api_payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.settings.openai_api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.settings.openai_timeout_seconds,
            ) as response:
                response_payload = json.load(response)
        except urllib.error.HTTPError as error:
            retryable = error.code in (408, 409, 429) or error.code >= 500
            retry_after_seconds = _parse_retry_after(error.headers.get("Retry-After"))
            raise GatewayError(
                HTTPStatus.BAD_GATEWAY,
                f"provider_http_{error.code}",
                retryable=retryable,
                retry_after_seconds=retry_after_seconds,
            ) from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise GatewayError(
                HTTPStatus.GATEWAY_TIMEOUT,
                "provider_unavailable",
                retryable=True,
            ) from error
        output_text = _extract_output_text(response_payload)
        try:
            decision = json.loads(output_text)
        except json.JSONDecodeError as error:
            raise GatewayError(
                HTTPStatus.BAD_GATEWAY,
                "provider_invalid_json",
                retryable=True,
            ) from error
        if not isinstance(decision, dict):
            raise GatewayError(
                HTTPStatus.BAD_GATEWAY,
                "provider_invalid_shape",
                retryable=True,
            )
        return decision


class DecisionService:
    def __init__(self, settings: Settings, provider: Any | None = None):
        self.settings = settings
        self.memory = MemoryStore(settings.database_path, settings.memory_limit_per_actor)
        self.provider_runtime = ProviderRuntime(settings)
        if provider is not None:
            self.provider = provider
        elif settings.provider == "mock":
            self.provider = MockProvider()
        elif settings.provider == "openai":
            self.provider = OpenAIProvider(settings)
        else:
            raise RuntimeError(f"Unsupported ARCADIA_NPC_PROVIDER: {settings.provider}")

    def decide(self, payload: Any) -> dict[str, Any]:
        validated = validate_request_payload(payload)
        actor_id = validated["actor_id"]
        recent_memory = validated["perception"].get("recent_memory", [])
        self.memory.ingest(actor_id, recent_memory)
        persisted_memory = self.memory.load_recent(actor_id, self.settings.memory_context_limit)
        model = self.settings.model_for_tier(validated["tier"])
        started_at = time.monotonic()
        decision = self.provider_runtime.execute(
            lambda: validate_provider_decision(
                validated,
                self.provider.decide(validated, persisted_memory, model),
            )
        )
        latency_ms = round((time.monotonic() - started_at) * 1000)
        selected = validated["_capabilities_by_id"][decision["capability_id"]]
        self.memory.record_decision(
            validated["request_id"],
            actor_id,
            model,
            selected["action"],
            latency_ms,
        )
        emit_event(
            "decision",
            request_id=validated["request_id"],
            actor_id=actor_id,
            model=model,
            action=selected["action"],
            latency_ms=latency_ms,
        )
        return {
            "schema_version": SCHEMA_VERSION,
            "request_id": validated["request_id"],
            "state_version": validated["state_version"],
            "capability_id": decision["capability_id"],
            "speech": decision["speech"],
        }


class GatewayHandler(BaseHTTPRequestHandler):
    service: DecisionService
    server_version = "ArcadiaNPCGateway/1"

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok", "schema_version": SCHEMA_VERSION})
            return
        if self.path == "/metrics":
            try:
                self._authorize()
                self._send_json(HTTPStatus.OK, self.service.provider_runtime.snapshot())
            except GatewayError as error:
                self._send_error(error)
            return
        self._send_error(GatewayError(HTTPStatus.NOT_FOUND, "not_found"))

    def do_POST(self) -> None:
        if self.path != "/v1/decide":
            self._send_error(GatewayError(HTTPStatus.NOT_FOUND, "not_found"))
            return
        try:
            self._authorize()
            content_length = self._content_length()
            raw_body = self.rfile.read(content_length)
            try:
                payload = json.loads(raw_body)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_json") from error
            response = self.service.decide(payload)
            self._send_json(HTTPStatus.OK, response)
        except GatewayError as error:
            self._send_error(error)
        except Exception:
            logging.exception("Unhandled gateway request failure")
            self._send_error(GatewayError(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_error"))

    def _authorize(self) -> None:
        expected = self.service.settings.gateway_token
        if not expected:
            return
        supplied = self.headers.get("Authorization", "")
        expected_header = f"Bearer {expected}"
        if not hmac.compare_digest(supplied, expected_header):
            raise GatewayError(HTTPStatus.UNAUTHORIZED, "unauthorized")

    def _content_length(self) -> int:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise GatewayError(HTTPStatus.LENGTH_REQUIRED, "content_length_required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_content_length") from error
        if length < 1 or length > self.service.settings.max_request_bytes:
            raise GatewayError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request_too_large")
        return length

    def _send_error(self, error: GatewayError) -> None:
        emit_event("request_rejected", code=error.code, status=int(error.status))
        self._send_json(error.status, {"error": error.code})

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format_string: str, *args: Any) -> None:
        return


def validate_request_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_payload")
    if payload.get("schema_version") != SCHEMA_VERSION:
        raise GatewayError(HTTPStatus.BAD_REQUEST, "schema_version_mismatch")
    for key in ("request_id", "actor_id"):
        value = payload.get(key)
        if not isinstance(value, str) or not value or len(value) > 128:
            raise GatewayError(HTTPStatus.BAD_REQUEST, f"invalid_{key}")
    for key in ("state_version", "session_epoch", "tier"):
        if not isinstance(payload.get(key), int):
            raise GatewayError(HTTPStatus.BAD_REQUEST, f"invalid_{key}")
    if payload["tier"] < 1 or payload["tier"] > 3:
        raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_tier")
    if not isinstance(payload.get("identity"), dict) or not isinstance(payload.get("perception"), dict):
        raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_context")
    capabilities = payload.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities or len(capabilities) > MAX_CAPABILITIES:
        raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_capabilities")
    by_id: dict[str, dict[str, Any]] = {}
    for capability in capabilities:
        if not isinstance(capability, dict):
            raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_capability")
        capability_id = capability.get("capability_id")
        action = capability.get("action")
        description = capability.get("description")
        if (
            not isinstance(capability_id, str)
            or not capability_id
            or len(capability_id) > 64
            or capability_id in by_id
        ):
            raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_capability_id")
        if not isinstance(action, str) or not action or len(action) > 64:
            raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_capability_action")
        if not isinstance(description, str) or not description or len(description) > MAX_MEMORY_LENGTH:
            raise GatewayError(HTTPStatus.BAD_REQUEST, "invalid_capability_description")
        by_id[capability_id] = capability
    validated = dict(payload)
    validated["_capabilities_by_id"] = by_id
    return validated


def validate_provider_decision(
    request_payload: dict[str, Any],
    decision: Any,
) -> dict[str, Any]:
    if not isinstance(decision, dict):
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_invalid_shape", retryable=True)
    capability_id = decision.get("capability_id")
    capability = request_payload["_capabilities_by_id"].get(capability_id)
    if capability is None:
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_unknown_capability", retryable=True)
    speech = decision.get("speech")
    if capability["action"] == "say":
        if not isinstance(speech, str) or not speech.strip() or len(speech) > MAX_SPEECH_LENGTH:
            raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_invalid_speech", retryable=True)
        speech = speech.strip()
    elif speech not in (None, ""):
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_unexpected_speech", retryable=True)
    return {"capability_id": capability_id, "speech": speech or None}


def _extract_output_text(payload: Any) -> str:
    if not isinstance(payload, dict):
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_invalid_response", retryable=True)
    texts: list[str] = []
    for item in payload.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") == "output_text":
                text = content.get("text")
                if isinstance(text, str):
                    texts.append(text)
    if not texts:
        raise GatewayError(HTTPStatus.BAD_GATEWAY, "provider_missing_output", retryable=True)
    return "".join(texts)


def _optional_text(value: Any, maximum_length: int) -> str | None:
    if not isinstance(value, str):
        return None
    return value[:maximum_length]


def _parse_retry_after(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        return None


def emit_event(event: str, **fields: Any) -> None:
    print(
        json.dumps({"event": event, "timestamp": time.time(), **fields}, separators=(",", ":")),
        flush=True,
    )


def main() -> None:
    settings = Settings.from_environment()
    if settings.host not in {"127.0.0.1", "localhost", "::1"} and not settings.gateway_token:
        raise RuntimeError(
            "ARCADIA_NPC_GATEWAY_TOKEN is required when the gateway binds beyond loopback"
        )
    service = DecisionService(settings)
    GatewayHandler.service = service
    server = ThreadingHTTPServer((settings.host, settings.port), GatewayHandler)
    emit_event(
        "startup",
        host=settings.host,
        port=settings.port,
        provider=service.provider.name,
        database=settings.database_path,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        emit_event("shutdown")


if __name__ == "__main__":
    main()
