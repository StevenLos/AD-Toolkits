# Low-Level Design

## Discovery

Discovery uses the Active Directory module for forest, domain, and DC metadata. It then performs optional read-only checks:

- CIM `Win32_Service` read for selected service states.
- `Test-Path` against `\\dc\SYSVOL` and `\\dc\NETLOGON`.
- TCP socket connection attempts for ports 389, 636, 3268, and 3269.
- DNS SRV lookups with `Resolve-DnsName`.

Each check records row-level status and error text. Failures are warnings unless a fatal setup issue prevents collection.

## Aggregation

Aggregation recursively reads `*.collection.json` files and includes only `Metadata.CollectionType = ADDomainControllerHealth`. Latest DC, service, share, port, and FSMO rows win when duplicate evidence exists.

Generated IDs are assigned after sorting:

- DCs by domain, site, hostname.
- Services by DC and service order.
- Shares by DC and share order.
- Ports by DC and port order.
- FSMO roles by scope and role.
- Findings by severity, DC, category, and finding text.

## Finding Rules

Critical examples:

- `NTDS`, `Netlogon`, `DFSR`, or `KDC` not running.
- `SYSVOL` or `NETLOGON` missing.
- LDAP TCP/389 unavailable.
- FSMO holder unreachable, missing, disabled, or read-only.

Warning examples:

- LDAPS unavailable.
- GC-LDAPS unavailable.
- Service/share/port evidence not collected.
- No locator SRV records match a DC.
- Time-Server-Toolkit reports local clock, unknown time source, or non-running W32Time.
- DC holds FSMO roles or is the only discovered GC during decommission planning.

## Rendering

The renderer accepts either `inventory.json` or `dc-health-relationship-details.csv`. The combined view shows DCs grouped by site and relationship targets grouped by type. The source view shows one lane per DC with relationship rows.
