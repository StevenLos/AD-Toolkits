# Data Dictionary

## `hybrid-identity-summary.csv`

| Field | Meaning |
| --- | --- |
| `ComponentId` | Stable row identifier such as `CMP01`. |
| `ComponentType` | `EntraConnect`, `ADFS`, `PTA`, or manually supplied type. |
| `Name` | Component display name. |
| `ServerName` | Server where evidence was collected or supplied. |
| `Role` | Functional role, such as `Synchronization` or `Federation`. |
| `SyncMode` | Detected or supplied modes: password hash sync, PTA, federation, or unknown. |
| `PasswordHashSync` | `true`, `false`, `detected`, or blank when unknown. |
| `PassThroughAuthentication` | PTA evidence state. |
| `Federation` | Federation evidence state. |
| `StagingMode` | Entra Connect staging mode evidence. |
| `SourceAnchor` | Source anchor attribute or rule evidence. |
| `ImmutableIdAttribute` | Attribute used to populate cloud immutable ID/source anchor. |
| `WritebackFeatures` | Detected writeback features. |
| `Tenant` | Tenant value if supplied; sensitive identifiers are redacted by default. |
| `CollectionStatus` | Collection status from source export. |
| `Evidence` | Short evidence note. |
| `SourceCollection` | Source JSON or packaged export reference. |
| `Notes` | Reviewer notes. |

## `sync-connectors.csv`

| Field | Meaning |
| --- | --- |
| `ConnectorId` | Stable connector row ID. |
| `ConnectorName` | Connector display name. |
| `ConnectorType` | Connector technology, such as AD DS or Entra ID. |
| `ServerName` | Sync server associated with the connector. |
| `ForestOrTenant` | Forest, domain, or tenant represented by the connector. |
| `IsEnabled` | Connector enabled state if visible. |
| `Partitions` | Selected naming contexts or partitions. |
| `IncludedOUs` | Included OU/container summary. |
| `ExcludedOUs` | Excluded OU/container summary. |
| `ConnectorSpaceObjectCount` | Connector space count if supplied. |
| `LastImport` | Last import timestamp if supplied. |
| `LastExport` | Last export timestamp if supplied. |
| `LastSync` | Last run timestamp if supplied. |
| `SourceCollection` | Source JSON or packaged export reference. |
| `Notes` | Reviewer notes. |

## `sync-scope-summary.csv`

Summarizes scope and filtering from connector evidence.

Key fields: `ScopeType`, `Forest`, `Domain`, `Partition`, `IncludedOUs`, `ExcludedOUs`, `FilteringMode`, `ObjectTypes`, `GroupsScoped`, and `ConnectorName`.

## `sync-rules-summary.csv`

Summarizes sync rules without dumping full rule bodies.

Key fields: `RuleName`, `Direction`, `Precedence`, `ConnectorName`, `ConnectedSystem`, `LinkType`, `SourceObjectType`, `TargetObjectType`, `Enabled`, `ImmutableTag`, `TransformSummary`, and `JoinSummary`.

## `federation-adfs-farm.csv`

Farm-level AD FS and WAP/proxy summary. Certificate fields focus on expiration and risk, not private key material.

Key fields: `ServiceName`, `FederationServiceIdentifier`, `BehaviorLevel`, `Servers`, `Proxies`, `TokenSigningCertExpires`, `TokenDecryptingCertExpires`, and `CertificateRisk`.

## `federation-relying-parties.csv`

AD FS relying party trust summary. Claim rule fields are summaries by default.

Key fields: `Name`, `Identifier`, `Enabled`, `ProtocolProfile`, `AccessControlPolicyName`, `IssuanceAuthorizationRulesSummary`, `IssuanceTransformRulesSummary`, `ClaimRulesSummary`, `TokenLifetime`, and `SignatureAlgorithm`.

## `federation-certificates.csv`

Certificate expiration review data.

Key fields: `CertificateType`, `IsPrimary`, `Subject`, `Thumbprint`, `NotBefore`, `NotAfter`, `DaysUntilExpiration`, and `Risk`.

## `hybrid-findings.csv`

Generated review findings. Findings identify incomplete collection, certificate expiration risk, staging mode evidence, low PTA agent evidence, and redaction state.

## `hybrid-endpoints-ports.csv`

Reference endpoint and port review data. `EvidenceType` is `ReferenceOnly`; rows are not reachability proof.

## `topology-relationships.csv`

Diagram edge data. `HybridEdgeId` maps to labels shown in rendered topology diagrams.
