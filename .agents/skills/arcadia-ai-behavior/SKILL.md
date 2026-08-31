---
name: arcadia-ai-behavior
description: Implement or modify Arcadia AI controllers, blackboards, behavior trees, decorators, subtrees, targeting strategies, movement, and AI performance in BYOND DM.
---

# Arcadia AI behavior

Read `code/datums/ai/README.md`, `code/datums/ai/learn_ai.md`, neighboring controllers/nodes, and `code/controllers/subsystem/ai_controllers.dm`.

## Model

- Keep state and decision data in the controller blackboard using existing key defines.
- Make leaf behaviors concrete actions, decorators reactive conditions, selectors alternatives, sequences ordered dependencies, parallels intentional concurrency, and subplans bounded retry loops.
- Reuse subtrees for shared plans. Add a new node only when existing nodes plus bindings/strategies cannot express the behavior cleanly.
- Add observers/signals for conditions that can change during a running plan; a looping subplan must always have a valid exit/cancellation path.

## Targeting and movement

- Prefer generic acquisition leaves with existing target sources, targeting strategies, and priority strategies.
- Do not scan all atoms or invent a per-AI global search. Use bounded existing sources and appropriate vision/range.
- Store dynamic targets in blackboard keys and handle qdeleted/invalid targets.
- Use existing AI movement datums and `SSmove_manager`; do not call BYOND `walk*()`.
- Bound retries and acquisition cadence to avoid hot-looping high-pop rounds.

## Source and validation

Edit source `.bt.json` with the intended behavior-tree tooling and refresh types after node changes. Do not edit compiled JSON under `build/behavior_trees`.

Test success, failure, running, observer cancellation, target loss, path failure, and cleanup. Run the behavior-tree compiler through the normal build and add focused DM tests for reusable behavior.
