# DNS Diagram Toolkit Requirements

## Goal

Build a DNS mapping toolkit that collects Windows DNS Server data, optionally merges AD Sites and Services context produced by the separate AD toolkit, and renders diagrams and CSV review tables.

## Design Principles

- Diagrams prioritize DNS relationships and resolution paths over individual DNS records.
- DNS discovery is read-only and must not call `Set-*`, `Remove-*`, or other mutating DNS cmdlets.
- Collection and aggregation are decoupled: each collector writes one self-contained JSON file, and aggregation runs later against a folder of files.
- Diagram edge IDs are stable for the same input set and map directly to `dns-relationship-details.csv`.
- The same renderer must support current-state inventory renders and future-state CSV renders.

## Discovery Requirements

### `Export-DnsMapCollection.ps1`

Requirements:

- Use PowerShell 5.1+ compatible syntax.
- Use the Windows `DnsServer` module where available.
- Export one self-contained `*.collection.json` file per queried DNS server.
- Use filename format `<dns-server>.<yyyyMMddTHHmmssZ>.collection.json`.
- Include collection metadata: collector computer, user, queried server, timestamps, PowerShell version, module availability/version, and collection status.

Capture:

- DNS server identity.
- Recursion enabled setting where available.
- DNS zones.
- Zone type.
- Reverse-zone flag.
- Replication scope where available.
- Directory partition where available.
- Dynamic update setting.
- Aging/scavenging settings where available.
- SOA records.
- NS records.
- Master servers for secondary and stub zones where available.
- Zone transfer settings.
- Forwarders.
- Forwarder order and root-hint fallback setting where available.
- Conditional forwarders.
- Root hints.
- Selected record summaries.

### Optional AD Sites And Services Input

AD Sites and Services discovery is owned by `../AD-Sites-Services-Topology-Toolkit`.

When DNS diagrams need site/subnet enrichment, place the AD toolkit's `<forest-or-domain>.<yyyyMMddTHHmmssZ>.sites.collection.json` output in `input/discovery-collections` before aggregation. DNS aggregation must treat that file as an optional external input and must not query Active Directory directly.

## Aggregation Requirements

Create `Merge-DnsMapCollections.ps1`.

It must read all discovery JSON files and generate:

```text
output/01-merged-inventory/
  inventory.json
  dns-relationship-details.csv
  dns-zones.csv
  dns-forwarders.csv
  dns-conditional-forwarders.csv
  dns-record-summary.csv
  current-state.mmd
```

The normalized inventory must include:

- `Metadata`
- `CollectionFiles`
- `DnsServers`
- `ADSites`
- `ADSubnets`
- `ADSiteLinks`
- `DomainControllers`
- `Zones`
- `Records`
- `Forwarders`
- `ConditionalForwarders`
- `Delegations`
- `NameServers`
- `RootHints`
- `DnsEdges`

Create stable edge IDs such as `D01`, `D02`, and `D03`. These IDs must appear in the combined diagram and map back to `dns-relationship-details.csv`.

When AD Sites and Services input is present, aggregation must resolve DNS server site context by:

1. Matching DNS server hostname to domain controller hostname when possible.
2. Falling back to IP-to-AD-subnet matching.
3. Marking site as `Ambiguous` when IPs map to multiple sites.
4. Marking site as `Unknown` when no match is found.

When AD Sites and Services input is absent, aggregation must keep DNS inventory valid and mark site/subnet context as `Unknown` or blank as appropriate.

Edge IDs must be assigned in a deterministic pass order:

1. `HostsZone`
2. `ForwardsTo`
3. `ConditionalForwarder`
4. `DelegatesTo`
5. `AuthoritativeNS`
6. `RootHint`

Within each pass, sort deterministically by relationship-specific fields such as `ZoneName`, `DnsServer`, `Source`, and `Target`.

## Relationship CSV Requirements

`dns-relationship-details.csv` must include at minimum:

- `DnsEdgeId`
- `Source`
- `SourceType`
- `Relationship`
- `Target`
- `TargetType`
- `ZoneName`
- `RecordType`
- `Direction`
- `SiteName`
- `SubnetName`
- `TargetSiteName`
- `TargetSubnetName`
- `DnsServer`
- `Order`
- `Priority`
- `Status`
- `SourceCollectionServer`
- `Notes`

CSV validation must fail with row and column detail when required columns are missing, edge IDs are duplicated, required fields are blank, or enum-like fields contain unsupported values.

## Rendering Requirements

Create `Convert-DnsMapInventoryToSvg.py` as a dependency-light Python renderer similar to the AD trust renderer.

Required views:

### `combined`

- High-level DNS topology.
- Group DNS servers by AD site when site data exists.
- Show hosted zones.
- Show conditional forwarders.
- Show standard forwarders.
- Show delegations.
- Show authoritative name servers.
- Show external DNS dependencies.
- Use edge IDs such as `D01` that map to the CSV.
- Avoid rendering every individual `A` or `CNAME` record.
- Use distinct styles or colors for `HostsZone`, `ForwardsTo`, `ConditionalForwarder`, `DelegatesTo`, `AuthoritativeNS`, and `RootHint`.
- Show a legend for relationship styles.
- Collapse visually noisy repeated `HostsZone` edges in the diagram when multiple DNS servers in the same site host the same AD-integrated zone, while preserving full per-server detail in CSV and JSON.

### `source`

- One lane per DNS server.
- Show zones hosted by that server.
- Show forwarders and conditional forwarders.
- Show site/subnet context when optional AD Sites and Services input is available.
- Show key DNS attributes in side detail cards.
- Render blank side-card values instead of failing when CSV-driven future-state input lacks inventory-only attributes.

## PowerShell Render Wrapper Requirements

Create `New-DnsMapImagesFromInventory.ps1`.

Requirements:

- Call the Python renderer for `combined` and `source` SVGs.
- Optionally convert SVG to PNG using Chrome, Edge, or Chromium.
- Follow the same output naming pattern as the AD trust sample:
  - `<Name>-combined.svg`
  - `<Name>-combined.png`
  - `<Name>-source.svg`
  - `<Name>-source.png`
  - `<Name>.dns-relationship-details.csv`

## CSV Rendering Requirements

Create `New-DnsMapImagesFromCsv.ps1`.

Requirements:

- Render diagrams from `dns-relationship-details.csv`.
- Write a normalized inventory JSON beside the rendered outputs.
- Preserve edge IDs so manually edited diagrams still map back to CSV rows.
- Reconstruct a minimal inventory from CSV alone for future-state rendering.

Create `New-DnsMapFutureStateCsv.ps1`.

Requirements:

- Copy the current-state CSV into:

```text
input/manual-csv/future-state.dns-relationship-details.csv
```

- Refuse to overwrite unless `-Force` is provided.

## Diagram Design Rule

Export detailed DNS data to JSON and CSV, but keep diagrams focused on network relationships and resolution paths.

The diagrams should answer:

- Which DNS servers host which zones?
- Which sites do those DNS servers belong to?
- Where do DNS servers forward queries?
- Which zones are delegated?
- What authoritative name servers exist?
- What external DNS dependencies exist?

The diagrams should not attempt to render every individual host record.
