# Forest Configuration Relationship CSV

## Columns

| Column | Meaning |
| --- | --- |
| `ForestConfigEdgeId` | Stable edge ID shown on diagrams. |
| `Source` | Source object name. |
| `SourceType` | Source object type. |
| `Relationship` | Relationship type. |
| `Target` | Target object name. |
| `TargetType` | Target object type. |
| `PartitionType` | Partition classification where relevant. |
| `NamingContext` | Naming context DN where relevant. |
| `DomainName` | Related domain DNS name where relevant. |
| `ReplicaServers` | Replica server names joined by semicolon. |
| `Status` | `Observed`, `Planned`, `Review`, or `Removed`. |
| `SourceCollection` | Source collection file or manual source. |
| `Notes` | Reviewer notes. |

## Supported Object Types

- `Forest`
- `Domain`
- `Schema`
- `NamingContext`
- `ApplicationPartition`
- `DnsApplicationPartition`
- `DomainController`
- `GlobalCatalog`
- `OptionalFeature`
- `Suffix`

## Supported Relationships

- `ContainsDomain`
- `HasNamingContext`
- `HasApplicationPartition`
- `HasDnsApplicationPartition`
- `ReplicatedTo`
- `SchemaMaster`
- `DomainNamingMaster`
- `EnabledOptionalFeature`
- `ConfiguredSuffix`

