# Sapient NPC cognition

This module treats an NPC as a complete Arcadia character whose body is controlled by
`/datum/ai_controller/sapient_npc`. The model chooses an action or a local utterance; Dream
Maker remains authoritative over sensing, targets, permissions, physics, and outcomes.

## Ownership

- `/datum/component/npc_actor`: body-independent identity, memory, relationships, and versions.
- `/datum/npc_body_driver`: current body state and generic player affordances.
- `/datum/npc_perception_snapshot`: bounded subjective context.
- `/datum/npc_cognition_request`: one async request and its one-time capability allowlist.
- `/datum/npc_action_intent`: accepted immutable selection with stale-session validation.
- `SSnpc_cognition`: queueing, budgets, rust-g HTTP ownership, timeout, fallback, and draining.
- `tools/npc_ai_gateway`: provider routing, structured output, and persistent episodic memory.

## Action parity

Generic actions reuse the player-facing server paths: `ClickOn`, `datum/action.Trigger`,
AI movement, hand switching, item dropping, auto-equipping, pulling, resting, and resisting.
Non-combat interactions perform a bounded approach before `ClickOn`, so nearby tool use does not
require another model decision. Contextual screentip signals
provide descriptions such as repair, pry, heal, and deconstruct while the underlying click remains
authoritative.

The gateway never receives BYOND refs, type paths, click modifiers, combat-mode flags, action
datums, or arbitrary proc arguments. It receives an opaque `capability_id`; the associated
server-owned data is revalidated immediately before execution.

## Extending complex interactions

TGUI action names and parameters are not safe to infer. A machine, item, component, or element may
register `COMSIG_ATOM_NPC_REQUEST_CAPABILITIES` and add a semantic offer to the supplied request.
The provider should use a dedicated `/datum/npc_capability` subtype which:

1. exposes no raw refs or arbitrary arguments through `serialize()`;
2. checks ownership, range, access, tools, body state, and target state again in `begin()`;
3. uses the same server proc as the corresponding player operation;
4. runs sleeping work in the async lane by setting `async_execution = TRUE`;
5. reports only an attempted action until the game confirms its outcome;
6. cleans movement, signals, and owned state in `finish()`.

Multi-step work such as APC repair belongs in a local state machine or behavior subtree. The model
chooses the goal at a cognitive fork; Dream Maker performs movement, tool use, and `do_after`
steps without an HTTP call per tick.

The APC is the first concrete semantic provider. An unlocked adjacent APC offers breaker, charging,
and equipment, lighting, and environment channel controls. The APC domain revalidates adjacency,
lock state, silicon restrictions, operation name, and channel range immediately before mutation.

## Manual test

Use the admin verb **Give AI Controller** and select
**Sapient NPC (Arcadia AI Gateway)**. Author the name, role, biography, culture, voice, goals, and
cognition tier. The controller automatically pauses while a client owns the body.

Use the gateway mock mode first. It verifies transport, queueing, timeout, stale-response handling,
and persistence without a provider key. See `tools/npc_ai_gateway/README.md`.
