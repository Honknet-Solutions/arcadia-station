---
name: arcadia-tgui
description: Build or modify Arcadia player-facing TGUI interfaces, shared TypeScript/TSX components, and secure Dream Maker ui_interact, ui_data, ui_static_data, and ui_act backends.
---

# Arcadia TGUI

Read the UI section of `.github/guides/STANDARDS.md`, `tgui/README.md`, and the relevant guides under `tgui/docs/`. Inspect a current neighboring interface before following older examples.

## Boundary design

- New player-facing UIs use TGUI unless the UI is critical. Critical interfaces retain an HTML/interface fallback and cannot depend exclusively on TGUI.
- Keep authority and gameplay state in DM. TSX renders data, manages presentation state, and submits intent.
- Expose only values the client needs. Serialize numbers, strings, booleans, nulls, and clean lists/objects; do not expose raw datum authority.
- Use `ui_static_data` for stable payloads and `ui_data` for changing state when established patterns support it.

## DM backend

- Reuse `SStgui.try_update_ui` and the normal `ui_interact` lifecycle.
- In `ui_act`, preserve the parent result and stop when the parent handled/denied the action.
- Treat action names and params as hostile. Validate type, bounds, membership, authorization, reachability, ownership, and current state server-side.
- Revalidate after delayed input. Prevent stale or repeated actions from duplicating effects.
- Return handled state consistently so non-autoupdating interfaces refresh correctly.

## Frontend

- Match current TypeScript types, hooks, shared components, layouts, and naming.
- Prefer existing primitives over one-off CSS/components. Extract a component when it creates a real reusable or readable boundary.
- Prefer arrays for ordered collections; add stable keys and handle empty/loading/null states.
- Preserve accessibility, theme behavior, window sizing, scrolling, and interaction feedback.
- Do not mask invalid server data with unsafe assertions; fix or explicitly model the boundary.

Run `tools\build\build.bat tgui-lint tgui-test`; add a focused test for pure helpers/components when practical and manually exercise DM-to-UI actions for gameplay changes.
