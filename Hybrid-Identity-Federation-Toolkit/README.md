# Hybrid Identity Federation Toolkit

This toolkit discovers and normalizes hybrid identity and federation configuration for review. It follows the same pattern as the sibling toolkits:

1. `01-discovery`: create one self-contained `*.collection.json` file from offline exports or local read-only discovery.
2. `02-aggregation`: merge collection files and manual CSV exports into `inventory.json` plus review CSVs.
3. `03-render-from-discovery`: render topology SVG/PNG diagrams from `inventory.json`.

The design is offline-first. You can drop sanitized JSON/CSV exports into `input/discovery-collections`, or run the collector with `-OfflineExportPath` to package exports before aggregation. Live discovery is optional and local to the server where the required role modules exist.

## Scope

Covered areas:

- Microsoft Entra Connect / Azure AD Connect server and connector topology when locally discoverable.
- Sync mode: password hash sync, pass-through authentication, federation evidence, and staging mode.
- Connector spaces, joined forests/domains, OU filtering summary, and sync rule summary.
- Source anchor and immutable ID attribute configuration.
- Writeback features: password, group, device, and Exchange hybrid evidence where visible.
- AD FS farm, WAP/proxy evidence, relying party trusts, claim rule summaries, and certificate expiration.
- PTA agent local service evidence and cloud-side health placeholders when readable.
- Required endpoints and ports as review data, not reachability proof.

Cloud/API collection is optional and explicitly separated under the `Cloud` section of collection JSON. The collector does not initiate cloud sign-in.

## Current-State Quick Start

Package offline exports without live discovery:

```powershell
.\01-discovery\Export-HybridIdentityCollection.ps1 `
  -OfflineExportPath C:\HybridExports `
  -OutputPath .\input\discovery-collections `
  -NoLiveDiscovery
```

Run local read-only discovery on an Entra Connect, AD FS, WAP, or PTA server:

```powershell
.\01-discovery\Export-HybridIdentityCollection.ps1 `
  -OutputPath .\input\discovery-collections
```

Merge offline collections:

```powershell
.\02-aggregation\Merge-HybridIdentityCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Render topology diagrams:

```powershell
.\03-render-from-discovery\New-HybridIdentityTopologyImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

If a browser renderer is unavailable, pass `-SkipPng` and use the generated SVG files.

## Main Outputs

Aggregation writes:

```text
output/01-merged-inventory/
  inventory.json
  hybrid-identity-summary.csv
  sync-connectors.csv
  sync-scope-summary.csv
  sync-rules-summary.csv
  federation-adfs-farm.csv
  federation-relying-parties.csv
  federation-certificates.csv
  hybrid-findings.csv
  hybrid-endpoints-ports.csv
  topology-relationships.csv
```

Rendering writes:

```text
output/02-current-state-images/
  current-state-combined.svg
  current-state-combined.png
  current-state-federation.svg
  current-state-federation.png
  current-state.topology-relationships.csv
```

The combined and federation diagrams use edge labels such as `HI01`; those map back to `HybridEdgeId` in `topology-relationships.csv`.

## Safety Defaults

- No secrets are intentionally collected.
- Credentials, client secrets, private keys, raw certificate material, access tokens, refresh tokens, immutable ID values, thumbprints, GUID identifiers, and similar sensitive values are redacted by default.
- Use `-NoRedaction` only in a controlled workspace when exact identifiers are required for analysis.
- Required endpoints and ports are reference data for review. They are not tested and must not be treated as reachability proof.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 for collectors and wrappers.
- Python 3 for SVG rendering.
- Microsoft Edge, Chrome, or Chromium for optional PNG export.
- `ADSync` module on an Entra Connect server for live sync discovery.
- `ADFS` module on a federation server for live AD FS discovery.
- `WebApplicationProxy` module on a WAP server for live proxy discovery.
- Optional Microsoft Graph PowerShell modules and an existing signed-in context for `-IncludeCloud`.

## Documentation

| File | Purpose |
| --- | --- |
| `00-docs/RUNBOOK.md` | Operator workflow for offline, live local, optional cloud, aggregation, and rendering. |
| `00-docs/data-dictionary.md` | Output CSV schemas and field meanings. |
| `05-templates` | Header templates for manual offline CSV exports. |

