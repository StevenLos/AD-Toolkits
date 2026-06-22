# Examples

`sample-collection` contains a safe mock forest configuration collection that can be merged without AD connectivity.

Example:

```powershell
.\02-aggregation\Merge-ADForestConfigurationCollections.ps1 `
  -InputPath .\examples\sample-collection `
  -OutputPath .\examples\sample-output
```

