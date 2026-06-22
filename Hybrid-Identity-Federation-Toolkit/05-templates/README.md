# Offline CSV Templates

Use these templates when live discovery is unavailable or when review data comes from screenshots, exported reports, or hand-curated evidence.

Copy the needed template into `input/discovery-collections`, remove `.template` from the name, populate rows, then run:

```powershell
.\02-aggregation\Merge-HybridIdentityCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

CSV files with the same names as the normal outputs are imported and carried into `inventory.json`.
