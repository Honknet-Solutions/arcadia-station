---
name: arcadia-subsystems-performance
description: Design or optimize Arcadia Master Controller subsystems, processing collections, timers, movement loops, spatial queries, verbs, and other BYOND DM hot paths.
---

# Arcadia subsystems and performance

Read `.github/guides/STANDARDS.md`, `.github/guides/TICK_ORDER.md`, relevant definitions in `code/__DEFINES/subsystems.dm`, and neighboring subsystem implementations.

## Architecture

- Prefer an existing subsystem/processing collection when its cadence and ownership match. Create a subsystem only for coherent global scheduling/state.
- Define initialization order, wait/cadence, priority, runlevel, offline behavior, recovery, shutdown, and ownership explicitly.
- Register/unregister processed objects symmetrically. Never rely on qdel to clean an external collection accidentally.
- Use `seconds_per_tick` for frame independence.
- In resumable `fire()` work, preserve queue/progress correctly and honor Master Controller tick checks. Do not restart completed work after a yield.
- Offload expensive verb work to the appropriate subsystem because verbs execute late in the BYOND tick.

## Hot-path rules

- Never scan all atoms/entities each tick. Use existing registries, spatial structures, view/range helpers appropriate to the domain, or event-driven membership.
- Do not sleep in `fire()`, signal handlers, or processing callbacks. Use subsystem yielding/timers at explicit boundaries.
- Avoid repeated list copies, dynamic type enumeration, associated-list lookup, icon creation, regex compilation, and allocation in hot loops.
- Use `SSmove_manager`, not BYOND `walk*()`.
- Cache only when invalidation and memory cost are clear. Do not introduce permanent global caches for unbounded keys.
- Preserve delta-time and random/probability semantics when cadence changes.

## Evidence

For optimization work, capture a baseline with the existing profiler/MC tooling and compare the same workload. Report CPU/tick/memory tradeoffs; intuition alone is not proof. Add behavior tests separately because a faster wrong path is still wrong.
