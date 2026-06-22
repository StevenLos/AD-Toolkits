# DC Health Relationship CSV Data Dictionary

`dc-health-relationship-details.csv` is the editable diagram CSV. Edge IDs are stable within one generated inventory and map to diagram labels.

| Column | Description |
| --- | --- |
| `DcHealthEdgeId` | Stable diagram edge ID such as `DCH001`. |
| `Source` | Source object label, usually a domain controller FQDN. |
| `SourceType` | Source type. Supported values: `DomainController`, `ExternalDependency`. |
| `Relationship` | Relationship type: `ServesDomain`, `LocatedInSite`, `HoldsFsmo`, `UsesTimeSource`, `HasFinding`, or `DependsOn`. |
| `Target` | Target object label such as domain name, site name, FSMO role, time source, or finding category. |
| `TargetType` | Target type: `ADDomain`, `ADSite`, `FSMORole`, `TimeSource`, `FindingCategory`, or `ExternalDependency`. |
| `DomainName` | AD domain context for the relationship. |
| `SiteName` | AD site context for the relationship. |
| `RoleName` | FSMO role name when `Relationship` is `HoldsFsmo`. |
| `Severity` | `Info`, `Warning`, or `Critical`. |
| `Status` | Clear review status such as `OK`, `Review`, or `Blocked`. |
| `Notes` | Short evidence or planning note. |

Keep manually edited future-state rows deterministic by preserving existing IDs and appending new IDs at the end.
