# DNS Diagram Toolkit Runbook

This runbook describes the intended operating process for current-state DNS discovery, rendering, and future-state CSV diagram generation.

The current-state and future-state workflow is implemented. Live DNS discovery must be run from a Windows host with the required PowerShell modules; the offline CSV renderer can be tested without live DNS access.

## Offline Sample Render

Render the sample CSV without live DNS or AD access:

```powershell
.\04-render-from-csv\New-DnsMapImagesFromCsv.ps1 `
  -DnsRelationshipCsv .\examples\sample-dns-relationship-details.csv `
  -OutputPath .\examples\sample-output\from-wrapper `
  -Name sample-from-wrapper `
  -SkipPng
```

This writes:

```text
examples/sample-output/from-wrapper/sample-from-wrapper.combined.svg
examples/sample-output/from-wrapper/sample-from-wrapper.source.svg
examples/sample-output/from-wrapper/sample-from-wrapper.inventory.json
examples/sample-output/from-wrapper/sample-from-wrapper.dns-relationship-details.csv
```

Render again from the generated inventory:

```powershell
.\03-render-from-discovery\New-DnsMapImagesFromInventory.ps1 `
  -InventoryJson .\examples\sample-output\from-wrapper\sample-from-wrapper.inventory.json `
  -OutputPath .\examples\sample-output\from-inventory-wrapper `
  -Name current-state `
  -SkipPng
```

Create an editable future-state CSV:

```powershell
.\04-render-from-csv\New-DnsMapFutureStateCsv.ps1 `
  -CurrentCsv .\examples\sample-output\from-wrapper\sample-from-wrapper.dns-relationship-details.csv `
  -OutputCsv .\input\manual-csv\future-state.dns-relationship-details.csv `
  -Force
```

## 1. Collect DNS Data

Run this from a host with the Windows `DnsServer` PowerShell module and network/RBAC access to the DNS server.

Run once per DNS server in scope:

```powershell
.\01-discovery\Export-DnsMapCollection.ps1 `
  -DnsServer dns01.contoso.com `
  -OutputPath .\input\discovery-collections
```

Expected output:

```text
input/discovery-collections/<dns-server>.<yyyyMMddTHHmmssZ>.collection.json
```

## 2. Optional AD Sites And Services Context

AD Sites and Services discovery is owned by the separate `AD-Sites-Services-Topology-Toolkit` folder. Use this optional step only when DNS diagrams need site/subnet enrichment.

From the DNS toolkit folder, run once per AD forest or collection scope:

```powershell
..\AD-Sites-Services-Topology-Toolkit\01-discovery\Export-ADSitesAndServicesInventory.ps1 `
  -OutputPath .\input\discovery-collections
```

Expected output:

```text
input/discovery-collections/<forest-or-domain>.<yyyyMMddTHHmmssZ>.sites.collection.json
```

## 3. Merge Collections

```powershell
.\02-aggregation\Merge-DnsMapCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

Expected output:

```text
output/01-merged-inventory/
  inventory.json
  dns-relationship-details.csv
  dns-zones.csv
  dns-forwarders.csv
  dns-conditional-forwarders.csv
  dns-record-summary.csv
  current-state.mmd
```

## 4. Render Current-State Diagrams

```powershell
.\03-render-from-discovery\New-DnsMapImagesFromInventory.ps1 `
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
output/02-current-state-images/current-state.dns-relationship-details.csv
```

Use `-SkipPng` to generate SVG only.

## 5. Edit CSV For Future State

Create the future-state CSV:

```powershell
.\04-render-from-csv\New-DnsMapFutureStateCsv.ps1
```

This copies:

```text
output/02-current-state-images/current-state.dns-relationship-details.csv
```

to:

```text
input/manual-csv/future-state.dns-relationship-details.csv
```

Edit the future-state CSV:

- Keep unchanged rows as-is.
- Preserve `DnsEdgeId` values for unchanged relationships.
- Add new rows for planned DNS relationships and assign the next unused `D##` value.
- Delete rows that should not appear in the future-state diagram.
- Use `TargetSiteName`, `TargetSubnetName`, `Order`, and `Priority` when future-state relationships need target-side location or forwarder order context.
- Update `Status` and `Notes` to explain planned changes.

## 6. Render From CSV

```powershell
.\04-render-from-csv\New-DnsMapImagesFromCsv.ps1 `
  -DnsRelationshipCsv .\input\manual-csv\future-state.dns-relationship-details.csv `
  -OutputPath .\output\03-csv-generated-images\future-state `
  -Name future-state
```

## 7. Handoff Files

For review, provide:

- Combined SVG/PNG.
- Source SVG/PNG.
- `dns-relationship-details.csv`.
- `dns-zones.csv`.
- `dns-forwarders.csv`.
- `dns-conditional-forwarders.csv`.
- `dns-record-summary.csv`.
- `inventory.json` when deeper technical review is needed.

Do not hand off raw collection JSON externally unless approved; it can contain sensitive infrastructure detail.
