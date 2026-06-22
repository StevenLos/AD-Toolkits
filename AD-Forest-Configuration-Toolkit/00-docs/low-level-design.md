# Low-Level Design

## `01-discovery/Export-ADForestConfigurationCollection.ps1`

The collector uses the ActiveDirectory PowerShell module and read-only cmdlets:

- `Get-ADRootDSE`
- `Get-ADForest`
- `Get-ADDomain`
- `Get-ADObject`
- `Get-ADOptionalFeature`
- `Get-ADReplicationSite`
- `Get-ADDomainController`

It writes one self-contained JSON file named:

```text
<forest-name>.<yyyyMMddTHHmmssZ>.forest-config.collection.json
```

The collector catches non-critical attribute or object read failures and writes them to `CollectionWarnings`.

## `02-aggregation/Merge-ADForestConfigurationCollections.ps1`

The merger reads collection JSON files, deduplicates normalized rows, creates findings, and writes:

- Inventory JSON
- Review CSVs
- Relationship CSV
- Mermaid `current-state.mmd`

It does not require AD connectivity.

## `03-render-from-discovery`

`New-ADForestConfigurationDiagramsFromInventory.ps1` validates inventory JSON, calls the Python renderer, and optionally exports PNG files through a headless browser.

The renderer creates:

- `combined` view: forest, domains, FSMO owners, naming contexts, schema, and optional features.
- `partitions` view: naming/application partitions and replica locations.

## `04-render-from-csv`

`New-ADForestConfigurationDiagramsFromCsv.ps1` validates an editable relationship CSV and uses the same Python renderer as the inventory workflow.

## Relationship CSV

Relationship rows use stable IDs such as `F001`. Supported relationship values are:

- `ContainsDomain`
- `HasNamingContext`
- `HasApplicationPartition`
- `HasDnsApplicationPartition`
- `ReplicatedTo`
- `SchemaMaster`
- `DomainNamingMaster`
- `EnabledOptionalFeature`
- `ConfiguredSuffix`

