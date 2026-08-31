---
name: arcadia-dm-core
description: Implement or review general Arcadia Dream Maker code, including atoms, datums, procs, helpers, defines, interactions, and secure server-authoritative gameplay.
---

# Arcadia DM core

Before editing, read applicable sections of `.github/guides/STYLE.md`, `.github/guides/STANDARDS.md`, and `.github/guides/AUTODOC.md` for public APIs.

## Design

- Find existing types, overrides, helpers, signals, traits, and tests before adding code.
- Prefer object-oriented extension or a narrow reusable proc over duplicated branches and feature-specific checks in root types.
- Put behavior in its feature domain. Expand root atoms, helpers, or globals only for a genuine cross-cutting contract.
- Preserve named-argument and parent-call compatibility on overrides.

## DM form

- Use tabs, LF, complete leading-slash paths, snake_case identifiers, and descriptive typed vars.
- Prefer early returns and shallow flow. Keep control bodies off the condition line.
- Use `variable & FLAG`; use `var/static` instead of DM's misleading type-level `global`.
- Replace magic modes with scoped defines. Use `SECONDS`, `MINUTES`, and `HOURS` instead of raw deciseconds.
- Use named arguments when booleans/numbers are unclear. Prefer explicit returns; `. = ..()` is the normal parent-result pattern.
- Multiline calls/lists use one indent and trailing commas. Backslashes are only for macros that require them.
- Use compile-time type paths, never unchecked text paths or `:` type-safety bypasses.
- Make macros hygienic, parenthesized, and unsurprising; cache repeated inputs and `#undef` file-local macros.
- Use associated lists only for genuinely dynamic keys, not as a reflexive substitute for vars or indexed lists.

## Security

- Treat client input, `usr`, Topic/href values, TGUI params, refs, and delayed prompt results as hostile.
- Sanitize/clamp server-side and validate reach, ownership, state, authorization, and target validity again after input/asynchronous waits.
- Prevent simultaneous prompts/actions that could duplicate effects.
- Never resolve a player-controlled ref with unrestricted `locate(ref)`; constrain resolution to the expected collection and verify type/state.

## Lifecycle and verification

- Prefer `Initialize()` for atoms, but do not convert unrelated old `New()` code casually.
- Do not sleep in signal callbacks or no-sleep contracts; create an explicit async boundary.
- Document intent, units, nullability, ownership, side effects, security revalidation, and unusual parent behavior.
- Add focused tests for bug fixes and reusable logic. Use `arcadia-testing-ci` for final checks.
