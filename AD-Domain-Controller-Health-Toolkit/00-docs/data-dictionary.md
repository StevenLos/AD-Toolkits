# AD Domain Controller Health Data Dictionary

## Aggregation Outputs

| File | Purpose |
| --- | --- |
| `inventory.json` | Full normalized inventory used by renderers. |
| `dc-health-summary.csv` | One row per DC with identity, OS/build, GC/RODC/enabled state, share status, port availability, time summary, FSMO roles, findings, and status. |
| `dc-role-readiness.csv` | Planning flags for role transfer, decommission, and migration readiness. |
| `fsmo-roles.csv` | FSMO roles, scopes, holders, holder reachability, and transfer readiness. |
| `dc-services.csv` | Selected service-state evidence for `NTDS`, `Netlogon`, `DFSR`, `DNS`, `KDC`, and `W32Time`. |
| `dc-shares.csv` | `SYSVOL` and `NETLOGON` UNC presence evidence. |
| `dc-port-checks.csv` | Collector-perspective TCP checks for LDAP 389, LDAPS 636, GC 3268, and GC-LDAPS 3269. |
| `dc-locator-records.csv` | DC locator SRV query results and target-to-DC matching. |
| `dc-findings.csv` | Warning and critical findings with recommendations and evidence. |
| `dc-health-relationship-details.csv` | Diagram relationship CSV used by the renderer and editable future-state workflow. |

## Discovery Outputs

| File | Purpose |
| --- | --- |
| `*.dc-health.collection.json` | Full raw collection, including nested AD, service, share, port, FSMO, SRV, warning, and error evidence. Use this for aggregation. |
| `*.dc-health.summary.csv` | Human-readable one-row-per-DC discovery summary emitted beside the JSON. If discovery fails before DC enumeration, it still contains one failure row with collection status and error messages. |

## Severity and Status

| Severity | Meaning |
| --- | --- |
| `Info` | Evidence is present and no readiness concern was generated. |
| `Warning` | Review is needed before migration, role transfer, or decommission planning. |
| `Critical` | A generated blocker exists. Human review can override, but the toolkit treats it as unsafe by default. |

| Status | Meaning |
| --- | --- |
| `OK` | No warning or critical evidence for the row. |
| `Review` | Warning evidence exists. |
| `Blocked` | Critical evidence exists. |

## Important Fields

| Field | Description |
| --- | --- |
| `DomainControllerId` | Stable per-inventory DC ID such as `DC001`. |
| `RoleReadinessId` | Stable per-inventory readiness row ID such as `RR001`. |
| `FsmoRoleId` | Stable per-inventory FSMO row ID such as `F001`. |
| `ServiceCheckId` | Stable per-inventory service row ID such as `S001`. |
| `ShareCheckId` | Stable per-inventory share row ID such as `SH001`. |
| `PortCheckId` | Stable per-inventory port row ID such as `P001`. |
| `LocatorRecordId` | Stable per-inventory locator row ID such as `L001`. |
| `FindingId` | Stable per-inventory finding ID such as `FIND001`. |
| `DcHealthEdgeId` | Stable diagram relationship ID such as `DCH001`. |

## Interpretation Rules

- `LdapReachable`, `LdapsReachable`, `GcReachable`, and `GcLdapsReachable` are collector-perspective TCP checks, not proof of application-level LDAP bind success.
- `SYSVOL` and `NETLOGON` status is based on UNC path presence from the collector perspective.
- `TimeSource`, `TimeSourceType`, and `TimeServiceStatus` come from Time-Server-Toolkit inventory when available.
- `dc-role-readiness.csv` is planning evidence. It is not an instruction to transfer roles, demote DCs, or change production configuration.
