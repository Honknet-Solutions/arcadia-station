---
name: arcadia-repository-navigation
description: Locate Arcadia SS13 code ownership, dependencies, generated files, and validation paths before planning cross-cutting BYOND DM, TGUI, map, asset, configuration, or tooling changes.
---

# Arcadia repository navigation

Use this skill when ownership is unclear, a task spans repository areas, or generated consumers may exist.

## Investigate

1. Read root `AGENTS.md` and any closer instruction file.
2. Record pre-existing work with `git status --short --branch`.
3. Search semantic anchors with `rg -n`: type paths, proc names, signals, defines, interface names, config keys, map instances, and tests.
4. Trace definitions, parents, initialization, and registration, then callers, listeners, consumers, and teardown.
5. Inspect neighboring implementations and choose the pattern used by current Arcadia code in that domain.
6. Identify generated files and their source/tool before proposing edits.

Read [references/repository-map.md](references/repository-map.md) for an unfamiliar or cross-cutting task. Skip it when the owner and dependency path are already clear.

## Architecture output

Before code, state:

- exact systems/types/files expected to change;
- data/control flow and ownership;
- lifecycle, performance, security, map/schema, and compatibility risks;
- targeted tests and build checks;
- explicit out-of-scope boundaries.

The project is Arcadia. Keep inherited names such as `tgstation.dme` only where build compatibility requires them.
