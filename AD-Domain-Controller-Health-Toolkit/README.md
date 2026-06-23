# AD Domain Controller Health Toolkit

This toolkit collects read-only Active Directory domain controller health and role-readiness evidence, merges it into review CSVs, and renders SVG/PNG diagrams for migration, decommission, and FSMO role-transfer planning.

It follows the sibling `DNS-Diagram-Toolkit` and `Time-Server-Toolkit` workflow:

1. `01-discovery`: collect one self-contained `*.dc-health.collection.json` file plus a human-readable `*.dc-health.summary.csv`.
2. `02-aggregation`: merge collection files into `inventory.json` plus review CSVs.
3. `03-render-from-discovery`: render current-state SVG/PNG diagrams from inventory.
4. `04-render-from-csv`: render diagrams from an editable relationship CSV.
5. `05-templates`: keep reusable metadata and relationship CSV templates.

## Design Principles

- Read-only discovery: no AD, DNS, service, share, replication, or time configuration is modified.
- Evidence over opinion: readiness flags are generated from explicit service, share, port, locator, FSMO, and optional time-toolkit evidence.
- Stable IDs: domain controllers, findings, checks, FSMO roles, and diagram relationships get deterministic IDs such as `DC001`, `FIND001`, and `DCH001`.
- Time-source reuse: time fields are consumed from `Time-Server-Toolkit` output when present; this project does not duplicate full `W32Time` discovery.

## Current-State Quick Start

Run live discovery from a Windows host with the Active Directory PowerShell module:

```powershell
.\01-discovery\Export-ADDomainControllerHealthCollection.ps1 `
  -Server dc01.contoso.com `
  -OutputPath .\input\discovery-collections
```

Discovery writes both:

```text
input/discovery-collections/
  <scope>.<timestamp>.dc-health.collection.json
  <scope>.<timestamp>.dc-health.summary.csv
```

Merge collections. If `..\Time-Server-Toolkit\output\01-merged-inventory\inventory.json` exists, it is consumed automatically:

```powershell
.\02-aggregation\Merge-ADDomainControllerHealthCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Render diagrams:

```powershell
.\03-render-from-discovery\New-ADDomainControllerHealthMapImagesFromInventory.ps1 `
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
  dc-health-summary.csv
  dc-role-readiness.csv
  fsmo-roles.csv
  dc-services.csv
  dc-shares.csv
  dc-port-checks.csv
  dc-locator-records.csv
  dc-findings.csv
  dc-health-relationship-details.csv
```

Rendering writes:

```text
output/02-current-state-images/
  current-state-combined.svg
  current-state-combined.png
  current-state-source.svg
  current-state-source.png
  current-state.dc-health-relationship-details.csv
```

## Mock Example

The mock forest can be processed without touching Active Directory:

```powershell
.\02-aggregation\Merge-ADDomainControllerHealthCollections.ps1 `
  -InputPath .\examples\mock-forest\raw `
  -OutputPath .\examples\sample-output\merged `
  -TimeInventoryJson .\examples\mock-forest\mock-time-inventory.json

.\03-render-from-discovery\New-ADDomainControllerHealthMapImagesFromInventory.ps1 `
  -InventoryJson .\examples\sample-output\merged\inventory.json `
  -OutputPath .\examples\sample-output\from-inventory-wrapper `
  -Name sample `
  -SkipPng
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 for wrappers.
- Active Directory PowerShell module for live discovery.
- Network visibility from the collector to DC LDAP/LDAPS/GC ports for port checks.
- Python 3 for SVG rendering.
- Microsoft Edge, Chrome, or Chromium for PNG export. SVG output does not require a browser.

## Scope Boundaries

The toolkit does not run `dcdiag`, force DNS registration, restart services, query replication metadata, transfer FSMO roles, demote DCs, or change time configuration. Generated readiness rows are planning evidence, not approval to execute production changes without operator review.
