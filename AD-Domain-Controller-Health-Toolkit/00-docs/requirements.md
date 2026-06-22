# Requirements

## Functional Requirements

- Collect domain controllers with domain, site, forest, GC, RODC, enabled, OS, OS version, build, and IP address fields.
- Collect FSMO role holders for forest and domain roles.
- Test FSMO holder reachability from the collector perspective using LDAP TCP/389 when port checks are enabled.
- Collect `SYSVOL` and `NETLOGON` share presence using read-only UNC path checks.
- Collect selected service state where safely readable: `NTDS`, `Netlogon`, `DFSR`, `DNS`, `KDC`, and `W32Time`.
- Collect DC locator SRV registration summary using DNS SRV queries.
- Collect LDAP/LDAPS/GC TCP availability from the collector perspective.
- Consume existing Time-Server-Toolkit inventory when present and avoid duplicate W32Time discovery logic.
- Produce health summary, readiness, FSMO, service, share, locator, finding, inventory, and diagram outputs.

## Non-Functional Requirements

- Discovery must be read-only.
- Scripts must continue when individual checks fail and preserve warnings/errors in the collection JSON.
- Aggregation must use deterministic IDs and clear `Severity`/`Status` fields.
- Renderers must run offline with Python 3 and no third-party Python dependencies.
- CSV render workflow must support manually edited current-state or future-state relationship files.

## Explicit Non-Goals

- No service restarts.
- No `dcdiag` remediation.
- No FSMO transfer or seizure.
- No DC demotion or metadata cleanup.
- No DNS registration forcing.
- No comprehensive W32Time collection beyond consuming sibling toolkit output.
