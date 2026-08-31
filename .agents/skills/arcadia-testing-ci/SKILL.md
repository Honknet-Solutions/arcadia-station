---
name: arcadia-testing-ci
description: Write, select, run, or diagnose Arcadia DM and TGUI tests, builds, linters, generated include enforcement, map checks, screenshot tests, and CI failures.
---

# Arcadia testing and CI

Read `.github/guides/CI.md`, `code/modules/unit_tests/README.md`, `tools/build/README.md`, and the relevant workflow under `.github/workflows/`.

## DM tests

- Put focused tests in the relevant file under `code/modules/unit_tests/`; create a topical file only when none exists.
- Use `/datum/unit_test/.../Run()`, production types/paths, `allocate()`/setup-teardown helpers, and the narrowest assertion with a diagnostic message.
- Model the real bug/behavior. Avoid test-only parallel logic and uncontrolled RNG.
- Keep tests independent, deterministic, and small. Use focus/repeat macros only locally; never leave `TEST_FOCUS` or `TEST_REPEAT` in committed changes.
- Keep `_unit_tests.dm` includes sorted and tool-enforced.

## Check selection

- DM behavior: targeted compile plus the focused unit/integration path.
- TGUI TS/TSX: `tools\build\build.bat tgui-lint tgui-test`.
- Maps/path changes: TGM/mapmerge validation, maplint, applicable map compile/integration tests.
- Icons/visuals: icon-cutter/DMI checks and screenshot tests where rendered output matters.
- SQL: schema/changelog/version consistency and clean/prefixed schema setup.
- Broad or foundational work: `tools\build\build.bat all` when practical.
- Documentation/skills only: format/link validation, skill validator, diff inspection, and `git diff --check`.

Use the supported build script; direct Dream Maker builds may omit generated TGUI/behavior-tree/icon work.

## Diagnosis

- Separate compile errors, DreamChecker/OpenDream lints, grep/ticked-file checks, unit runtimes, map-only failures, screenshot diffs, and flaky tests.
- Read the first causal failure and its surrounding output; later failures may be fallout.
- Do not dismiss a map-specific failure without testing whether the changed assumption varies by map.
- Report exact commands, pass/fail results, and anything not run. Never claim success from a build you did not execute.
