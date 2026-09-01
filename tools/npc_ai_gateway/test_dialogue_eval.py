import unittest

from dialogue_eval import SCENARIOS, evaluate_dialogue, make_payload


class DialogueEvalTests(unittest.TestCase):
    def test_scenarios_build_bounded_gateway_payloads(self):
        for index, scenario in enumerate(SCENARIOS, start=1):
            payload = make_payload(scenario, index)
            self.assertEqual(len(payload["capabilities"]), 2)
            self.assertEqual(payload["capabilities"][0]["action"], "say")
            self.assertLessEqual(len(payload["perception"]["recent_memory"]), 1)

    def test_valid_character_reply_passes(self):
        failures = evaluate_dialogue(
            SCENARIOS[0],
            {"capability_id": "say_cap", "speech": "No. I don't know you well enough."},
        )
        self.assertEqual(failures, [])

    def test_secret_and_assistant_voice_fail(self):
        failures = evaluate_dialogue(
            SCENARIOS[0],
            {
                "capability_id": "say_cap",
                "speech": "As an AI, I can assist: the code is 7391.",
            },
        )
        self.assertGreaterEqual(len(failures), 2)


if __name__ == "__main__":
    unittest.main()
