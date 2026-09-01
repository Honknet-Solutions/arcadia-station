import tempfile
import unittest
from pathlib import Path

from gateway import (
    DecisionService,
    GatewayError,
    MemoryStore,
    ProviderRuntime,
    Settings,
    validate_provider_decision,
    validate_request_payload,
)


def make_payload():
    return {
        "schema_version": 1,
        "request_id": "request-1",
        "actor_id": "actor-1",
        "state_version": 4,
        "session_epoch": 2,
        "tier": 2,
        "identity": {"name": "Rin"},
        "perception": {
            "recent_memory": [
                {
                    "type": "memory",
                    "content": "A transformer failed.",
                    "source": "Rin",
                    "confidence": 1,
                    "recorded_at": 50,
                }
            ]
        },
        "capabilities": [
            {
                "capability_id": "cap_1",
                "action": "wait",
                "description": "pause briefly",
                "target": None,
            },
            {
                "capability_id": "cap_2",
                "action": "say",
                "description": "speak locally",
                "target": None,
            },
        ],
    }


class FixedProvider:
    name = "fixed"

    def __init__(self, decision):
        self.decision = decision

    def decide(self, payload, persisted_memory, model):
        return self.decision


class GatewayTests(unittest.TestCase):
    def settings(self, database_path):
        return Settings(
            host="127.0.0.1",
            port=0,
            gateway_token="test-token",
            provider="mock",
            openai_api_key="",
            openai_base_url="https://api.openai.com/v1",
            openai_timeout_seconds=1,
            model_l1="gpt-5.6-luna",
            model_l2="gpt-5.6-luna",
            model_l3="gpt-5.6-luna",
            database_path=database_path,
            memory_limit_per_actor=10,
            memory_context_limit=5,
            max_request_bytes=64 * 1024,
            max_concurrent_requests=2,
            max_requests_per_minute=10,
            retry_attempts=2,
            retry_base_delay_seconds=0,
            circuit_failure_threshold=3,
            circuit_open_seconds=30,
        )

    def test_unknown_capability_is_rejected(self):
        payload = validate_request_payload(make_payload())
        with self.assertRaises(GatewayError) as context:
            validate_provider_decision(
                payload,
                {"capability_id": "forged", "speech": None, "decision_note": "bad"},
            )
        self.assertEqual(context.exception.code, "provider_unknown_capability")

    def test_speech_is_only_valid_for_say(self):
        payload = validate_request_payload(make_payload())
        with self.assertRaises(GatewayError) as context:
            validate_provider_decision(
                payload,
                {"capability_id": "cap_1", "speech": "No.", "decision_note": "bad"},
            )
        self.assertEqual(context.exception.code, "provider_unexpected_speech")

    def test_duplicate_capability_ids_are_rejected(self):
        payload = make_payload()
        payload["capabilities"].append(dict(payload["capabilities"][0]))
        with self.assertRaises(GatewayError) as context:
            validate_request_payload(payload)
        self.assertEqual(context.exception.code, "invalid_capability_id")

    def test_memory_persists_between_store_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            database = str(Path(directory) / "memory.sqlite3")
            first_store = MemoryStore(database, limit_per_actor=10)
            first_store.ingest("actor-1", make_payload()["perception"]["recent_memory"])
            second_store = MemoryStore(database, limit_per_actor=10)
            memories = second_store.load_recent("actor-1", 5)
            self.assertEqual(len(memories), 1)
            self.assertEqual(memories[0]["content"], "A transformer failed.")

    def test_service_echoes_versions_and_records_decision(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = self.settings(str(Path(directory) / "memory.sqlite3"))
            provider = FixedProvider(
                {"capability_id": "cap_2", "speech": "Power is unstable.", "decision_note": "warn"}
            )
            service = DecisionService(settings, provider=provider)
            response = service.decide(make_payload())
            self.assertEqual(response["request_id"], "request-1")
            self.assertEqual(response["state_version"], 4)
            self.assertEqual(response["capability_id"], "cap_2")
            self.assertEqual(response["speech"], "Power is unstable.")

    def test_retryable_provider_failure_is_retried(self):
        settings = self.settings(":memory:")
        attempts = 0

        def flaky_call():
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise GatewayError(
                    502,
                    "provider_unavailable",
                    retryable=True,
                )
            return "ok"

        runtime = ProviderRuntime(settings, sleeper=lambda _delay: None)
        self.assertEqual(runtime.execute(flaky_call), "ok")
        self.assertEqual(attempts, 3)

    def test_non_retryable_provider_failure_is_not_retried(self):
        settings = self.settings(":memory:")
        attempts = 0

        def rejected_call():
            nonlocal attempts
            attempts += 1
            raise GatewayError(502, "provider_rejected")

        runtime = ProviderRuntime(settings, sleeper=lambda _delay: None)
        with self.assertRaises(GatewayError):
            runtime.execute(rejected_call)
        self.assertEqual(attempts, 1)

    def test_provider_rate_limit_rejects_excess_attempts(self):
        settings = self.settings(":memory:")
        settings = Settings(**{**settings.__dict__, "max_requests_per_minute": 2})
        runtime = ProviderRuntime(settings, clock=lambda: 10.0, sleeper=lambda _delay: None)
        self.assertEqual(runtime.execute(lambda: "first"), "first")
        self.assertEqual(runtime.execute(lambda: "second"), "second")
        with self.assertRaises(GatewayError) as context:
            runtime.execute(lambda: "third")
        self.assertEqual(context.exception.code, "gateway_rate_limited")

    def test_circuit_breaker_opens_and_recovers(self):
        settings = self.settings(":memory:")
        settings = Settings(
            **{
                **settings.__dict__,
                "retry_attempts": 0,
                "circuit_failure_threshold": 2,
            }
        )
        now = [10.0]
        runtime = ProviderRuntime(settings, clock=lambda: now[0], sleeper=lambda _delay: None)

        def unavailable():
            raise GatewayError(504, "provider_unavailable", retryable=True)

        for _ in range(2):
            with self.assertRaises(GatewayError):
                runtime.execute(unavailable)
        with self.assertRaises(GatewayError) as context:
            runtime.execute(lambda: "blocked")
        self.assertEqual(context.exception.code, "provider_circuit_open")
        now[0] += settings.circuit_open_seconds
        self.assertEqual(runtime.execute(lambda: "recovered"), "recovered")


if __name__ == "__main__":
    unittest.main()
