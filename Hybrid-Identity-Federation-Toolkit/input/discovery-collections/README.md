# Discovery Collections

Place offline exports here before aggregation.

Accepted inputs:

- `*.hybrid.collection.json` or `*.collection.json` files from `01-discovery`.
- JSON files shaped like `05-templates/offline-export-manifest.template.json`.
- CSVs copied from `05-templates` and renamed to the output filename, such as `sync-connectors.csv`.

Run aggregation from the toolkit root:

```powershell
.\02-aggregation\Merge-HybridIdentityCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

