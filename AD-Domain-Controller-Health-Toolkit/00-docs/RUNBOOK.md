# AD Domain Controller Health Toolkit Runbook

## 1. Collect

Run discovery from a domain-joined Windows host with the Active Directory module:

```powershell
.\01-discovery\Export-ADDomainControllerHealthCollection.ps1 `
  -Server dc01.contoso.com `
  -OutputPath .\input\discovery-collections
```

The collector writes both a machine-readable JSON file and a human-readable CSV summary:

```text
<scope>.<timestamp>.dc-health.collection.json
<scope>.<timestamp>.dc-health.summary.csv
```

Use `-NoSummaryCsv` only when the raw JSON collection is the only desired artifact.

Useful collection switches:

| Switch | Purpose |
| --- | --- |
| `-DomainName contoso.com` | Limit domain enumeration to selected domains. |
| `-DomainController dc01,dc02` | Limit service/share/port checks to selected DCs after AD discovery. |
| `-Credential` | Use alternate credentials for AD/CIM reads. |
| `-SkipServiceChecks` | Skip CIM service-state reads. |
| `-SkipShareChecks` | Skip `\\DC\SYSVOL` and `\\DC\NETLOGON` presence checks. |
| `-SkipPortChecks` | Skip LDAP/LDAPS/GC TCP checks and FSMO holder LDAP reachability probes. |
| `-SkipSrvRecordSummary` | Skip `Resolve-DnsName` SRV lookups. |
| `-NoSummaryCsv` | Suppress the companion discovery summary CSV. |

## 2. Merge

```powershell
.\02-aggregation\Merge-ADDomainControllerHealthCollections.ps1 `
  -InputPath .\input\discovery-collections `
  -OutputPath .\output\01-merged-inventory
```

By default the merger looks for:

```text
..\Time-Server-Toolkit\output\01-merged-inventory\inventory.json
```

Pass `-TimeInventoryJson` to use a specific time inventory, or `-NoDefaultTimeInventory` to suppress automatic lookup.

## 3. Review CSVs

Start with:

- `dc-findings.csv`: warning and critical evidence.
- `dc-role-readiness.csv`: migration, decommission, and role-transfer flags.
- `fsmo-roles.csv`: current FSMO holders and holder reachability.
- `dc-health-summary.csv`: one-row-per-DC operating summary.

## 4. Render

```powershell
.\03-render-from-discovery\New-ADDomainControllerHealthMapImagesFromInventory.ps1 `
  -InventoryJson .\output\01-merged-inventory\inventory.json `
  -OutputPath .\output\02-current-state-images `
  -Name current-state
```

Use `-SkipPng` when only SVG is needed.

## 5. Future-State CSV

```powershell
.\04-render-from-csv\New-ADDomainControllerHealthFutureStateCsv.ps1 `
  -CurrentCsv .\output\02-current-state-images\current-state.dc-health-relationship-details.csv `
  -OutputCsv .\input\manual-csv\future-state.dc-health-relationship-details.csv `
  -Force
```

Edit the future-state CSV, then render:

```powershell
.\04-render-from-csv\New-ADDomainControllerHealthMapImagesFromCsv.ps1 `
  -DcHealthRelationshipCsv .\input\manual-csv\future-state.dc-health-relationship-details.csv `
  -OutputPath .\output\03-csv-generated-images `
  -Name future-state `
  -SkipPng
```
