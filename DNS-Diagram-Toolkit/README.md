# DNS Diagram Toolkit

This project is a DNS mapping toolkit modeled after the `SAMPLE/AD-Trust-Diag` workflow.

It collects Windows DNS Server data, can merge optional AD Sites and Services collection files produced by the sibling AD toolkit, and renders current-state or future-state DNS diagrams.

## Design Principles

- Relationships over records: diagrams show DNS servers, zones, forwarders, delegations, optional AD site context, and external dependencies, not every individual host record.
- Read-only discovery: the DNS collector queries state only and must not modify DNS configuration.
- Collect now, merge later: each discovery run writes a self-contained collection JSON file that can be merged offline later.
- Stable edge IDs: every rendered relationship has a `DnsEdgeId` such as `D01` that maps back to `dns-relationship-details.csv`.
- One rendering pipeline: inventory-driven and CSV-driven renders use the same renderer and produce the same `combined` and `source` view types.

## Pattern From AD Trust Sample

The AD trust sample uses this lifecycle:

1. `01-discovery`: create one self-contained `*.collection.json` file per queried source.
2. `02-aggregation`: merge collection files into `output/01-merged-inventory/inventory.json` and review CSVs.
3. `03-render-from-discovery`: render `combined` and `source` SVG/PNG views from inventory.
4. `04-render-from-csv`: regenerate diagrams from an editable relationship CSV.
5. `05-templates`: keep metadata, planned-state, and CSV templates.

The DNS toolkit should preserve that shape and naming style, but focus diagrams on DNS network relationships and resolution paths rather than raw DNS record volume.

## Folder Order

Run the project in numbered order when building a current-state DNS map from discovery:

1. `01-discovery`: collect DNS Server data.
2. `02-aggregation`: merge collection JSON files into one normalized inventory.
3. `03-render-from-discovery`: render current-state diagrams from `inventory.json`.

Use `04-render-from-csv` when you already have a DNS relationship CSV, such as a manually edited future-state CSV.

If DNS diagrams should include AD site/subnet context, generate that collection from `../AD-Sites-Services-Topology-Toolkit` and place the resulting `*.sites.collection.json` file in `input/discovery-collections`.

## Folder Map

| Folder | Purpose |
| --- | --- |
| `00-docs` | Runbook, requirements, data dictionary, and sample-pattern notes. |
| `01-discovery` | PowerShell collector for DNS Server data. |
| `02-aggregation` | Offline merge process for collected JSON files. |
| `03-render-from-discovery` | Render selected diagrams from normalized inventory. |
| `04-render-from-csv` | Render selected diagrams from manually edited DNS relationship CSVs. |
| `05-templates` | CSV and metadata templates. |
| `input/discovery-collections` | Drop DNS `*.collection.json` files and optional external `*.sites.collection.json` files here. |
| `input/manual-csv` | Store manually edited current/future-state CSV files here. |
| `output` | Generated inventories, diagrams, and CSV outputs. |
| `examples` | Safe sample input/output files for testing. |

## Documentation

| File | Purpose |
| --- | --- |
| `00-docs/requirements.md` | Committed requirements for discovery, aggregation, rendering, and CSV round-trip. |
| `00-docs/high-level-design.md` | Architecture, design principles, artifacts, and scope boundaries. |
| `00-docs/low-level-design.md` | Per-script behavior, algorithms, validation rules, and implementation decisions. |
| `00-docs/RUNBOOK.md` | Operating workflow. |
| `00-docs/ad-trust-sample-pattern.md` | Notes on the AD trust sample pattern this toolkit follows. |
| `05-templates/dns-relationship-details.data-dictionary.md` | Relationship CSV schema and expected values. |

## Current-State Quick Start

The full current-state flow is implemented. Live DNS discovery must be run from a Windows host with the `DnsServer` PowerShell module available. Optional AD site/subnet enrichment comes from the separate `AD-Sites-Services-Topology-Toolkit` folder. The offline CSV render path can be tested anywhere PowerShell and Python are available.

Implemented offline render:

```powershell
.\04-render-from-csv\New-DnsMapImagesFromCsv.ps1 `
  -DnsRelationshipCsv .\examples\sample-dns-relationship-details.csv `
  -OutputPath .\examples\sample-output\from-wrapper `
  -Name sample-from-wrapper `
  -SkipPng
```

Implemented inventory render from the generated inventory:

```powershell
.\03-render-from-discovery\New-DnsMapImagesFromInventory.ps1 `
  -InventoryJson .\examples\sample-output\from-wrapper\sample-from-wrapper.inventory.json `
  -OutputPath .\examples\sample-output\from-inventory-wrapper `
  -Name current-state `
  -SkipPng
```

Implemented future-state CSV copy:

```powershell
.\04-render-from-csv\New-DnsMapFutureStateCsv.ps1 `
  -CurrentCsv .\examples\sample-output\from-wrapper\sample-from-wrapper.dns-relationship-details.csv `
  -OutputCsv .\input\manual-csv\future-state.dns-relationship-details.csv `
  -Force
```

Live-discovery commands:

```powershell
.\01-discovery\Export-DnsMapCollection.ps1 `
  -DnsServer dns01.contoso.com `
  -OutputPath .\input\discovery-collections

..\AD-Sites-Services-Topology-Toolkit\01-discovery\Export-ADSitesAndServicesInventory.ps1 `
  -OutputPath .\input\discovery-collections

.\02-aggregation\Merge-DnsMapCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory

.\03-render-from-discovery\New-DnsMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

## Main Outputs

Aggregation produces:

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

Rendering produces:

```text
output/02-current-state-images/
  current-state-combined.svg
  current-state-combined.png
  current-state-source.svg
  current-state-source.png
  current-state.dns-relationship-details.csv
```

The combined diagram uses edge labels such as `D01`; those map to the `DnsEdgeId` column in the CSV.

## Implementation Status

Implemented:

- CSV-driven render wrapper with schema validation.
- Dependency-light Python renderer for `combined` and `source` SVG views.
- CSV-to-minimal-inventory conversion.
- Inventory-driven render wrapper.
- Future-state CSV copy script.
- DNS Server live discovery collector.
- Collection aggregation into `output/01-merged-inventory`.
- Optional AD Sites and Services collection merge when a sibling-toolkit collection file is present.
- Safe sample relationship CSV and rendered sample outputs.

Not yet live-validated in this macOS workspace:

- DNS collector execution against a real Windows DNS server.
- Optional AD Sites collection merge with a real collection from `AD-Sites-Services-Topology-Toolkit`.
- PNG conversion testing on Windows with Chrome, Edge, or Chromium.

## Design Rule

Export detailed DNS data to JSON and CSV, but keep diagrams focused on network relationships and resolution paths. Diagrams should answer:

- Which DNS servers host which zones?
- Which AD sites do DNS servers belong to?
- Where do servers forward unresolved queries?
- Which conditional forwarders and delegated zones exist?
- Which authoritative name servers and external DNS dependencies matter?

## Scope Boundaries

The toolkit intentionally does not simulate true client-side resolver behavior, audit DNSSEC or DNS policy posture, or diagram every individual DNS record. Record details are captured for review, but diagrams stay focused on resolution-path relationships.
