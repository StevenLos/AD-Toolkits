# AD Sites Services Topology Toolkit Runbook

This runbook describes the implemented offline workflow and the live discovery entry point. Core live inventory export, conversion, preflight, rendering, and the mock smoke test are implemented.

## Planned Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+.
- Active Directory PowerShell module for live discovery.
- Python 3 for rendering.
- Read access to the target AD forest.
- Network reachability from the execution host to a target domain controller. AD PowerShell discovery commonly requires ADWS on `TCP/9389`; LDAP, DNS, Kerberos, and RPC access may also be required depending on the selected commands and target environment.

## Review Caveats

- AD site-link-derived arrows are topology documentation aids. They do not prove direct network reachability, active replication connections, or current bridgehead domain controller selection.
- Replication connection objects are configured topology. Replication partner metadata, failures, and queue rows are observed read-only evidence. Keep those evidence types separate during review.
- Replication health output is not remediation, does not change AD, and does not prove network reachability.
- A site without discovered domain controllers is not always a defect. Automatic site coverage can allow domain controllers in other sites to serve clients from an empty site.
- AD subnet assignments are administrator-maintained and may be stale or incomplete. Treat subnet tables as discovered configuration, not proof of actual client location.
- Multi-site site links are deduplicated into site pairs for MVP. Each rendered pair must preserve the original contributing site link names in the link map or notes.

## Output Handling

Raw exports contain domain controller names, site topology, subnet information, link costs, and optional replication data. Treat the `raw` and `output` folders as sensitive project artifacts.

For anonymized runs:

- Confirm `-Anonymize` applies to raw CSVs, raw JSON, normalized CSVs, metadata, and rendered inventory.
- Keep `anonymization-map.csv` internal. It re-identifies all anonymized values and should not be included in external handoff packages.
- Do not assume anonymized outputs are safe for broad sharing; topology shape and counts can still reveal useful infrastructure details.

## Offline Smoke Test

Run the full mock workflow without live AD access:

```powershell
.\06-tests\Invoke-ADSitesAndServicesMockSmokeTest.ps1
```

The smoke test regenerates normalized CSVs, validates them, renders the SVG and inventory JSON, and confirms expected counts.
It also verifies configured replication connections, observed partner metadata, replication failures, topology evidence, and health summary counts from the mock dataset.

## Manual Offline Workflow

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

Expected rendered outputs:

```text
04-examples/mock-forest-sites/output/mock-forest-sites.svg
04-examples/mock-forest-sites/output/mock-forest-sites.inventory.json
04-examples/mock-forest-sites/output/transform-summary.json
```

## Live AD Inventory Export

```powershell
.\01-discovery\Export-ADSitesAndServicesInventory.ps1 `
  -OutputPath .\05-projects\my-ad-sites-project\raw `
  -IncludeReplicationConnections `
  -IncludeReplicationMetadata `
  -ResolveDns `
  -IncludeSrvRecordSummary
```

Expected output:

```text
05-projects/my-ad-sites-project/raw/<forest-or-domain>.<yyyyMMddTHHmmssZ>.sites.collection.json
05-projects/my-ad-sites-project/raw/replication-connections.csv
05-projects/my-ad-sites-project/raw/replication-partner-metadata.csv
05-projects/my-ad-sites-project/raw/replication-failures.csv
05-projects/my-ad-sites-project/raw/replication-topology-edges.csv
05-projects/my-ad-sites-project/raw/replication-health-summary.csv
```

## Normalize And Render Workflow

```powershell
.\01-discovery\Convert-ADSitesAndServicesExportToDiagramCsv.ps1 `
  -RawPath .\05-projects\my-ad-sites-project\raw `
  -InputPath .\05-projects\my-ad-sites-project\input `
  -OutputPath .\05-projects\my-ad-sites-project\output `
  -Name my-ad-sites-project `
  -Force

.\01-setup\Test-ADSitesAndServicesDiagramEnvironment.ps1 `
  -ConfigCsv .\05-projects\my-ad-sites-project\diagram-inputs.csv

.\02-render-from-csv\New-ADSitesAndServicesDiagramFromCsv.ps1 `
  -ConfigCsv .\05-projects\my-ad-sites-project\diagram-inputs.csv
```

## Current State

Core live inventory export, optional read-only replication evidence collection, and the offline convert/validate/render path are implemented. Detailed IP transport inspection, anonymization, PNG export, and live validation against a real AD forest are not implemented yet.
