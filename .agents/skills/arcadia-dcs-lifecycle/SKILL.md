---
name: arcadia-dcs-lifecycle
description: Design or modify Arcadia signals, components, elements, traits, callbacks, weakrefs, initialization, qdel cleanup, garbage collection, and hard-delete prevention.
---

# Arcadia DCS and lifecycle

Read the relevant local contracts before editing:

- `code/datums/components/README.md`, `COMPONENT_TEMPLATE.md`, and `_component.dm`;
- `code/datums/elements/ELEMENT_TEMPLATE.md` and `_element.dm`;
- `code/__DEFINES/dcs/declarations.dm`;
- the signal section of `.github/guides/STANDARDS.md`;
- `.github/guides/HARDDELETES.md`.

## Select a mechanism

- Inheritance: intrinsic behavior in one coherent hierarchy.
- Component: reusable behavior with per-parent state or independent lifetime.
- Element: lightweight shared behavior; non-bespoke elements cannot hold attachment-specific mutable state.
- Signal: an authoritative event whose sender must not know observers.
- Trait: a boolean capability/state granted by multiple source-aware owners.
- Callback/timer: explicit deferred invocation, not a lifecycle substitute.

Reuse an existing semantic event/mechanism before creating another.

## Lifetime

- Register lists, subsystems, signals, timers, and paired references only after required state exists.
- Every long-lived registration and strong reference needs an end path.
- `Destroy()` stops processing/movement, unregisters observation, removes registries, clears owned references, and returns `..()`.
- Use `qdel()`, `QDEL_NULL()` for owned datums, and weakrefs for non-owned observations that tolerate disappearance.
- For a necessary hot strong reference, observe `COMSIG_QDELETING` and clear it.

## Signals and DCS

- Put signal declarations and argument contracts in the closest topical file under `code/__DEFINES/dcs/signals/`.
- Register with the correct `PROC_REF` macro; handlers begin with `SIGNAL_HANDLER`, never sleep, and unregister symmetrically.
- If a target changes, unregister the old target before registering the new one. Use `override = TRUE` only with a comment proving duplicate registration is intentional.
- Component `Initialize()` returns `COMPONENT_INCOMPATIBLE` instead of qdeling itself. Parent signals belong in `RegisterWithParent()`/`UnregisterFromParent()`.
- Choose component `dupe_mode` deliberately and implement its source/inheritance/selection contract. Enable transfer only with correct pre/post transfer behavior.
- Element `Attach()`/`Detach()` call parent and mirror signal changes. Use BESPOKE/hash bounds, COMPLEX_DETACH, and DETACH_ON_HOST_DESTROY only for their documented need.

## Verification

Test attach/register, behavior, detach/unregister, duplicate policy, and deletion. Verify both sides of paired-reference deletion and no stale registries. Use repository reference tracking for hard-delete diagnosis rather than guessing.
