# DNS Relationship Details CSV Data Dictionary

| Column | Purpose |
| --- | --- |
| `DnsEdgeId` | Stable diagram edge ID such as `D01`. Must map to labels in the combined diagram. |
| `Source` | Source object name. Usually DNS server, hosted zone, delegation source, or forwarding server. |
| `SourceType` | Object type such as `DnsServer`, `DnsZone`, `ADSite`, `ExternalDns`, or `NameServer`. |
| `Relationship` | Relationship type such as `HostsZone`, `ForwardsTo`, `ConditionalForwarder`, `DelegatesTo`, `AuthoritativeNS`, or `RootHint`. |
| `Target` | Target object name. |
| `TargetType` | Target object type. |
| `ZoneName` | DNS zone involved in the relationship when applicable. |
| `RecordType` | DNS record type behind the relationship when applicable, such as `NS`, `SOA`, or `Forwarder`. |
| `Direction` | Direction for diagram arrows, such as `SourceToTarget`, `TargetToSource`, or `Bidirectional`. |
| `SiteName` | AD site associated with the source DNS server when known. |
| `SubnetName` | AD subnet associated with the source DNS server when known. |
| `TargetSiteName` | AD site associated with the target when known or manually supplied. |
| `TargetSubnetName` | AD subnet associated with the target when known or manually supplied. |
| `DnsServer` | DNS server that contributed or owns the relationship. |
| `Order` | Forwarder or processing order when the relationship is ordered. |
| `Priority` | Priority value when applicable, such as SRV or MX style prioritization context. |
| `Status` | `Discovered`, `Planned`, `Changed`, `Retired`, or another review status. |
| `SourceCollectionServer` | DNS server or AD source collection that produced the row. |
| `Notes` | Human-readable context, caveats, or review notes. |

## Expected Values

Recommended `SourceType` and `TargetType` values:

- `DnsServer`
- `DnsZone`
- `ADSite`
- `ExternalDns`
- `NameServer`

Recommended `Relationship` values:

- `HostsZone`
- `ForwardsTo`
- `ConditionalForwarder`
- `DelegatesTo`
- `AuthoritativeNS`
- `RootHint`
