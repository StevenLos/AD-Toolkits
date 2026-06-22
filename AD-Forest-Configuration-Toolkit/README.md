# AD Forest Configuration Toolkit

This toolkit collects and normalizes Active Directory forest configuration data for migration, compatibility, and planning reviews.

It follows the same workflow used by the DNS and Time Server toolkits:

1. `01-discovery`: collect one self-contained `*.forest-config.collection.json` file from a Windows host with AD read access.
2. `02-aggregation`: merge collection files into `inventory.json` plus review CSVs.
3. `03-render-from-discovery`: render simple forest configuration relationship diagrams from `inventory.json`.
4. `04-render-from-csv`: render diagrams from an editable relationship CSV.
5. `05-templates`: keep reusable metadata and CSV templates.

## Scope

The collector is read-only. It queries forest, domain, schema, naming context, partition, optional feature, tombstone/deleted-object, UPN suffix, and light sites/global-catalog context.

Trusts are intentionally out of scope and are not queried or rendered by this toolkit.

## Folder Map

| Folder | Purpose |
| --- | --- |
| `00-docs` | Requirements, design notes, runbook, and data dictionary. |
| `01-discovery` | Read-only PowerShell collector for AD forest configuration. |
| `02-aggregation` | Offline merge process for collection JSON files. |
| `03-render-from-discovery` | SVG/PNG diagram rendering from normalized inventory. |
| `04-render-from-csv` | SVG/PNG diagram rendering from editable relationship CSVs. |
| `05-templates` | CSV and metadata templates. |
| `input/discovery-collections` | Drop collected `*.forest-config.collection.json` files here. |
| `input/manual-csv` | Store manually edited relationship CSVs here. |
| `output` | Generated inventories, CSVs, and diagrams. |
| `examples` | Safe sample input/output files for local testing. |

## Current-State Quick Start

Run discovery from a Windows host with the ActiveDirectory PowerShell module:

```powershell
.\01-discovery\Export-ADForestConfigurationCollection.ps1 `
  -OutputPath .\input\discovery-collections
```

Merge collected files:

```powershell
.\02-aggregation\Merge-ADForestConfigurationCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Render diagrams:

```powershell
.\03-render-from-discovery\New-ADForestConfigurationDiagramsFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

If browser-based PNG export is unavailable, pass `-SkipPng` and use the generated SVG files.

## Main Outputs

Aggregation writes:

```text
output/01-merged-inventory/
  inventory.json
  forest-summary.csv
  domain-summary.csv
  schema-summary.csv
  naming-contexts.csv
  application-partitions.csv
  optional-features.csv
  forest-config-findings.csv
  forest-config-relationships.csv
  current-state.mmd
```

Rendering writes:

```text
output/02-current-state-images/
  current-state-combined.svg
  current-state-combined.png
  current-state-partitions.svg
  current-state-partitions.png
  current-state.forest-config-relationships.csv
```

The diagrams use edge IDs such as `F001`; those map back to `ForestConfigEdgeId` in `forest-config-relationships.csv`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 for PowerShell scripts.
- ActiveDirectory PowerShell module for live discovery.
- Read-only AD permissions sufficient to read forest, configuration, schema, partition, optional feature, and domain root attributes.
- Python 3 for SVG rendering.
- Microsoft Edge, Chrome, or Chromium for PNG export. SVG output does not require a browser.

