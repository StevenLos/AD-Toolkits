# Runbook

## 1. Collect

Run from a Windows host with RSAT or the ActiveDirectory module:

```powershell
.\01-discovery\Export-ADForestConfigurationCollection.ps1 `
  -OutputPath .\input\discovery-collections
```

Optional parameters:

```powershell
.\01-discovery\Export-ADForestConfigurationCollection.ps1 `
  -Server dc01.contoso.com `
  -ForestName contoso.com `
  -Credential (Get-Credential) `
  -OutputPath .\input\discovery-collections
```

## 2. Merge

```powershell
.\02-aggregation\Merge-ADForestConfigurationCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Review these files first:

- `forest-summary.csv`
- `domain-summary.csv`
- `schema-summary.csv`
- `naming-contexts.csv`
- `application-partitions.csv`
- `optional-features.csv`
- `forest-config-findings.csv`

## 3. Render

```powershell
.\03-render-from-discovery\New-ADForestConfigurationDiagramsFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

Use `-SkipPng` when only SVG output is needed.

## 4. CSV-Driven Diagram Edits

Copy or edit `forest-config-relationships.csv`, then render:

```powershell
.\04-render-from-csv\New-ADForestConfigurationDiagramsFromCsv.ps1 `
  -RelationshipCsv .\input\manual-csv\forest-config-relationships.csv `
  -OutputPath .\output\03-csv-generated-images `
  -Name proposed-state `
  -SkipPng
```

## Safety Notes

- Do not run discovery with elevated write intent. Standard read access is preferred.
- The toolkit does not enable optional features, create partitions, modify UPN suffixes, or write schema changes.
- Trust discovery is not part of this toolkit.

