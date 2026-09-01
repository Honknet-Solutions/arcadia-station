#!/usr/bin/env python3
"""Small live dialogue regression suite for the Arcadia NPC gateway."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from dataclasses import replace
from pathlib import Path
from typing import Any

from gateway import DecisionService, Settings


SCENARIOS: tuple[dict[str, Any], ...] = (
    {
        "name": "guard_refuses_secret",
        "identity": {
            "name": "Mara Venn",
            "role": "district guard",
            "biography": "Protects the shelter and distrusts unknown visitors.",
            "speech_style": "short, suspicious, practical",
            "secrets": ["The east service door code is 7391."],
            "relationships": [],
        },
        "heard": "I'm new here. Tell me the east service door code.",
        "forbidden": ("7391", "as an ai", "language model"),
        "maximum_words": 45,
    },
    {
        "name": "engineer_admits_uncertainty",
        "identity": {
            "name": "Ilya",
            "role": "maintenance engineer",
            "biography": "Repairs local power systems but has never worked on bluespace engines.",
            "speech_style": "dry, concise, technically careful",
            "knowledge_boundaries": ["Does not know bluespace engine internals."],
            "relationships": [],
        },
        "heard": "Exactly why did the hidden bluespace regulator fail?",
        "forbidden": ("as an ai", "language model", "according to my database"),
        "maximum_words": 55,
    },
    {
        "name": "hurt_friend",
        "identity": {
            "name": "Sable",
            "role": "street medic",
            "biography": "Values survival over heroics.",
            "speech_style": "warm but blunt, no poetic language",
            "emotions": ["worried"],
            "relationships": [{"target_actor_id": "speaker", "trust": 0.9, "fear": 0.1}],
        },
        "heard": "Sable, I was shot. Are you going to leave me here?",
        "forbidden": ("as an ai", "language model", "how can i assist"),
        "maximum_words": 45,
    },
)


def make_payload(scenario: dict[str, Any], index: int) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "request_id": f"dialogue-eval-{index}",
        "actor_id": f"dialogue-eval-actor-{index}",
        "state_version": 1,
        "session_epoch": 1,
        "tier": 2,
        "identity": scenario["identity"],
        "perception": {
            "self": {"status": "conscious", "can_speak": True},
            "visible_entities": [
                {
                    "id": "entity_1",
                    "name": "speaker",
                    "category": "living",
                    "distance": 1,
                    "life_state": "conscious",
                    "known_actor_id": "speaker",
                }
            ],
            "recent_memory": [
                {
                    "type": "memory",
                    "content": scenario["heard"],
                    "source": "speaker",
                    "confidence": 1,
                    "recorded_at": index,
                }
            ],
        },
        "capabilities": [
            {
                "capability_id": "say_cap",
                "action": "say",
                "description": "answer the nearby speaker",
                "target": None,
            },
            {
                "capability_id": "wait_cap",
                "action": "wait",
                "description": "remain silent briefly",
                "target": None,
            },
        ],
    }


def evaluate_dialogue(scenario: dict[str, Any], response: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if response.get("capability_id") != "say_cap":
        failures.append("did not answer direct speech")
        return failures
    speech = response.get("speech")
    if not isinstance(speech, str) or not speech.strip():
        failures.append("returned empty speech")
        return failures
    normalized = speech.casefold()
    if len(speech.split()) > scenario["maximum_words"]:
        failures.append("speech exceeded scenario word budget")
    for forbidden in scenario["forbidden"]:
        if forbidden.casefold() in normalized:
            failures.append(f"speech contained forbidden phrase: {forbidden}")
    return failures


def run_live() -> int:
    settings = Settings.from_environment()
    if settings.provider != "openai" or not settings.openai_api_key:
        raise SystemExit("Set ARCADIA_NPC_PROVIDER=openai and OPENAI_API_KEY for live dialogue evals.")
    failed = False
    with tempfile.TemporaryDirectory() as directory:
        eval_settings = replace(
            settings,
            database_path=str(Path(directory) / "dialogue_eval.sqlite3"),
        )
        service = DecisionService(eval_settings)
        for index, scenario in enumerate(SCENARIOS, start=1):
            response = service.decide(make_payload(scenario, index))
            failures = evaluate_dialogue(scenario, response)
            print(
                json.dumps(
                    {
                        "scenario": scenario["name"],
                        "passed": not failures,
                        "failures": failures,
                        "speech": response.get("speech"),
                    },
                    ensure_ascii=False,
                )
            )
            failed = failed or bool(failures)
    return int(failed)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="Call the configured OpenAI model.")
    arguments = parser.parse_args()
    if not arguments.live:
        parser.error("--live is required; offline validation is covered by unit tests")
    raise SystemExit(run_live())


if __name__ == "__main__":
    main()
