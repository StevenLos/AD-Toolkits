# DNS Diagram Toolkit Low-Level Design

This document translates the DNS toolkit requirements into implementation-level behavior for each script.

## 1. Naming Conventions

| Item | Pattern |
| --- | --- |
| DNS collection file | `<dns-server>.<yyyyMMddTHHmmssZ>.collection.json` |
| Optional AD Sites collection file | `<forest-or-domain>.<yyyyMMddTHHmmssZ>.sites.collection.json` produced by `../AD-Sites-Services-Topology-Toolkit` |
| Edge ID | `D01`, `D02`, `D03` with zero padding sized for the edge count. |
| Current render outputs | `<Name>-combined.svg`, `<Name>-combined.png`, `<Name>-source.svg`, `<Name>-source.png`, `<Name>.dns-relationship-details.csv` |
| CSV render outputs | `<Name>.combined.svg`, `<Name>.combined.png`, `<Name>.source.svg`, `<Name>.source.png`, `<Name>.dns-relationship-details.csv`, `<Name>.inventory.json` |

## 2. DNS Collection Script

`01-discovery/Export-DnsMapCollection.ps1` should collect one DNS server and write one JSON bundle.

Required top-level JSON sections:

- `Metadata`
- `DnsServerIdentity`
- `Forwarders`
- `ConditionalForwarders`
- `RootHints`
- `Zones`
- `RecordSummary`

Required `Metadata` fields:

- `CollectorComputer`
- `CollectorUser`
- `QueriedServer`
- `TimestampUtc`
- `PowerShellVersion`
- `DnsServerModuleVersion`
- `CollectionStatus`

Important collection details:

- Use `Get-DnsServer*` cmdlets only.
- Capture `RecursionEnabled` and root-hint fallback where available.
- Capture `ZoneType`, `ReplicationScope`, `DirectoryPartition`, `DynamicUpdate`, reverse-zone status, aging/scavenging, SOA, NS, zone transfer settings, and master servers for secondary/stub zones.
- Capture selected record summaries as counts and samples rather than full record dumps unless explicitly requested.

## 3. Optional AD Sites Collection Input

AD Sites and Services discovery is outside this DNS toolkit. When DNS diagrams need site/subnet enrichment, use `../AD-Sites-Services-Topology-Toolkit/01-discovery/Export-ADSitesAndServicesInventory.ps1` and place the resulting sites collection JSON in `input/discovery-collections`.

Recognized top-level JSON sections:

- `Metadata`
- `ADSites`
- `ADSubnets`
- `ADSiteLinks`
- `DomainControllers`
- `SrvRecordSummary`

DNS aggregation must consume this file only as an offline input. It must not call the `ActiveDirectory` module or perform live AD queries.

## 4. Aggregation Algorithm

`02-aggregation/Merge-DnsMapCollections.ps1` should:

1. Enumerate `*.collection.json` and `*.sites.collection.json` below `InputPath`.
2. Parse JSON files and validate required metadata.
3. Skip malformed files with warnings instead of aborting the whole merge.
4. Keep the latest collection per DNS server when duplicates exist.
5. Build normalized `DnsServers` and, when optional AD input exists, `ADSites`, `ADSubnets`, `ADSiteLinks`, and `DomainControllers`.
6. Enrich each DNS server with site/subnet context when optional AD input exists:
   - Match hostname to domain controller hostname first.
   - If no DC match, match DNS server IPs to AD subnet CIDRs.
   - If multiple site matches exist, set `SiteName = Ambiguous` and capture candidates in `Notes`.
   - If no match exists, set `SiteName = Unknown`.
7. Flatten zones, forwarders, conditional forwarders, delegations, name servers, root hints, and record summaries.
8. Generate `DnsEdges` in deterministic pass order:
   - `HostsZone`
   - `ForwardsTo`
   - `ConditionalForwarder`
   - `DelegatesTo`
   - `AuthoritativeNS`
   - `RootHint`
9. Assign `DnsEdgeId` values after sorting each pass deterministically.
10. Write `inventory.json`, review CSVs, and `current-state.mmd`.

Aggregation should keep full per-server detail. Visual collapsing belongs in the renderer so CSV and JSON remain complete.

## 5. Renderer Behavior

`03-render-from-discovery/Convert-DnsMapInventoryToSvg.py` should be dependency-light and support:

- `--inventory`
- `--dns-csv`
- `--view combined|source`
- `--details-csv`
- `--inventory-output`

### Combined View

- Cluster DNS servers by `SiteName`.
- Place `Unknown` and `Ambiguous` site servers in clearly labeled fallback groups.
- Use one node per collected DNS server.
- Use one node per distinct external target or authoritative name server not collected as a DNS server.
- Use distinct visual styles and a legend for `HostsZone`, `ForwardsTo`, `ConditionalForwarder`, `DelegatesTo`, `AuthoritativeNS`, and `RootHint`.
- Show `DnsEdgeId` labels.
- Collapse visually repeated same-site AD-integrated zone hosting edges while preserving full details in CSV and JSON.

### Source View

- Render one lane per DNS server, ordered by site then hostname.
- Show hosted zones, forwarders, conditional forwarders, AD site/subnet context, and detail cards.
- Leave unavailable inventory-only attributes blank in CSV-driven future-state mode.

## 6. CSV-Driven Render Validation

`04-render-from-csv/New-DnsMapImagesFromCsv.ps1` must validate before rendering:

- All columns in `dns-relationship-details.data-dictionary.md` are present.
- `DnsEdgeId` values are unique and non-blank.
- `Source`, `SourceType`, `Relationship`, `Target`, and `TargetType` are non-blank.
- `SourceType` and `TargetType` use documented values.
- `Relationship` uses documented values.
- Failures include row number and column name.

## 7. Open Implementation Decisions

These are intentionally tracked but no longer block the scaffold:

- How much record sampling to include by default.
- How aggressively the combined view should collapse repeated same-site zone hosting edges.
- Whether future-state CSVs should support adding full server/zone attribute rows, or only relationship rows.
- How much redaction/anonymization support belongs in v1.
