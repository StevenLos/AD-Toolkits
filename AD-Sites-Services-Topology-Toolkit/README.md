# AD Sites Services Topology Toolkit

This folder is the build target for the Active Directory Sites and Services topology discovery-to-diagram workflow.

The goal is to collect read-only AD Sites and Services inventory, optional replication health/topology evidence, normalize that inventory into diagram CSVs, and render tables and diagrams similar to the existing high-level network diagram sample.

## Intended Outcome

- Export AD forest, domain, site, subnet, site link, site link bridge, domain controller, and optional read-only replication evidence.
- Preserve raw discovery output for review and audit.
- Convert raw AD exports into diagram-ready CSV files.
- Render an SVG diagram and normalized JSON inventory from those CSV files.
- Support an offline mock example before live AD discovery is used.

## Working Documents

| File | Purpose |
| --- | --- |
| `00-docs/high-level-requirements.md` | High-level goals, users, and first MVP scope. |
| `00-docs/low-level-requirements.md` | Detailed requirements for discovery, normalization, validation, rendering, and testing. |
| `00-docs/RUNBOOK.md` | Planned user workflow for mock and live AD runs. |
| `00-docs/data-dictionary.md` | Planned field definitions for raw and normalized exports. |
| `01-discovery/Export-ADSitesAndServicesInventory.ps1` | Read-only AD discovery/export script. |
| `01-discovery/Convert-ADSitesAndServicesExportToDiagramCsv.ps1` | Raw collection JSON to diagram CSV converter. |
| `01-setup/Test-ADSitesAndServicesDiagramEnvironment.ps1` | Preflight validation script. |
| `02-render-from-csv/Render-ADSitesAndServicesDiagram.py` | AD Sites ring-layout SVG renderer. |
| `02-render-from-csv/New-ADSitesAndServicesDiagramFromCsv.ps1` | PowerShell render wrapper. |
| `03-templates/My-ADSS-Project-Template/` | Copy-ready project template shape. |
| `04-examples/mock-forest-sites/` | Offline mock dataset location. |
| `05-projects/` | User-owned project folders. |
| `06-tests/Invoke-ADSitesAndServicesMockSmokeTest.ps1` | Offline mock smoke test for convert, validate, and render. |

## Offline Quick Start

From this folder:

```powershell
.\06-tests\Invoke-ADSitesAndServicesMockSmokeTest.ps1
```

Or run the steps manually:

```powershell
.\01-discovery\Convert-ADSitesAndServicesExportToDiagramCsv.ps1 `
  -RawPath .\04-examples\mock-forest-sites\raw `
  -InputPath .\04-examples\mock-forest-sites\input `
  -OutputPath .\04-examples\mock-forest-sites\output `
  -Name mock-forest-sites `
  -Force

.\01-setup\Test-ADSitesAndServicesDiagramEnvironment.ps1 `
  -ConfigCsv .\04-examples\mock-forest-sites\diagram-inputs.csv

.\02-render-from-csv\New-ADSitesAndServicesDiagramFromCsv.ps1 `
  -ConfigCsv .\04-examples\mock-forest-sites\diagram-inputs.csv
```

## Current State

This folder now owns the AD Sites and Services discovery context. `Export-ADSitesAndServicesInventory.ps1` collects core read-only AD site, subnet, site-link, domain controller, optional SRV/DNS address data, and optional replication evidence into a `*.sites.collection.json` file.

The offline MVP path is implemented:

- Mock raw collection JSON.
- Converter to normalized diagram CSVs.
- Preflight validation.
- Ring-layout SVG renderer with inventory JSON output.
- Replication connection, partner metadata, failure, topology-edge, and health-summary CSVs.
- Smoke test for the mock workflow.

Still pending: anonymization, detailed IP transport bridge settings, PNG export, and live validation against a real AD forest.
