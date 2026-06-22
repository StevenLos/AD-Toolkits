# Time Server Toolkit

This toolkit collects Windows Time (`W32Time`) configuration from servers, normalizes the results into an inventory, and renders diagrams that show where each server gets time from.

It is modeled after the repository's DNS mapping workflow:

1. `01-discovery`: collect one self-contained `*.collection.json` file per queried server.
2. `02-aggregation`: merge collection files into `inventory.json` plus review CSVs.
3. `03-render-from-discovery`: render current-state SVG/PNG diagrams from `inventory.json`.

## Questions Answered

- Is this server acting as a time server?
- What source of time does this server use?
- Is the source local clock, domain hierarchy, a manual NTP peer, a hypervisor provider, or unknown?
- Which servers have risky or ambiguous time-source evidence?

## Time Server Classification

The collector uses evidence rather than a single flag. `IsTimeServer` is true when W32Time is running and one or more of these indicators is present:

- `TimeProviders\NtpServer\Enabled` is enabled.
- UDP port `123` appears to be listening locally.
- The server is a domain controller, which commonly serves domain time through the Windows Time hierarchy.

The raw evidence is captured in JSON and CSV so review can override the classification when needed.

## Current-State Quick Start

Collect one or more servers:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -Server DC01,DC02,APP01 `
  -OutputPath .\input\discovery-collections
```

Collect from a text file with one server name per line:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -ServerListPath .\servers.txt `
  -OutputPath .\input\discovery-collections
```

Merge collections:

```powershell
.\02-aggregation\Merge-TimeServerCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Render diagrams:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
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
  time-relationship-details.csv
  time-server-summary.csv
```

Rendering writes:

```text
output/02-current-state-images/
  current-state-combined.svg
  current-state-combined.png
  current-state-source.svg
  current-state-source.png
  current-state.time-relationship-details.csv
```

The combined diagram uses edge labels such as `T01`; those map back to `TimeEdgeId` in the relationship CSV.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 for local rendering wrappers.
- Windows Time service (`W32Time`) present on queried Windows systems.
- WinRM enabled for full remote collection. Without WinRM, use `-NoWinRM` to collect a reduced `w32tm /computer:<server>` data set.
- Python 3 for SVG rendering.
- Microsoft Edge, Chrome, or Chromium for PNG export. SVG output does not require a browser.

