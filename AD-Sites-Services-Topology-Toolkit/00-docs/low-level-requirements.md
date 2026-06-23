# Active Directory Sites And Services Diagram Low-Level Requirements

## 1. Purpose

Build a toolkit that discovers Active Directory Sites and Services configuration, exports the relevant inventory, normalizes that data into diagram-ready CSV files, and renders tables and diagrams using the same general workflow as the existing high-level network diagram sample.

The toolkit must let an engineer run one discovery command against an AD forest or domain controller, review the generated CSV inventory, and produce a stakeholder-ready SVG diagram with supporting tables.

## 2. Scope

### 2.1 In Scope

- Discover AD forest, domain, site, subnet, site link, site link bridge, IP transport, domain controller, and optional read-only replication connection/health/topology evidence.
- Export raw discovered data to CSV and JSON for audit and troubleshooting.
- Generate normalized diagram CSVs compatible with the existing high-level renderer pattern.
- Render an SVG diagram and normalized inventory JSON from the generated CSVs.
- Provide a mock example dataset that works without live AD access.
- Provide setup/preflight validation for both discovery prerequisites and generated CSV consistency.
- Document an offline workflow and a live AD workflow.

### 2.2 Out Of Scope For MVP

- Modifying Active Directory configuration.
- Running replication health remediation.
- Building Group Policy coverage.
- Testing firewall reachability between sites.
- Producing Visio, Draw.io, or PowerPoint output.
- Automatically determining all required firewall ports from AD alone.
- Proving active replication paths or current bridgehead selection from site links alone.
- Replacing AD Sites and Services as the authoritative management tool.
- Rendering exact geographic maps.

## 3. Target Folder Structure

The new toolkit should follow the sample project shape while adding a discovery phase:

```text
AD-Sites-Services-Topology-Toolkit/
  README.md
  00-docs/
    high-level-requirements.md
    low-level-requirements.md
    RUNBOOK.md
    data-dictionary.md
  01-discovery/
    Export-ADSitesAndServicesInventory.ps1
    Convert-ADSitesAndServicesExportToDiagramCsv.ps1
  01-setup/
    Test-ADSitesAndServicesDiagramEnvironment.ps1
  02-render-from-csv/
    Render-ADSitesAndServicesDiagram.py
    New-ADSitesAndServicesDiagramFromCsv.ps1
  03-templates/
    My-ADSS-Project-Template/
      diagram-inputs.csv
      discovery-settings.csv
      input/
      raw/
      output/
  04-examples/
    mock-forest-sites/
      diagram-inputs.csv
      discovery-settings.csv
      input/
      raw/
      output/
  05-projects/
```

## 4. Functional Requirements

### 4.1 Discovery Script

`Export-ADSitesAndServicesInventory.ps1` must collect AD Sites and Services data without changing AD.

Required parameters:

| Parameter | Required | Purpose |
| --- | --- | --- |
| `OutputPath` | Yes | Folder where raw exports are written. |
| `Server` | No | Domain controller or AD Web Services endpoint to query. |
| `Credential` | No | Alternate credential for AD queries. |
| `ForestName` | No | Optional forest target when not inferred from current context. |
| `FullInventory` | No | Convenience switch that enables configured replication connections, observed replication metadata, DC hostname DNS resolution, and SRV record summary collection. |
| `IncludeReplicationConnections` | No | Collect configured replication connection objects when enabled. |
| `IncludeReplicationMetadata` | No | Collect observed replication partner metadata, failures, queue indicators, derived topology edges, and health summary where available. |
| `CollectIpTransport` | No | Collect transport-level bridge-all-site-links settings when possible. |
| `ResolveDns` | No | Resolve domain controller hostnames to IP addresses. |
| `IncludeSrvRecordSummary` | No | Query DC locator and related SRV records for summary evidence. |
| `Anonymize` | No | Replace sensitive names/IPs with deterministic placeholders. |
| `Force` | No | Overwrite existing export files. |
| `PassThru` | No | Return a summary object to the pipeline. |

Required behavior:

- Verify the Active Directory PowerShell module is available before querying.
- Use read-only AD cmdlets and LDAP/ADWS reads only.
- Create `OutputPath` if it does not exist.
- Fail before overwriting existing files unless `-Force` is provided.
- Write a run metadata file containing timestamp, user, computer, PowerShell version, module version, command parameters, and warnings.
- Continue collecting independent datasets when one optional dataset fails, but record the failure in metadata.
- Exit non-zero on required dataset failure.
- Keep configured connection objects separate from observed replication partner metadata by preserving an explicit evidence type in topology outputs.
- Never call mutating AD replication cmdlets or perform remediation.

### 4.2 Raw Export Files

The discovery script must write these raw files:

| File | Required | Description |
| --- | --- | --- |
| `forest.csv` | Yes | Forest name, root domain, domains, functional level, schema master, domain naming master, global catalog list, site count. |
| `domains.csv` | Yes | Domain names, NetBIOS names, domain mode, PDC emulator, RID master, infrastructure master. |
| `sites.csv` | Yes | AD replication sites and site metadata. |
| `subnets.csv` | Yes | AD replication subnets and assigned sites. |
| `site-links.csv` | Yes | AD site links, transport, sites included, cost, schedule, frequency. |
| `site-link-bridges.csv` | No | Site link bridge objects when present. |
| `ip-transport.csv` | Yes | Per-transport bridge-all-site-links state and transport container metadata. |
| `domain-controllers.csv` | Yes | Domain controllers, domains, sites, hostnames, OS, GC flag, FSMO roles when known. |
| `replication-connections.csv` | No | Configured replication connection objects when requested. |
| `replication-partner-metadata.csv` | No | Observed inbound/outbound replication partner metadata when requested and available. |
| `replication-failures.csv` | No | Observed replication failures when requested and available. |
| `replication-topology-edges.csv` | No | Derived topology evidence rows across configured connections, observed metadata, failures, and queue indicators. |
| `replication-health-summary.csv` | No | Per-domain-controller read-only replication health summary. |
| `run-metadata.json` | Yes | Discovery metadata, warnings, errors, and source context. |
| `raw-inventory.json` | Yes | JSON representation of all collected raw datasets. |

### 4.3 Raw Dataset Columns

#### 4.3.1 `forest.csv`

Required columns:

- `ForestName`
- `RootDomain`
- `ForestMode`
- `SchemaMaster`
- `DomainNamingMaster`
- `Domains`
- `GlobalCatalogs`
- `SiteCount`
- `Notes`

#### 4.3.2 `sites.csv`

Required columns:

- `SiteName`
- `DistinguishedName`
- `Description`
- `Location`
- `Options`
- `WhenCreated`
- `WhenChanged`
- `SourceServer`
- `Notes`

#### 4.3.3 `subnets.csv`

Required columns:

- `SubnetName`
- `Cidr`
- `SiteName`
- `Location`
- `Description`
- `DistinguishedName`
- `WhenCreated`
- `WhenChanged`
- `Notes`

`SubnetName` and `Cidr` are expected to match because an AD subnet object's name is normally the CIDR. Keeping both fields is allowed so malformed or normalized values can be flagged explicitly.

#### 4.3.4 `site-links.csv`

Required columns:

- `SiteLinkName`
- `Transport`
- `SitesIncluded`
- `SiteCount`
- `Cost`
- `ReplicationFrequencyInMinutes`
- `Schedule`
- `Options`
- `Description`
- `DistinguishedName`
- `WhenCreated`
- `WhenChanged`
- `Notes`

`SitesIncluded` must use a deterministic delimiter, recommended `;`, because site links can include more than two sites.

`Schedule` must be a coarse CSV-safe summary such as `24x7`, `None`, or `Custom - see raw-inventory.json`. Full schedule detail belongs in `raw-inventory.json`.

#### 4.3.5 `ip-transport.csv`

Required columns:

- `TransportName`
- `BridgeAllSiteLinks`
- `DistinguishedName`
- `Options`
- `Notes`

The Active Directory PowerShell module does not expose all transport settings through a dedicated high-level cmdlet. The implementation may need `Get-ADObject` or ADSI reads against the transport container. The exact `options` bit interpretation must be confirmed in a lab or live test forest before implementation is considered complete.

#### 4.3.6 `domain-controllers.csv`

Required columns:

- `HostName`
- `Name`
- `Domain`
- `Forest`
- `SiteName`
- `IPv4Address`
- `OperatingSystem`
- `OperatingSystemVersion`
- `IsGlobalCatalog`
- `IsReadOnly`
- `Enabled`
- `LdapPort`
- `SslPort`
- `OperationMasterRoles`
- `PreferredBridgeheadTransports`
- `DistinguishedName`
- `Notes`

#### 4.3.7 `replication-connections.csv`

Configured replication connection objects must be exported separately from observed partner metadata.

Required columns:

- `ConnectionId`
- `ConnectionName`
- `SourceServer`
- `SourceSite`
- `DestinationServer`
- `DestinationSite`
- `Transport`
- `Enabled`
- `AutoGenerated`
- `Options`
- `Schedule`
- `DistinguishedName`
- `WhenCreated`
- `WhenChanged`
- `Notes`

#### 4.3.8 `replication-partner-metadata.csv`

Observed partner metadata must represent read-only replication state where AD exposes it.

Required columns:

- `MetadataId`
- `Direction`
- `SourceServer`
- `SourceSite`
- `DestinationServer`
- `DestinationSite`
- `NamingContext`
- `LastSuccess`
- `LastFailure`
- `ConsecutiveFailureCount`
- `ResultCode`
- `ResultMessage`
- `Transport`
- `PartnerAddress`
- `Status`
- `Notes`

#### 4.3.9 `replication-failures.csv`

Required columns:

- `FailureId`
- `SourceServer`
- `SourceSite`
- `DestinationServer`
- `DestinationSite`
- `NamingContext`
- `FirstFailure`
- `LastFailure`
- `ConsecutiveFailureCount`
- `ResultCode`
- `ResultMessage`
- `FailureType`
- `Status`
- `Notes`

#### 4.3.10 `replication-topology-edges.csv`

`ReplicationEdgeId` values must be deterministic, using IDs such as `RPL001` after stable sorting or a stable source/destination/naming-context-derived ID.

Required columns:

- `ReplicationEdgeId`
- `EvidenceType`
- `SourceServer`
- `SourceSite`
- `DestinationServer`
- `DestinationSite`
- `NamingContext`
- `Transport`
- `LastSuccess`
- `LastFailure`
- `ConsecutiveFailureCount`
- `ResultCode`
- `ResultMessage`
- `Status`
- `EvidenceId`
- `Notes`

Allowed `EvidenceType` values:

- `ConfiguredConnection`
- `ObservedPartnerMetadata`
- `ReplicationFailure`
- `ReplicationQueue`

#### 4.3.11 `replication-health-summary.csv`

Required columns:

- `DomainController`
- `SiteName`
- `PartnerMetadataCount`
- `ConfiguredConnectionCount`
- `FailureCount`
- `QueueOperationCount`
- `LastSuccess`
- `LastFailure`
- `Status`
- `Notes`

### 4.4 Normalization Script

`Convert-ADSitesAndServicesExportToDiagramCsv.ps1` must transform raw discovery output into the renderer input CSV files.

Required parameters:

| Parameter | Required | Purpose |
| --- | --- | --- |
| `RawPath` | Yes | Folder containing discovery raw files. |
| `InputPath` | Yes | Folder where normalized diagram CSVs are written. |
| `OutputPath` | No | Folder where rendered outputs will later be written. |
| `Name` | No | Diagram/project name used for manifest defaults. |
| `Title` | No | Diagram title. |
| `Subtitle` | No | Diagram subtitle. |
| `ObjectMode` | No | `Site` for MVP; future values may include `Domain` or `SiteAndDomain`. |
| `LinkExpansionMode` | No | `Pairwise` for MVP; future values may include `Hub`. |
| `PortProfile` | No | Port profile name or CSV path for generated port rows. |
| `Force` | No | Overwrite generated CSVs. |
| `PassThru` | No | Return summary object. |

Required behavior:

- Read raw exports using structured CSV import, not string parsing.
- Generate stable object IDs from site names.
- Generate stable line-of-sight IDs from unordered site pairs, not from row order.
- Preserve original AD names in notes or source columns where possible.
- Sort output deterministically by display order and source object name.
- Write `diagram-inputs.csv` if requested or if one does not exist.
- Write a transform summary JSON file with counts and warnings.
- Preserve full site-link contributor detail in `transform-summary.json` when multiple site links contribute to one diagram edge.

### 4.5 Diagram Input CSVs

The normalized output must remain compatible with the existing diagram model.

Required generated files:

```text
input/
  diagram-objects.csv
  line-of-sight-links.csv
  ports-protocols.csv
  ad-site-domain-controller-expansion.csv
  ad-site-subnets.csv
  replication-connections.csv
  replication-partner-metadata.csv
  replication-failures.csv
  replication-topology-edges.csv
  replication-health-summary.csv
```

For compatibility with the current renderer, MVP may also write:

```text
input/
  ad-domain-server-expansion.csv
```

This compatibility file should contain domain controller rows mapped to site objects until the renderer supports a generalized expansion table name.

### 4.6 Diagram Objects Mapping

Each AD site must become one row in `diagram-objects.csv`.

Required mapping:

| Diagram Column | Source |
| --- | --- |
| `ObjectId` | Stable ID generated from `SiteName`, such as `SITE001`. |
| `ObjectName` | `SiteName`. |
| `ObjectType` | `ADSite`. |
| `DisplayLabel` | `SiteName`, optionally prettified. |
| `Group` | Region or grouping rule, default `Active Directory Sites`. |
| `Location` | Site `Location` or blank. |
| `Environment` | Configurable default, usually `Production`. |
| `Zone` | Configurable default, optionally from naming rules. |
| `NetworkCidr` | Semicolon-separated assigned subnet CIDRs or blank if too long. |
| `Provider` | Configurable default, usually `On-Premises`. |
| `Role` | `AD replication site`. |
| `DisplayOrder` | Deterministic numeric order. |
| `Notes` | Site description, subnet count, DC count, and source DN summary. |

### 4.7 Line-Of-Sight Link Mapping

AD site links must become deduplicated diagram links. These links represent site-link-derived possible connectivity, not confirmed bridgehead selection or active replication connections.

MVP rule:

- Split `SitesIncluded` on `;`, trim values, and remove duplicate site names within each site link.
- If a site link contains fewer than two known sites, warn and skip it.
- For each site link, generate all unordered site pairs from its site list.
- Maintain a global pair map keyed by sorted site object IDs.
- Emit one line-of-sight row per unordered site pair, even when multiple site links contribute to that pair.
- Preserve every contributing site link name, transport, cost, replication frequency, and DN in `Notes` and `transform-summary.json`.
- Add one diagram-wide footnote stating that site-link-derived lines do not represent confirmed bridgehead selection or active replication connections.

Required mapping:

| Diagram Column | Source |
| --- | --- |
| `LineOfSightId` | Stable generated ID from sorted site IDs, such as `LOS-SITE001-SITE002`. |
| `SourceObjectId` | Generated object ID for source site. |
| `TargetObjectId` | Generated object ID for target site. |
| `Direction` | `Bidirectional`. |
| `Label` | Site link name when one contributor exists; otherwise `Multiple site links (<count>)`. |
| `Status` | `Discovered`. |
| `Notes` | Site link contributor names, transport, cost, frequency, schedule summary, bridge-all-site-links context, and bridge notes. |

### 4.8 Ports And Protocols Mapping

The tool must generate firewall review rows from a configurable port profile.

MVP default profile:

| Protocol | Port | Service | Purpose |
| --- | --- | --- | --- |
| TCP | 53 | DNS | DNS queries and large DNS responses where TCP is required. |
| UDP | 53 | DNS | Standard DNS queries. |
| TCP | 88 | Kerberos | Kerberos authentication. |
| UDP | 88 | Kerberos | Kerberos authentication. |
| UDP | 123 | NTP | Time synchronization required for Kerberos clock-skew tolerance. |
| TCP | 135 | RPC Endpoint Mapper | RPC endpoint discovery. |
| TCP | 389 | LDAP | Directory lookup and LDAP operations. |
| UDP | 389 | LDAP | LDAP locator and related operations where required. |
| TCP | 445 | SMB | SYSVOL, NETLOGON, and file-based domain services where required. |
| TCP | 464 | Kerberos Password Change | Kerberos password change. |
| UDP | 464 | Kerberos Password Change | Kerberos password change. |
| TCP | 636 | LDAPS | Secure LDAP where used. |
| TCP | 3268 | Global Catalog | Global Catalog LDAP. |
| TCP | 3269 | Global Catalog SSL | Secure Global Catalog LDAP. |
| TCP | 9389 | AD Web Services | ADWS access for AD PowerShell discovery and management tooling where required. |
| TCP | 49152-65535 | Dynamic RPC | Modern Windows dynamic RPC range, configurable. |

Requirements:

- The default profile must be clearly marked as a review starting point, not an assertion that every port is required in every environment.
- Users must be able to substitute a custom port profile CSV.
- Each port row must map to one `LineOfSightId`.
- Generated rows must use stable `RequirementId` values.
- Notes must mention that firewall teams should validate actual required scope.
- ADWS `TCP/9389` must also be documented as an execution-host prerequisite for the discovery script. It is not necessarily a site-to-site firewall requirement.

### 4.9 Expansion Tables

#### 4.9.1 AD Site Domain Controller Expansion

Each discovered domain controller must be represented in an expansion table.

Required columns:

- `ExpansionId`
- `SiteObjectId`
- `SiteName`
- `DomainName`
- `ServerName`
- `ServerRole`
- `Environment`
- `Location`
- `NetworkZone`
- `IpAddress`
- `IsGlobalCatalog`
- `IsReadOnly`
- `OperatingSystem`
- `InScope`
- `Status`
- `Notes`

Compatibility output to `ad-domain-server-expansion.csv` must map:

| Compatibility Column | Source |
| --- | --- |
| `DomainObjectId` | `SiteObjectId`. |
| `DomainName` | `SiteName` for site-mode diagrams. |
| `ServerName` | DC hostname. |
| `ServerRole` | `Domain Controller`, plus GC/RODC indicators in notes. |

#### 4.9.2 AD Site Subnet Table

Each discovered subnet must be represented in `ad-site-subnets.csv`.

Required columns:

- `SubnetId`
- `SiteObjectId`
- `SiteName`
- `SubnetName`
- `Cidr`
- `Location`
- `Description`
- `InScope`
- `Status`
- `Notes`

## 5. Validation Requirements

### 5.1 Discovery Validation

The setup or discovery script must validate:

- Active Directory module is installed.
- Current user or supplied credential can read required AD objects.
- Required raw datasets are non-empty unless explicitly allowed.
- Each site has a unique name.
- Each subnet has a parseable subnet name or CIDR-like value.
- Each site link references at least two known sites.
- Each domain controller maps to a known or clearly flagged unknown site.
- DNS resolution failures are warnings, not fatal errors, when `-ResolveDns` is used.
- `BridgeAllSiteLinks` state is captured for the IP transport or an explicit warning is emitted that transport bridge behavior was not collected.

### 5.2 Diagram CSV Validation

The setup script must validate:

- Required CSV files exist.
- Required headers are present.
- `ObjectId`, `LineOfSightId`, `RequirementId`, and expansion IDs are unique.
- Every link references known objects.
- Every port row references a known line-of-sight link.
- Every expansion row references a known site object.
- Multi-site site links expanded into pairwise links include the original site link name in notes.
- `line-of-sight-links.csv` contains no duplicate unordered `(SourceObjectId, TargetObjectId)` pair.
- Replication IDs are unique within their files.
- `replication-topology-edges.csv` uses only documented `EvidenceType` values.
- Configured connection evidence and observed partner metadata evidence remain distinguishable in CSV and rendered inventory.
- Generated CSVs can be re-read by PowerShell and Python without encoding errors.

### 5.3 Warning Conditions

The tool should warn, not fail, when:

- A site has no subnets.
- A subnet has no site assignment.
- A site has no discovered domain controllers. The warning must say this can be expected when automatic site coverage is in use.
- A site link has high cost or missing replication frequency.
- A site link uses a custom schedule that is summarized in CSV and preserved in full only in JSON.
- A domain controller has no resolved IP address.
- The generated diagram has more than the configured dense link threshold or more than the configured dense site threshold and will switch to dense rendering behavior.

## 6. Rendering Requirements

### 6.1 MVP Renderer Behavior

The renderer must:

- Produce a standalone SVG.
- Produce normalized inventory JSON.
- Show AD sites as nodes.
- Show AD site links as bidirectional line-of-sight arrows.
- Include a site link map table when the diagram is dense.
- Include a required ports/protocols table.
- Include a domain controller expansion table.
- Include a subnet table when `--subnets-csv` is provided.
- Include replication topology and health summary tables when replication CSVs are provided.
- Add a diagram-wide footnote stating that site-link-derived arrows show possible topology relationships, not confirmed KCC bridgehead selection or active replication connections.
- Add a replication caveat stating that health rows are read-only evidence, not remediation and not proof of network reachability.

### 6.2 Renderer Enhancements From Sample

The existing sample renderer is not sufficient for AD Sites topology because it uses a two-column source/target layout. AD sites can be both source and target across different links, which would render duplicate boxes for the same site. The AD Sites renderer must add a dedicated graph layout path instead of only relabeling the sample renderer.

Required renderer changes:

- Add a dedicated `render_site_topology_svg()` path selected by `--layout-mode ring` or by `ObjectType = ADSite`.
- Use deterministic ring placement for site nodes so each site appears once regardless of link direction.
- Keep the renderer dependency-free; do not add a force-directed layout dependency for MVP.
- Add optional CLI arguments `--subnets-csv`, `--layout-mode {bipartite,ring}`, `--dense-link-threshold`, and `--dense-site-threshold`.
- Trigger dense rendering based on link count and site count.
- Support configurable expansion table title.
- Support configurable expansion table column set or an AD Sites mode.
- Preserve dense-diagram behavior for large site-link counts.
- Add a subtitle or note indicating that site link arrows represent site-link-derived possible connectivity, not proven network reachability or active replication paths.

## 7. Configuration Requirements

### 7.1 Manifest

`diagram-inputs.csv` must continue to drive render paths.

Required settings:

- `Name`
- `Title`
- `Subtitle`
- `InputPath`
- `OutputPath`
- `ObjectsCsv`
- `LineOfSightLinksCsv`
- `PortsProtocolsCsv`
- `ExpansionCsv`
- `SubnetsCsv`
- `ReplicationConnectionsCsv`
- `ReplicationPartnerMetadataCsv`
- `ReplicationFailuresCsv`
- `ReplicationTopologyEdgesCsv`
- `ReplicationHealthSummaryCsv`
- `LayoutMode`
- `DenseLinkThreshold`
- `DenseSiteThreshold`
- `PythonCommand`

Backward compatibility setting:

- `AdDomainServerExpansionCsv`

### 7.2 Discovery Settings

`discovery-settings.csv` should support reusable defaults.

Required settings:

- `Server`
- `ForestName`
- `ObjectMode`
- `LinkExpansionMode`
- `EnvironmentDefault`
- `ProviderDefault`
- `ZoneDefault`
- `PortProfile`
- `CollectIpTransport`
- `FullInventory`
- `IncludeReplicationConnections`
- `IncludeReplicationMetadata`
- `ResolveDns`
- `IncludeSrvRecordSummary`
- `Anonymize`

## 8. Security Requirements

- Scripts must not write credentials to disk.
- `run-metadata.json` must record that alternate credentials were used without storing secrets. It may record `CredentialProvided: true` and the credential username, but must never log password or `SecureString` contents.
- `run-metadata.json` must record command parameters safely. If `-Anonymize` is set, echoed `Server` and `ForestName` values in metadata must be anonymized.
- `-Anonymize` must replace names and IPs consistently across all outputs, including raw CSVs, normalized CSVs, `raw-inventory.json`, `run-metadata.json`, and rendered inventory JSON.
- An anonymized run must write `anonymization-map.csv` separately. That map is the most sensitive artifact of an anonymized run and must be excluded from external handoff unless explicitly approved.
- Raw exports may contain sensitive infrastructure data; documentation must warn users to restrict ACLs on `OutputPath` and treat raw exports as security-sensitive reconnaissance data.
- Anonymized outputs must not be assumed safe for public sharing because topology shape, counts, and link costs may still reveal environment details.
- No script may modify AD objects.
- No script may transmit data to external services.

## 9. Reliability And Error Handling Requirements

- Scripts must use `Set-StrictMode -Version Latest`.
- Scripts must set `$ErrorActionPreference = "Stop"`.
- Required failures must throw clear terminating errors.
- Optional collection failures must emit warnings and write metadata.
- Output writes must be deterministic and repeatable.
- Re-running with the same raw inputs must produce stable IDs.
- `-Force` must be required to overwrite existing generated files.

## 10. Testing Requirements

### 10.1 Offline Tests

The repository must include mock raw AD export files that can be converted and rendered without AD access.

Acceptance tests:

- Convert mock raw exports to diagram CSVs.
- Render a throwaway 4-site/6-edge CSV using ring layout before the mock converter path is treated as valid.
- Run setup/preflight against generated CSVs.
- Render SVG and inventory JSON.
- Confirm all expected files exist.
- Confirm expected counts for sites, subnets, site links, deduplicated generated site pairs, DCs, port rows, replication topology rows, replication failures, and replication health summary rows.

### 10.2 PowerShell Tests

If Pester is available, tests should cover:

- Stable ID generation.
- Pairwise site-link expansion with duplicate unordered pair merging.
- Required header validation.
- Missing site reference handling.
- Custom port profile loading.
- `-Force` overwrite behavior.
- Anonymization consistency.
- Safe credential metadata logging.

### 10.3 Renderer Tests

Renderer tests should cover:

- Sparse diagram output.
- Dense diagram output.
- Ring-layout output with one rendered node per site.
- Long site names.
- Multi-row table wrapping.
- Empty optional fields.
- Optional `--subnets-csv` plumbing and subnets table output.
- Optional replication CSV plumbing and replication topology/health table output.
- Inventory JSON shape.

## 11. Example Dataset Requirements

The mock example must include:

- At least four AD sites.
- At least six subnets.
- At least three site links.
- At least one site link with more than two sites.
- At least one site with no domain controller to trigger a warning.
- At least one domain controller that is a global catalog.
- At least one RODC if practical.
- A generated SVG and inventory JSON committed as example output.
- Configured replication connection objects and observed replication partner metadata that clearly render as different evidence types.
- At least one replication failure and one queue/backlog indicator.

## 12. Acceptance Criteria

The MVP is complete when:

1. A user can run the mock example end-to-end without live AD access.
2. A user with RSAT/AD module access can run discovery against AD and produce raw exports.
3. Raw exports can be converted into diagram CSVs.
4. Generated CSVs pass preflight validation.
5. The renderer produces a standalone SVG and inventory JSON.
6. The SVG shows sites, site-link arrows, ports/protocols, and DC expansion data.
7. Replication CSVs distinguish configured connection objects from observed partner metadata and include stable replication edge IDs.
8. The runbook documents live and offline usage.
9. All scripts fail clearly on missing prerequisites or malformed inputs.
10. No script modifies AD.
11. A site with multiple links renders as one node, not as separate source and target boxes.
12. Duplicate/overlapping site-link coverage produces one diagram edge per unordered site pair.

## 13. Implementation Sequence

1. Scaffold the new toolkit folder from the high-level network diagram sample.
2. Build a ring-layout renderer spike from a throwaway 4-site/6-edge hand-written CSV. Exit criterion: one rendered box per site even when a site has three or more links.
3. Build a small live-discovery shape probe or lab export for `Get-ADReplicationSite`, `Get-ADReplicationSubnet`, `Get-ADReplicationSiteLink`, transport settings, and domain controller output.
4. Add mock raw exports under `04-examples/mock-forest-sites/raw`.
5. Build the converter from raw exports to diagram CSVs, including duplicate unordered pair merging.
6. Add setup/preflight checks for generated diagram CSVs.
7. Complete the AD Sites renderer table labels, ring layout, expansion schema, and subnet table support.
8. Build the read-only live AD discovery script.
9. Add default and custom port profile support.
10. Add runbook and data dictionary documentation.
11. Add offline tests using the mock dataset.
12. Validate a full render from mock data.

## 14. Open Technical Decisions

1. Whether the MVP renderer should show subnets in the SVG or keep subnets as supporting CSV/JSON only.
2. Whether multi-site site links should later render as hub/link objects instead of deduplicated pairwise lines.
3. Whether to infer regions/groups from naming conventions or keep grouping fully user-configurable.
4. Whether the default port profile should be minimal or broad.
5. Whether to include replication health data in the first live discovery script or keep it as a later optional module.
6. Whether to add PNG export after SVG rendering is stable.
