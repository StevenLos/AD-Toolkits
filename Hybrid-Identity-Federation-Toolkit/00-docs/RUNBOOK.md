# Hybrid Identity Federation Toolkit Runbook

## 1. Prepare Offline Exports

Prefer offline exports when server access is not available. Place exported JSON or CSV files in `input/discovery-collections`, or package them into a collection file:

```powershell
.\01-discovery\Export-HybridIdentityCollection.ps1 `
  -OfflineExportPath C:\HybridExports `
  -OutputPath .\input\discovery-collections `
  -NoLiveDiscovery
```

Supported offline-first paths:

- Drop a prior `*.hybrid.collection.json` or `*.collection.json` file into the input folder.
- Drop CSVs with the same names as the output CSVs, using templates from `05-templates`.
- Package JSON/CSV exports with `-OfflineExportPath`; the aggregator expands known packaged exports.

## 2. Optional Local Discovery

Run the collector locally on each role holder you can access:

```powershell
.\01-discovery\Export-HybridIdentityCollection.ps1 `
  -OutputPath .\input\discovery-collections
```

Useful collection hosts:

- Entra Connect / Azure AD Connect sync server.
- AD FS federation server.
- Web Application Proxy server.
- Pass-through Authentication agent server.

The collector is read-only. It uses locally available modules and services only. Missing modules are recorded as warnings or notes rather than treated as proof that a feature is absent.

## 3. Optional Cloud/API Discovery

Cloud collection is opt-in and separated from on-prem discovery:

```powershell
Connect-MgGraph -Scopes Organization.Read.All,Directory.Read.All

.\01-discovery\Export-HybridIdentityCollection.ps1 `
  -OutputPath .\input\discovery-collections `
  -IncludeCloud
```

The collector does not start interactive sign-in. It only reads an existing Microsoft Graph context and available modules.

## 4. Aggregate Collections

```powershell
.\02-aggregation\Merge-HybridIdentityCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Use `-Recurse` when collections are grouped into subfolders. Use `-NoRedaction` only in a controlled review workspace.

## 5. Review CSVs

Start with:

- `hybrid-identity-summary.csv` for high-level sync and federation mode.
- `sync-connectors.csv` and `sync-scope-summary.csv` for forest/domain/OU scope review.
- `sync-rules-summary.csv` for source anchor, join, and transform review.
- `federation-certificates.csv` and `hybrid-findings.csv` for expiration and risk triage.
- `hybrid-endpoints-ports.csv` for endpoint and firewall review data.

Endpoint rows are reference data only. Validate current requirements against Microsoft documentation and the actual environment.

## 6. Render Diagrams

```powershell
.\03-render-from-discovery\New-HybridIdentityTopologyImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

Use `-SkipPng` to generate only SVG files.

## 7. Verify Completeness

Before relying on the output:

- Confirm every expected sync server, AD FS node, WAP node, and PTA agent has collection evidence.
- Confirm whether the Entra Connect server is active or staging.
- Confirm source anchor attribute and immutable ID behavior against the tenant.
- Confirm certificate expiration and rollover state directly on AD FS.
- Confirm cloud-side PTA and sync health through Microsoft Entra admin center or a separate cloud export.

