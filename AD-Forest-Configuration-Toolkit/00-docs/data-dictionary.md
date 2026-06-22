# Data Dictionary

## `forest-summary.csv`

| Column | Meaning |
| --- | --- |
| `ForestName` | Forest DNS name. |
| `RootDomain` | Forest root domain. |
| `ForestMode` | Forest functional level label from AD. |
| `ForestModeLevel` | Numeric forest functional level where readable. |
| `SchemaMaster` | Current schema master FSMO owner. |
| `DomainNamingMaster` | Current domain naming master FSMO owner. |
| `ConfigurationNamingContext` | Configuration naming context DN. |
| `SchemaNamingContext` | Schema naming context DN. |
| `RootDomainNamingContext` | Root domain naming context DN. |
| `PartitionsContainer` | Partitions container DN. |
| `DomainCount` | Number of domains found in the forest object. |
| `SiteCount` | Number of sites collected for context. |
| `GlobalCatalogCount` | Number of global catalogs collected for context. |
| `UpnSuffixes` | Forest UPN suffixes joined by semicolon. |
| `SpnSuffixes` | Forest SPN suffixes joined by semicolon. |
| `TombstoneLifetimeDays` | Tombstone lifetime from Directory Service settings. |
| `DeletedObjectLifetimeDays` | Deleted object lifetime where explicitly configured. |
| `CollectionStatus` | Source collection status. |
| `SourceCollection` | Source collection filename. |
| `Notes` | Merge notes or warnings. |

## `domain-summary.csv`

Contains one row per domain with functional level, FSMO owners, replica server lists, global catalog count, and selected domain-wide compatibility settings.

## `schema-summary.csv`

Contains schema naming context, `objectVersion`, product hint, schema master, schema timestamps, and schema update state where readable.

## `naming-contexts.csv`

Contains rootDSE-advertised naming contexts and cross-reference partition naming contexts, classified as configuration, schema, domain, application, or DNS application.

## `application-partitions.csv`

Contains application partitions and DNS application partitions with replica locations parsed from `msDS-NC-Replica-Locations` where available.

## `optional-features.csv`

Contains optional AD features, enabled scopes, feature scope, required forest mode, and a Recycle Bin marker.

## `forest-config-findings.csv`

Contains review findings generated from normalized inventory. Findings are advisory and should be validated by an AD engineer before migration decisions.

## `forest-config-relationships.csv`

See `05-templates/forest-config-relationships.data-dictionary.md`.

