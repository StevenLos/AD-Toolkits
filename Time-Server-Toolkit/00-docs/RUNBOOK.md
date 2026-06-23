# Time Server Toolkit Runbook

This runbook describes the operating process for Windows Time discovery, aggregation, review, and diagram generation.

The tool is read-only. It collects `W32Time`, registry, service, network listener, and `w32tm` evidence so reviewers can answer:

- Is a server acting as a time server?
- What source of time does this server use?
- Which time-source relationships or evidence need follow-up?

## Operating Notes

- Run live collection from a Windows host with PowerShell access to the servers in scope.
- Full remote collection uses WinRM. Use `-NoWinRM` only when reduced `w32tm /computer:<server>` collection is acceptable.
- PNG generation requires Microsoft Edge, Chrome, or Chromium. SVG generation works without a browser.
- Raw collection JSON can contain sensitive infrastructure detail. Do not share it externally unless approved.

## Offline Sample Render

From the `Time-Server-Toolkit` folder, render the sample inventory without live server access:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
  -InventoryJson .\examples\sample-output\sample.inventory.json `
  -OutputPath .\examples\sample-output `
  -Name sample `
  -SkipPng
```

Expected output:

```text
examples/sample-output/sample-combined.svg
examples/sample-output/sample-source.svg
examples/sample-output/sample.time-relationship-details.csv
```

Use this step to confirm Python and the rendering wrapper are working before live discovery.

## 1. Define Collection Scope

Start with a small lab or pilot list before scanning a broad environment.

At minimum, run collection against all domain controllers in each AD domain. Domain controllers are the core Windows Time distribution layer, and the PDC emulator is usually the authoritative source for the domain hierarchy.

Where appropriate, add representative member servers. Good candidates include critical application servers, servers with manual NTP configuration, virtual machines where hypervisor time sync may matter, and any server suspected of serving time.

Recommended first targets:

- PDC emulator.
- All other domain controllers.
- One normal domain-joined member server.
- One virtual machine where hypervisor time sync is known to be enabled.
- One server expected not to serve time.

Create a `servers.txt` file with one server name per line:

```text
PDC01.contoso.com
DC02.contoso.com
APP01.contoso.com
SQL01.contoso.com
```

Blank lines and lines beginning with `#` are ignored.

## 2. Prepare Collector Host

On the collector host, verify the basics:

```powershell
$PSVersionTable.PSVersion
Get-Command w32tm
Test-Path .\01-discovery\Export-TimeServerCollection.ps1
```

For full remote collection, test WinRM to a target:

```powershell
Test-WSMan PDC01.contoso.com
Invoke-Command -ComputerName PDC01.contoso.com -ScriptBlock { hostname }
```

If WinRM is unavailable, verify reduced `w32tm` collection:

```powershell
w32tm /query /computer:PDC01.contoso.com /source
w32tm /query /computer:PDC01.contoso.com /status /verbose
```

## 3. Collect Time Server Data

From the `Time-Server-Toolkit` folder, run the collector against a server list:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -ServerListPath .\servers.txt `
  -OutputPath .\input\discovery-collections
```

Or pass servers directly:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -Server PDC01.contoso.com,DC02.contoso.com,APP01.contoso.com `
  -OutputPath .\input\discovery-collections
```

Use explicit credentials when needed:

```powershell
$cred = Get-Credential
.\01-discovery\Export-TimeServerCollection.ps1 `
  -ServerListPath .\servers.txt `
  -Credential $cred `
  -OutputPath .\input\discovery-collections
```

Use reduced remote collection when WinRM is unavailable:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -ServerListPath .\servers.txt `
  -NoWinRM `
  -OutputPath .\input\discovery-collections
```

Expected output:

```text
input/discovery-collections/<server>.<yyyyMMddTHHmmssZ>.collection.json
```

Review the command output for `Status`, `IsTimeServer`, `Source`, `SourceType`, warning count, and error count.

## 4. Merge Collections

Merge all collection files into normalized inventory and CSV review files:

```powershell
.\02-aggregation\Merge-TimeServerCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Expected output:

```text
output/01-merged-inventory/
  inventory.json
  time-relationship-details.csv
  time-server-summary.csv
```

Use `-Recurse` if collection files are stored in subfolders:

```powershell
.\02-aggregation\Merge-TimeServerCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory `
  -Recurse
```

## 5. Review CSV Outputs

Start with `time-server-summary.csv`.

Review these columns first:

- `ServerName`
- `IsTimeServer`
- `Source`
- `SourceType`
- `W32TimeType`
- `NtpServerEnabled`
- `Udp123Listening`
- `ServiceStatus`
- `Stratum`
- `LastSuccessfulSyncTime`
- `Evidence`

Then review `time-relationship-details.csv`.

Use `TimeEdgeId` to map CSV rows to diagram edges. Relationship values include:

- `SyncsFrom`: active source relationship.
- `ConfiguredPeer`: configured manual peer that is not the active source edge.
- `UsesLocalClock`: local clock or free-running source.
- `UsesHypervisor`: hypervisor time provider.
- `UnknownSource`: missing or unclear source.

Review or escalate these patterns:

- PDC emulator using `LocalClock` unexpectedly.
- Domain controller using `Hypervisor`.
- Member server with `IsTimeServer=true` unexpectedly.
- `ServiceStatus` is not `Running`.
- `LastSuccessfulSyncTime` is blank or stale.
- `SourceType` is `Unknown` or `None`.
- High or unexpected `Stratum`.

## 6. Render Current-State Diagrams

Render combined and per-server source views:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

Expected output:

```text
output/02-current-state-images/current-state-combined.svg
output/02-current-state-images/current-state-combined.png
output/02-current-state-images/current-state-source.svg
output/02-current-state-images/current-state-source.png
output/02-current-state-images/current-state.time-relationship-details.csv
```

Use `-SkipPng` to generate SVG only:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state `
  -SkipPng
```

## 7. Interpret Diagrams

Use `current-state-combined.svg` for topology:

- Left side shows queried servers grouped by time-server classification.
- Right side shows time sources grouped by source type.
- Edge labels such as `T01` map to `TimeEdgeId` in the CSV.

Use `current-state-source.svg` for per-server review:

- One lane per server.
- Shows role, service status, source type, and evidence.
- Lists active source and configured peer relationships.

The diagram is a review aid. Use the CSV and raw collection JSON for evidence-level validation.

## 8. Handoff Files

For normal review, provide:

- `current-state-combined.svg` or `.png`.
- `current-state-source.svg` or `.png`.
- `time-server-summary.csv`.
- `time-relationship-details.csv`.

For technical review, also provide:

- `inventory.json`.
- Selected `*.collection.json` files when raw evidence is required and approved.

Do not hand off raw collection JSON externally unless approved.

## Troubleshooting

### WinRM Fails

Use reduced collection if full remote evidence is not required:

```powershell
.\01-discovery\Export-TimeServerCollection.ps1 `
  -Server PDC01.contoso.com `
  -NoWinRM `
  -OutputPath .\input\discovery-collections
```

Reduced collection does not capture registry, service, CIM, or UDP/123 listener evidence.

### PNG Files Are Missing

Run with `-SkipPng` and use SVG output, or pass a browser path:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -BrowserPath "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
```

### Python Is Not Found

Install Python 3 or pass the executable path:

```powershell
.\03-render-from-discovery\New-TimeServerMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -PythonCommand "C:\Python311\python.exe" `
  -SkipPng
```

### Classification Looks Wrong

Check these fields in `time-server-summary.csv` and the matching collection JSON:

- `Evidence`
- `NtpServerEnabled`
- `Udp123Listening`
- `DomainRole`
- `ServiceStatus`
- `Source`
- `SourceType`

If a server is a domain controller, the tool may classify it as a time server because domain controllers commonly serve domain time. Confirm the intended role with the AD/domain owner.
