---
name: arcadia-sql-config
description: Change Arcadia SQL queries, database schemas, migrations, cache behavior, distributed configuration, policy configuration, and backward-compatible server settings.
---

# Arcadia SQL and configuration

Read the SQL section of `.github/guides/STANDARDS.md`, `.github/guides/EZDB.md`, and `.github/guides/POLICYCONFIG.md` when applicable. Trace both DM consumers and deployment-facing files.

## SQL safety

- Parameterize every value and use `format_table_name` for table names. Never interpolate input or specify a database name.
- Name insert columns explicitly. Keep primary keys immutable, including during table conversions.
- Perform transformations atomically in SQL rather than read-modify-write races. For user-edited values, detect intervening changes before overwriting.
- Treat query input and returned rows as untrusted: validate types, bounds, nullability, authorization, and row ownership.
- Use the established query lifecycle and cleanup patterns; do not leak query datums.
- Database cache TTL is ten seconds unless a documented, compelling reason justifies longer.

## Schema changes

- Update canonical and prefixed schema files, add the SQL changelog migration, and bump the correct schema revision/DB version define.
- Make migrations safe for existing populated installations and explicit about destructive/irreversible transformations.
- Test clean schema creation and migration assumptions. Do not modify live/production data as part of development.

## Configuration

- Treat `config/` as user-owned after deployment. New defaults and parsers must preserve previous behavior when operators retain older files.
- Use existing config/policy readers, keys, validation, and reload behavior. Do not add a second parser or silently repurpose a key.
- Define missing, malformed, legacy, and reload behavior. Avoid leaking secrets through logs, UI, or diagnostics.
- Document operator-visible changes and validate both old and new configuration paths.
