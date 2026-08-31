# Arcadia repository map

This is a routing map, not an exhaustive inventory. Confirm every path against the current tree.

## Runtime code

- `code/__DEFINES/`: compile-order-sensitive defines, flags, signals, and declarations.
- `code/__HELPERS/`: reusable global helpers, not feature-specific behavior.
- `code/_globalvars/`: registries and global state; inspect initialization and cleanup.
- `code/controllers/`: game controller, Master Controller, config controller, and subsystems.
- `code/datums/`: reusable datums, DCS, callbacks, actions, and AI.
- `code/game/`: foundational atom, mob, object, area, turf, and machinery behavior.
- `code/modules/`: feature-domain implementations and `code/modules/unit_tests/`.

Follow feature ownership rather than inventing a downstream dumping folder.

## Interfaces, maps, and data

- `tgui/packages/tgui/` and `tgui/docs/`: TypeScript/TSX interfaces and UI guidance.
- `interface/`, `html/`: BYOND skin and browser resources.
- `_maps/`: station maps, ruins, z-levels, shuttles, templates, and modular pieces.
- `icons/`, `sound/`, `strings/`: presentation assets and structured content.
- `config/`, `cfg/`: distributed/runtime configuration surfaces.
- `SQL/`: schemas and database changelogs.
- `data/`, `tmp/`: generally runtime/generated state, not source.

## Tooling

- `tgstation.dme`: inherited DME name and compile include order.
- `tools/build/`: supported DM/TGUI/behavior-tree/icon build graph.
- `tools/ci/` and `.github/workflows/`: authoritative CI composition.
- `tools/ticked_file_enforcement/`: DME and unit-test include enforcement.
- `tools/mapmerge2/`, `tools/maplint/`, `tools/UpdatePaths/`, `tools/hooks/`: map-safe changes.
- `.github/guides/`: upstream-derived technical guidance used unless Arcadia overrides it.

## Common dependency paths

- New DM file: topical implementation -> defines/signals if required -> DME include -> focused unit test -> build.
- New TGUI: DM `ui_*` backend -> TSX interface -> test -> TGUI checks.
- Type-path rename: DM callers -> maps/config/strings -> UpdatePaths script -> map validation.
- Schema change: DM query behavior -> schemas -> changelog -> DB version -> clean/prefixed schema checks.
- Behavior-tree change: DM nodes/controllers and source `.bt.json` -> build compiler -> AI tests.
