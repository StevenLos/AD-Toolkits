#requires -Version 5.1
<#
.SYNOPSIS
Merges AD domain controller health collection files into inventory and CSVs.

.DESCRIPTION
Offline aggregation for *.dc-health.collection.json files produced by
Export-ADDomainControllerHealthCollection.ps1. It writes inventory.json,
health/readiness/review CSVs, and diagram relationship CSVs.

If a Time-Server-Toolkit inventory is supplied or found at the sibling toolkit's
default output path, selected time-source summary fields are consumed. This
script does not run w32tm or duplicate Windows Time discovery.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath = ".\output\01-merged-inventory",

    [Parameter()]
    [string]$TimeInventoryJson,

    [Parameter()]
    [switch]$NoDefaultTimeInventory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$HealthSummaryFields = @(
    "DomainControllerId",
    "HostName",
    "Name",
    "DomainName",
    "ForestName",
    "SiteName",
    "IsGlobalCatalog",
    "IsReadOnly",
    "Enabled",
    "OperatingSystem",
    "OperatingSystemVersion",
    "BuildNumber",
    "IPv4Addresses",
    "IPv6Addresses",
    "LdapReachable",
    "LdapsReachable",
    "GcReachable",
    "GcLdapsReachable",
    "SysvolShareStatus",
    "NetlogonShareStatus",
    "CoreServicesStatus",
    "TimeSource",
    "TimeSourceType",
    "TimeServiceStatus",
    "TimeStatus",
    "FsmoRoles",
    "LocatorRecordCount",
    "FindingCount",
    "HighestSeverity",
    "Status",
    "SourceCollectionFile",
    "Notes"
)

$ReadinessFields = @(
    "RoleReadinessId",
    "DomainControllerId",
    "HostName",
    "DomainName",
    "SiteName",
    "HeldFsmoRoles",
    "IsGlobalCatalog",
    "IsReadOnly",
    "Enabled",
    "IsLdapReachable",
    "CoreServicesStatus",
    "SharesStatus",
    "LocatorStatus",
    "TimeStatus",
    "RoleTransferReadinessStatus",
    "DecommissionReadinessStatus",
    "MigrationReadinessStatus",
    "Severity",
    "Status",
    "Notes"
)

$FsmoFields = @(
    "FsmoRoleId",
    "RoleName",
    "ScopeType",
    "ScopeName",
    "RoleHolder",
    "DomainControllerId",
    "DomainName",
    "SiteName",
    "IsGlobalCatalog",
    "IsReadOnly",
    "Enabled",
    "ReachabilityStatus",
    "Ldap389Open",
    "TransferReadinessStatus",
    "Severity",
    "Status",
    "Notes"
)

$ServiceFields = @(
    "ServiceCheckId",
    "DomainControllerId",
    "HostName",
    "ServiceName",
    "DisplayName",
    "Status",
    "State",
    "StartMode",
    "CheckStatus",
    "Severity",
    "ReadinessImpact",
    "SourceCollectionFile",
    "Notes"
)

$ShareFields = @(
    "ShareCheckId",
    "DomainControllerId",
    "HostName",
    "ShareName",
    "UncPath",
    "Present",
    "Status",
    "Severity",
    "ReadinessImpact",
    "SourceCollectionFile",
    "Notes"
)

$PortFields = @(
    "PortCheckId",
    "DomainControllerId",
    "HostName",
    "PortName",
    "Protocol",
    "Port",
    "Open",
    "Status",
    "LatencyMilliseconds",
    "Severity",
    "ReadinessImpact",
    "SourceCollectionFile",
    "Notes"
)

$LocatorFields = @(
    "LocatorRecordId",
    "QueryName",
    "Service",
    "Scope",
    "DomainName",
    "SiteName",
    "TargetHost",
    "Port",
    "Priority",
    "Weight",
    "DomainControllerId",
    "HostName",
    "RegistrationStatus",
    "Severity",
    "Status",
    "Notes"
)

$FindingFields = @(
    "FindingId",
    "DomainControllerId",
    "HostName",
    "DomainName",
    "SiteName",
    "Category",
    "Severity",
    "Status",
    "Finding",
    "Recommendation",
    "Evidence",
    "Source"
)

$DiagramFields = @(
    "DcHealthEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "DomainName",
    "SiteName",
    "RoleName",
    "Severity",
    "Status",
    "Notes"
)

function Get-PropertyValue {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $null
        }
        $property = $current.PSObject.Properties[$name]
        if (-not $property) {
            return $null
        }
        $current = $property.Value
    }

    return $current
}

function Get-FirstPropertyValue {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-Text {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return $Value.Trim()
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            if ($null -ne $item -and ([string]$item).Trim()) {
                $items += ([string]$item).Trim()
            }
        }
        return ($items -join "; ")
    }

    return ([string]$Value).Trim()
}

function ConvertTo-BoolText {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    $text = ([string]$Value).Trim()
    if (-not $text) {
        return ""
    }

    if ($text -in @("1", "true", "True", "TRUE", "yes", "Yes", "enabled", "Enabled")) {
        return "true"
    }

    if ($text -in @("0", "false", "False", "FALSE", "no", "No", "disabled", "Disabled")) {
        return "false"
    }

    return $text
}

function ConvertTo-ObjectArray {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $items += $item
            }
        }
        return $items
    }

    return @($Value)
}

function Get-NormalizedName {
    param([Parameter()][string]$Value)

    if (-not $Value) {
        return ""
    }

    return $Value.Trim().TrimEnd(".").ToLowerInvariant()
}

function Get-NameKeys {
    param([Parameter()][string]$Name)

    $keys = @()
    $normalized = Get-NormalizedName -Value $Name
    if ($normalized) {
        $keys += $normalized
        if ($normalized.Contains(".")) {
            $keys += ($normalized.Split(".")[0])
        }
    }

    return @($keys | Select-Object -Unique)
}

function Get-CollectionTimestamp {
    param([Parameter()][object]$Collection)

    foreach ($path in @(
            @("Metadata", "CollectionCompletedUtc"),
            @("Metadata", "TimestampUtc"),
            @("Metadata", "CollectionStartedUtc")
        )) {
        $value = ConvertTo-Text -Value (Get-PropertyValue -InputObject $Collection -Path $path)
        if ($value) {
            try {
                return ([DateTime]::Parse($value)).ToUniversalTime()
            }
            catch {
            }
        }
    }

    return [DateTime]::MinValue
}

function Get-SeverityRank {
    param([Parameter()][string]$Severity)

    switch -Regex ($Severity) {
        "^Critical$" { return 3 }
        "^Warning$" { return 2 }
        "^Info$" { return 1 }
        default { return 0 }
    }
}

function Get-HighestSeverity {
    param([Parameter()][object[]]$Rows)

    $highest = "Info"
    foreach ($row in @($Rows)) {
        $severity = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $row -Names @("Severity", "HighestSeverity"))
        if ((Get-SeverityRank -Severity $severity) -gt (Get-SeverityRank -Severity $highest)) {
            $highest = $severity
        }
    }

    return $highest
}

function Get-StatusFromSeverity {
    param([Parameter()][string]$Severity)

    switch ($Severity) {
        "Critical" { return "Blocked" }
        "Warning" { return "Review" }
        default { return "OK" }
    }
}

function Export-CsvRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns
    )

    $outputRows = @()
    foreach ($row in @($Rows)) {
        $out = [ordered]@{}
        foreach ($column in $Columns) {
            $out[$column] = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $row -Names @($column))
        }
        $outputRows += [pscustomobject]$out
    }

    if ($outputRows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value ($Columns -join ",") -Encoding UTF8
        return
    }

    $outputRows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$InputObject
    )

    $InputObject | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ReadinessImpact {
    param([Parameter()][string]$Severity)

    switch ($Severity) {
        "Critical" { return "Blocker" }
        "Warning" { return "Review" }
        default { return "None" }
    }
}

function Get-ServiceSeverity {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter()][string]$Status,
        [Parameter()][string]$CheckStatus
    )

    if ($CheckStatus -in @("NotCollected", "Unknown")) {
        return "Warning"
    }

    if ($Status -ieq "Running") {
        return "Info"
    }

    if ($ServiceName -in @("NTDS", "Netlogon", "DFSR", "KDC")) {
        return "Critical"
    }

    return "Warning"
}

function Get-ShareSeverity {
    param([Parameter()][string]$Status)

    if ($Status -eq "Present") {
        return "Info"
    }
    if ($Status -eq "Missing") {
        return "Critical"
    }
    return "Warning"
}

function Get-PortSeverity {
    param(
        [Parameter(Mandatory = $true)][object]$Dc,
        [Parameter(Mandatory = $true)][string]$PortName,
        [Parameter()][string]$Open,
        [Parameter()][string]$Status
    )

    $isGc = (ConvertTo-BoolText -Value $Dc.IsGlobalCatalog) -eq "true"
    if ($Open -eq "true") {
        return "Info"
    }

    if ($PortName -eq "LDAP") {
        return "Critical"
    }

    if ($PortName -eq "GC" -and $isGc) {
        return "Critical"
    }

    if ($PortName -in @("LDAPS", "GC-LDAPS")) {
        return "Warning"
    }

    if ($Status -in @("NotCollected", "Unknown")) {
        return "Warning"
    }

    return "Info"
}

function Find-DomainControllerByName {
    param([Parameter()][string]$Name)

    foreach ($key in (Get-NameKeys -Name $Name)) {
        if ($script:dcLookup.ContainsKey($key)) {
            return $script:dcLookup[$key]
        }
    }

    return $null
}

function Add-Finding {
    param(
        [Parameter()][object]$Dc,
        [Parameter()][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Finding,
        [Parameter(Mandatory = $true)][string]$Recommendation,
        [Parameter()][string]$Evidence,
        [Parameter()][string]$Source
    )

    $dcId = ""
    $dcHost = $HostName
    $domain = ""
    $site = ""
    if ($Dc) {
        $dcId = ConvertTo-Text -Value $Dc.DomainControllerId
        $dcHost = ConvertTo-Text -Value $Dc.HostName
        $domain = ConvertTo-Text -Value $Dc.DomainName
        $site = ConvertTo-Text -Value $Dc.SiteName
    }

    $key = (Get-NormalizedName -Value "$dcId|$dcHost|$Category|$Severity|$Finding|$Evidence")
    if ($script:findingKeySet.ContainsKey($key)) {
        return
    }
    $script:findingKeySet[$key] = $true

    $script:findingItems += [pscustomobject][ordered]@{
        DomainControllerId = $dcId
        HostName = $dcHost
        DomainName = $domain
        SiteName = $site
        Category = $Category
        Severity = $Severity
        Status = $Status
        Finding = $Finding
        Recommendation = $Recommendation
        Evidence = $Evidence
        Source = $Source
    }
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath was not found: $InputPath"
}

$inputDirectory = Resolve-Path -LiteralPath $InputPath
$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force

$collectionFiles = @(Get-ChildItem -LiteralPath $inputDirectory.Path -Recurse -File | Where-Object {
    $_.Name -like "*.collection.json"
} | Sort-Object FullName)
if ($collectionFiles.Count -eq 0) {
    throw "No *.collection.json files were found in $($inputDirectory.Path)."
}

$collections = @()
$collectionFileEntries = @()
foreach ($file in $collectionFiles) {
    $entry = [ordered]@{
        FilePath = $file.FullName
        FileName = $file.Name
        CollectionType = "Unknown"
        TimestampUtc = ""
        CollectionStatus = ""
        Included = $false
        Notes = ""
    }

    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $collectionType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $json -Path @("Metadata", "CollectionType"))
        $entry.CollectionType = $collectionType
        $entry.TimestampUtc = ConvertTo-Text -Value (Get-PropertyValue -InputObject $json -Path @("Metadata", "TimestampUtc"))
        $entry.CollectionStatus = ConvertTo-Text -Value (Get-PropertyValue -InputObject $json -Path @("Metadata", "CollectionStatus"))
        if ($collectionType -eq "ADDomainControllerHealth") {
            $entry.Included = $true
            $collections += [pscustomobject]@{
                File = $file.FullName
                Data = $json
                Timestamp = Get-CollectionTimestamp -Collection $json
            }
        }
        else {
            $entry.Notes = "Skipped non-ADDomainControllerHealth collection."
        }
    }
    catch {
        $entry.Notes = "Skipped malformed collection: $($_.Exception.Message)"
    }

    $collectionFileEntries += [pscustomobject]$entry
}

if ($collections.Count -eq 0) {
    throw "No ADDomainControllerHealth collection files were found in $($inputDirectory.Path)."
}

$timeInventoryPath = $null
if ($TimeInventoryJson) {
    if (-not (Test-Path -LiteralPath $TimeInventoryJson)) {
        throw "TimeInventoryJson was not found: $TimeInventoryJson"
    }
    $timeInventoryPath = (Resolve-Path -LiteralPath $TimeInventoryJson).Path
}
elseif (-not $NoDefaultTimeInventory) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $workspaceRoot = Split-Path -Parent $projectRoot
    $candidateTimeInventory = Join-Path $workspaceRoot "Time-Server-Toolkit\output\01-merged-inventory\inventory.json"
    if (Test-Path -LiteralPath $candidateTimeInventory) {
        $timeInventoryPath = (Resolve-Path -LiteralPath $candidateTimeInventory).Path
    }
}

$timeLookup = @{}
if ($timeInventoryPath) {
    $timeInventory = Get-Content -LiteralPath $timeInventoryPath -Raw | ConvertFrom-Json
    foreach ($server in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $timeInventory -Names @("Servers")))) {
        foreach ($name in @(
                (Get-FirstPropertyValue -InputObject $server -Names @("ServerName", "ComputerName", "QueriedServer")),
                (Get-FirstPropertyValue -InputObject $server -Names @("Fqdn"))
            )) {
            foreach ($key in (Get-NameKeys -Name (ConvertTo-Text -Value $name))) {
                if ($key -and -not $timeLookup.ContainsKey($key)) {
                    $timeLookup[$key] = $server
                }
            }
        }
    }
}

$latestDcByKey = @{}
foreach ($collection in $collections) {
    foreach ($dc in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("DomainControllers")))) {
        $hostName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
        if (-not $hostName) {
            continue
        }

        $key = Get-NormalizedName -Value $hostName
        $candidate = [pscustomobject]@{
            Key = $key
            HostName = $hostName
            Timestamp = $collection.Timestamp
            SourceFile = $collection.File
            Data = $dc
        }
        if (-not $latestDcByKey.ContainsKey($key) -or $candidate.Timestamp -gt $latestDcByKey[$key].Timestamp) {
            $latestDcByKey[$key] = $candidate
        }
    }
}

$dcBaseRows = @()
$dcIndex = 0
foreach ($candidate in @($latestDcByKey.Values | Sort-Object @{ Expression = { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $_.Data -Names @("DomainName", "Domain")) } }, @{ Expression = { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $_.Data -Names @("SiteName", "Site")) } }, @{ Expression = { $_.HostName } })) {
    $dcIndex++
    $dc = $candidate.Data
    $dcBaseRows += [pscustomobject][ordered]@{
        DomainControllerId = "DC{0:000}" -f $dcIndex
        HostName = $candidate.HostName
        Name = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("Name"))
        DomainName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("DomainName", "Domain"))
        ForestName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("ForestName", "Forest"))
        SiteName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("SiteName", "Site"))
        IsGlobalCatalog = ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $dc -Names @("IsGlobalCatalog"))
        IsReadOnly = ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $dc -Names @("IsReadOnly"))
        Enabled = ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $dc -Names @("Enabled"))
        OperatingSystem = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("OperatingSystem"))
        OperatingSystemVersion = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("OperatingSystemVersion"))
        BuildNumber = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("BuildNumber"))
        IPv4Addresses = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("IPv4Addresses", "IPv4Address"))
        IPv6Addresses = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $dc -Names @("IPv6Addresses", "IPv6Address"))
        SourceCollectionFile = $candidate.SourceFile
    }
}

$script:dcLookup = @{}
foreach ($dc in $dcBaseRows) {
    foreach ($name in @($dc.HostName, $dc.Name)) {
        foreach ($key in (Get-NameKeys -Name $name)) {
            if ($key -and -not $script:dcLookup.ContainsKey($key)) {
                $script:dcLookup[$key] = $dc
            }
        }
    }
}

$script:findingItems = @()
$script:findingKeySet = @{}

$serviceCandidates = @{}
foreach ($collection in $collections) {
    foreach ($service in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("Services")))) {
        $serviceHostName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $service -Names @("DcHostName", "ComputerName", "HostName"))
        $serviceName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $service -Names @("ServiceName", "Name"))
        if (-not $serviceHostName -or -not $serviceName) {
            continue
        }
        $key = "$(Get-NormalizedName -Value $serviceHostName)|$(Get-NormalizedName -Value $serviceName)"
        $candidate = [pscustomobject]@{
            Timestamp = $collection.Timestamp
            SourceFile = $collection.File
            Data = $service
        }
        if (-not $serviceCandidates.ContainsKey($key) -or $candidate.Timestamp -gt $serviceCandidates[$key].Timestamp) {
            $serviceCandidates[$key] = $candidate
        }
    }
}

$serviceRows = @()
$serviceIndex = 0
foreach ($dc in $dcBaseRows) {
    foreach ($serviceName in @("NTDS", "Netlogon", "DFSR", "DNS", "KDC", "W32Time")) {
        $key = "$(Get-NormalizedName -Value $dc.HostName)|$(Get-NormalizedName -Value $serviceName)"
        $candidate = $null
        if ($serviceCandidates.ContainsKey($key)) {
            $candidate = $serviceCandidates[$key]
        }
        $data = if ($candidate) { $candidate.Data } else { $null }
        $status = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Status", "State")) } else { "NotCollected" }
        $checkStatus = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("CheckStatus")) } else { "NotCollected" }
        if (-not $checkStatus) {
            $checkStatus = "Collected"
        }
        $severity = Get-ServiceSeverity -ServiceName $serviceName -Status $status -CheckStatus $checkStatus
        $serviceIndex++
        $row = [pscustomobject][ordered]@{
            ServiceCheckId = "S{0:000}" -f $serviceIndex
            DomainControllerId = $dc.DomainControllerId
            HostName = $dc.HostName
            ServiceName = $serviceName
            DisplayName = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("DisplayName")) } else { "" }
            Status = $status
            State = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("State")) } else { "NotCollected" }
            StartMode = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("StartMode")) } else { "" }
            CheckStatus = $checkStatus
            Severity = $severity
            ReadinessImpact = Get-ReadinessImpact -Severity $severity
            SourceCollectionFile = if ($candidate) { $candidate.SourceFile } else { $dc.SourceCollectionFile }
            Notes = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Error", "Notes")) } else { "Service state was not collected." }
        }
        $serviceRows += $row
        if ($severity -ne "Info") {
            Add-Finding -Dc $dc -Category "Service" -Severity $severity -Status (Get-StatusFromSeverity -Severity $severity) -Finding "$serviceName service status is $status." -Recommendation "Validate $serviceName on $($dc.HostName) before migration, role transfer, or decommission activity." -Evidence $row.Notes -Source $row.ServiceCheckId
        }
    }
}

$shareCandidates = @{}
foreach ($collection in $collections) {
    foreach ($share in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("Shares")))) {
        $shareHostName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $share -Names @("DcHostName", "ComputerName", "HostName"))
        $shareName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $share -Names @("ShareName", "Name"))
        if (-not $shareHostName -or -not $shareName) {
            continue
        }
        $key = "$(Get-NormalizedName -Value $shareHostName)|$(Get-NormalizedName -Value $shareName)"
        $candidate = [pscustomobject]@{
            Timestamp = $collection.Timestamp
            SourceFile = $collection.File
            Data = $share
        }
        if (-not $shareCandidates.ContainsKey($key) -or $candidate.Timestamp -gt $shareCandidates[$key].Timestamp) {
            $shareCandidates[$key] = $candidate
        }
    }
}

$shareRows = @()
$shareIndex = 0
foreach ($dc in $dcBaseRows) {
    foreach ($shareName in @("SYSVOL", "NETLOGON")) {
        $key = "$(Get-NormalizedName -Value $dc.HostName)|$(Get-NormalizedName -Value $shareName)"
        $candidate = $null
        if ($shareCandidates.ContainsKey($key)) {
            $candidate = $shareCandidates[$key]
        }
        $data = if ($candidate) { $candidate.Data } else { $null }
        $status = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Status")) } else { "NotCollected" }
        $severity = Get-ShareSeverity -Status $status
        $shareIndex++
        $row = [pscustomobject][ordered]@{
            ShareCheckId = "SH{0:000}" -f $shareIndex
            DomainControllerId = $dc.DomainControllerId
            HostName = $dc.HostName
            ShareName = $shareName
            UncPath = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("UncPath")) } else { "\\$($dc.HostName)\$shareName" }
            Present = if ($data) { ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $data -Names @("Present")) } else { "" }
            Status = $status
            Severity = $severity
            ReadinessImpact = Get-ReadinessImpact -Severity $severity
            SourceCollectionFile = if ($candidate) { $candidate.SourceFile } else { $dc.SourceCollectionFile }
            Notes = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Error", "Notes")) } else { "Share presence was not collected." }
        }
        $shareRows += $row
        if ($severity -ne "Info") {
            Add-Finding -Dc $dc -Category "Share" -Severity $severity -Status (Get-StatusFromSeverity -Severity $severity) -Finding "$shareName share status is $status." -Recommendation "Confirm SYSVOL/NETLOGON health before moving AD roles or decommissioning this DC." -Evidence $row.UncPath -Source $row.ShareCheckId
        }
    }
}

$portCandidates = @{}
foreach ($collection in $collections) {
    foreach ($port in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("PortChecks")))) {
        $portHostName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $port -Names @("DcHostName", "ComputerName", "HostName"))
        $portName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $port -Names @("PortName"))
        if (-not $portHostName -or -not $portName) {
            continue
        }
        $key = "$(Get-NormalizedName -Value $portHostName)|$(Get-NormalizedName -Value $portName)"
        $candidate = [pscustomobject]@{
            Timestamp = $collection.Timestamp
            SourceFile = $collection.File
            Data = $port
        }
        if (-not $portCandidates.ContainsKey($key) -or $candidate.Timestamp -gt $portCandidates[$key].Timestamp) {
            $portCandidates[$key] = $candidate
        }
    }
}

$portRows = @()
$portIndex = 0
foreach ($dc in $dcBaseRows) {
    foreach ($portDefinition in @(
            @{ PortName = "LDAP"; Port = "389" },
            @{ PortName = "LDAPS"; Port = "636" },
            @{ PortName = "GC"; Port = "3268" },
            @{ PortName = "GC-LDAPS"; Port = "3269" }
        )) {
        $key = "$(Get-NormalizedName -Value $dc.HostName)|$(Get-NormalizedName -Value $portDefinition.PortName)"
        $candidate = $null
        if ($portCandidates.ContainsKey($key)) {
            $candidate = $portCandidates[$key]
        }
        $data = if ($candidate) { $candidate.Data } else { $null }
        $open = if ($data) { ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $data -Names @("Open")) } else { "" }
        $status = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Status")) } else { "NotCollected" }
        $severity = Get-PortSeverity -Dc $dc -PortName $portDefinition.PortName -Open $open -Status $status
        $portIndex++
        $row = [pscustomobject][ordered]@{
            PortCheckId = "P{0:000}" -f $portIndex
            DomainControllerId = $dc.DomainControllerId
            HostName = $dc.HostName
            PortName = $portDefinition.PortName
            Protocol = "TCP"
            Port = $portDefinition.Port
            Open = $open
            Status = $status
            LatencyMilliseconds = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("LatencyMilliseconds")) } else { "" }
            Severity = $severity
            ReadinessImpact = Get-ReadinessImpact -Severity $severity
            SourceCollectionFile = if ($candidate) { $candidate.SourceFile } else { $dc.SourceCollectionFile }
            Notes = if ($data) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $data -Names @("Error", "Notes")) } else { "Port availability was not collected." }
        }
        $portRows += $row
        if ($severity -ne "Info") {
            Add-Finding -Dc $dc -Category "Port" -Severity $severity -Status (Get-StatusFromSeverity -Severity $severity) -Finding "$($portDefinition.PortName) TCP/$($portDefinition.Port) status is $status." -Recommendation "Validate collector-to-DC connectivity and service listener state before role transfer or migration activity." -Evidence $row.Notes -Source $row.PortCheckId
        }
    }
}

foreach ($dc in $dcBaseRows) {
    if ($dc.Enabled -eq "false") {
        Add-Finding -Dc $dc -Category "Inventory" -Severity "Critical" -Status "Blocked" -Finding "Domain controller computer account is disabled." -Recommendation "Do not target this DC for migration or role transfer until account state is understood." -Evidence "Enabled=false" -Source "DomainControllers"
    }
}

$locatorRows = @()
$locatorIndex = 0
foreach ($collection in $collections) {
    foreach ($record in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("SrvRecords")))) {
        $queryStatus = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("QueryStatus", "Status"))
        $targetHost = (ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("NameTarget", "TargetHost"))).TrimEnd(".")
        $dc = Find-DomainControllerByName -Name $targetHost
        $registrationStatus = ""
        $severity = "Info"
        if ($queryStatus -eq "Resolved" -and $dc) {
            $registrationStatus = "Registered"
        }
        elseif ($queryStatus -eq "Resolved") {
            $registrationStatus = "ExternalOrUnknownTarget"
            $severity = "Warning"
        }
        elseif ($queryStatus -eq "NoRecords") {
            $registrationStatus = "NoRecords"
            $severity = "Warning"
        }
        elseif ($queryStatus -eq "Error") {
            $registrationStatus = "QueryError"
            $severity = "Warning"
        }
        else {
            $registrationStatus = "Unknown"
            $severity = "Warning"
        }

        $locatorIndex++
        $locatorRows += [pscustomobject][ordered]@{
            LocatorRecordId = "L{0:000}" -f $locatorIndex
            QueryName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("QueryName"))
            Service = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Service"))
            Scope = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Scope"))
            DomainName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("DomainName"))
            SiteName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("SiteName"))
            TargetHost = $targetHost
            Port = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Port"))
            Priority = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Priority"))
            Weight = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Weight"))
            DomainControllerId = if ($dc) { $dc.DomainControllerId } else { "" }
            HostName = if ($dc) { $dc.HostName } else { $targetHost }
            RegistrationStatus = $registrationStatus
            Severity = $severity
            Status = Get-StatusFromSeverity -Severity $severity
            Notes = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $record -Names @("Error", "Notes"))
        }
    }
}

$locatorByDc = @{}
foreach ($locator in $locatorRows) {
    if ($locator.DomainControllerId -and $locator.RegistrationStatus -eq "Registered") {
        if (-not $locatorByDc.ContainsKey($locator.DomainControllerId)) {
            $locatorByDc[$locator.DomainControllerId] = 0
        }
        $locatorByDc[$locator.DomainControllerId]++
    }
}
foreach ($dc in $dcBaseRows) {
    if ($locatorRows.Count -eq 0) {
        Add-Finding -Dc $dc -Category "Locator" -Severity "Warning" -Status "Review" -Finding "DC locator SRV records were not collected." -Recommendation "Run discovery without -SkipSrvRecordSummary or provide DNS SRV evidence before final readiness decisions." -Evidence "No SrvRecords present in collection input." -Source "SrvRecords"
    }
    elseif (-not $locatorByDc.ContainsKey($dc.DomainControllerId)) {
        Add-Finding -Dc $dc -Category "Locator" -Severity "Warning" -Status "Review" -Finding "No DC locator SRV records matched this domain controller." -Recommendation "Validate SRV registration, Netlogon registration, and DNS zone health." -Evidence "No resolved SRV target matched $($dc.HostName)." -Source "dc-locator-records.csv"
    }
}

$fsmoCandidates = @{}
foreach ($collection in $collections) {
    foreach ($role in (ConvertTo-ObjectArray -Value (Get-FirstPropertyValue -InputObject $collection.Data -Names @("FSMORoles", "FsmoRoles")))) {
        $roleName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleName"))
        $scopeName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("ScopeName"))
        if (-not $roleName) {
            continue
        }
        $key = "$(Get-NormalizedName -Value $roleName)|$(Get-NormalizedName -Value $scopeName)"
        $candidate = [pscustomobject]@{
            Timestamp = $collection.Timestamp
            SourceFile = $collection.File
            Data = $role
        }
        if (-not $fsmoCandidates.ContainsKey($key) -or $candidate.Timestamp -gt $fsmoCandidates[$key].Timestamp) {
            $fsmoCandidates[$key] = $candidate
        }
    }
}

$fsmoRows = @()
$fsmoIndex = 0
foreach ($candidate in @($fsmoCandidates.Values | Sort-Object @{ Expression = { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $_.Data -Names @("ScopeType")) } }, @{ Expression = { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $_.Data -Names @("ScopeName")) } }, @{ Expression = { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $_.Data -Names @("RoleName")) } })) {
    $role = $candidate.Data
    $holder = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleHolder"))
    $dc = Find-DomainControllerByName -Name $holder
    $reachabilityStatus = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleHolderReachabilityStatus", "ReachabilityStatus"))
    $ldapOpen = ConvertTo-BoolText -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleHolderLdap389Open", "Ldap389Open"))
    $severity = "Info"
    $transferStatus = "Ready"
    $notes = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleHolderReachabilityEvidence", "Notes"))
    if (-not $holder) {
        $severity = "Critical"
        $transferStatus = "Blocked"
        $notes = "Role holder was blank."
    }
    elseif (-not $dc) {
        $severity = "Warning"
        $transferStatus = "Review"
        $notes = "Role holder was not found in discovered DC inventory. $notes".Trim()
    }
    elseif ($dc.IsReadOnly -eq "true") {
        $severity = "Critical"
        $transferStatus = "Blocked"
        $notes = "FSMO role appears to be associated with an RODC. $notes".Trim()
    }
    elseif ($dc.Enabled -eq "false") {
        $severity = "Critical"
        $transferStatus = "Blocked"
        $notes = "Role holder computer account is disabled. $notes".Trim()
    }
    elseif ($reachabilityStatus -eq "Unreachable" -or $ldapOpen -eq "false") {
        $severity = "Critical"
        $transferStatus = "Blocked"
    }
    elseif ($reachabilityStatus -in @("Unknown", "NotCollected", "MissingHolder") -or -not $reachabilityStatus) {
        $severity = "Warning"
        $transferStatus = "Review"
    }

    $fsmoIndex++
    $row = [pscustomobject][ordered]@{
        FsmoRoleId = "F{0:000}" -f $fsmoIndex
        RoleName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("RoleName"))
        ScopeType = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("ScopeType"))
        ScopeName = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $role -Names @("ScopeName"))
        RoleHolder = $holder
        DomainControllerId = if ($dc) { $dc.DomainControllerId } else { "" }
        DomainName = if ($dc) { $dc.DomainName } else { "" }
        SiteName = if ($dc) { $dc.SiteName } else { "" }
        IsGlobalCatalog = if ($dc) { $dc.IsGlobalCatalog } else { "" }
        IsReadOnly = if ($dc) { $dc.IsReadOnly } else { "" }
        Enabled = if ($dc) { $dc.Enabled } else { "" }
        ReachabilityStatus = $reachabilityStatus
        Ldap389Open = $ldapOpen
        TransferReadinessStatus = $transferStatus
        Severity = $severity
        Status = Get-StatusFromSeverity -Severity $severity
        Notes = $notes
    }
    $fsmoRows += $row
    if ($severity -ne "Info") {
        Add-Finding -Dc $dc -HostName $holder -Category "FSMO" -Severity $severity -Status $row.Status -Finding "$($row.RoleName) role holder readiness is $transferStatus." -Recommendation "Validate role holder health and plan transfer or seizure decision points before role changes." -Evidence $row.Notes -Source $row.FsmoRoleId
    }
}

$fsmoByDc = @{}
foreach ($role in $fsmoRows) {
    if ($role.DomainControllerId) {
        if (-not $fsmoByDc.ContainsKey($role.DomainControllerId)) {
            $fsmoByDc[$role.DomainControllerId] = @()
        }
        $fsmoByDc[$role.DomainControllerId] += $role.RoleName
    }
}

$gcCountByDomain = @{}
foreach ($dc in $dcBaseRows) {
    if ($dc.IsGlobalCatalog -eq "true" -and $dc.Enabled -ne "false") {
        $domainKey = Get-NormalizedName -Value $dc.DomainName
        if (-not $gcCountByDomain.ContainsKey($domainKey)) {
            $gcCountByDomain[$domainKey] = 0
        }
        $gcCountByDomain[$domainKey]++
    }
}

foreach ($dc in $dcBaseRows) {
    $heldRoles = @()
    if ($fsmoByDc.ContainsKey($dc.DomainControllerId)) {
        $heldRoles = @($fsmoByDc[$dc.DomainControllerId])
        Add-Finding -Dc $dc -Category "DecommissionReadiness" -Severity "Warning" -Status "Review" -Finding "Domain controller currently holds FSMO roles: $($heldRoles -join ', ')." -Recommendation "Transfer FSMO roles and validate new holders before decommissioning this DC." -Evidence ($heldRoles -join "; ") -Source "fsmo-roles.csv"
    }

    $domainKey = Get-NormalizedName -Value $dc.DomainName
    if ($dc.IsGlobalCatalog -eq "true" -and $gcCountByDomain.ContainsKey($domainKey) -and $gcCountByDomain[$domainKey] -eq 1) {
        Add-Finding -Dc $dc -Category "DecommissionReadiness" -Severity "Warning" -Status "Review" -Finding "Domain controller is the only discovered global catalog in its domain." -Recommendation "Confirm GC coverage before decommissioning or demoting this DC." -Evidence "Enabled GC count for $($dc.DomainName): 1" -Source "dc-health-summary.csv"
    }
}

$timeByDc = @{}
foreach ($dc in $dcBaseRows) {
    $timeServer = $null
    foreach ($key in (Get-NameKeys -Name $dc.HostName)) {
        if ($timeLookup.ContainsKey($key)) {
            $timeServer = $timeLookup[$key]
            break
        }
    }
    if ($timeServer) {
        $timeByDc[$dc.DomainControllerId] = $timeServer
        $serviceStatus = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $timeServer -Names @("ServiceStatus"))
        $source = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $timeServer -Names @("Source"))
        $sourceType = ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $timeServer -Names @("SourceType"))
        if ($serviceStatus -and $serviceStatus -ne "Running") {
            Add-Finding -Dc $dc -Category "Time" -Severity "Warning" -Status "Review" -Finding "Sibling time inventory reports W32Time service status '$serviceStatus'." -Recommendation "Review Time-Server-Toolkit output before migration or role transfer planning." -Evidence $serviceStatus -Source "Time-Server-Toolkit"
        }
        if (-not $source -or $sourceType -in @("LocalClock", "None", "Unknown")) {
            Add-Finding -Dc $dc -Category "Time" -Severity "Warning" -Status "Review" -Finding "Sibling time inventory reports risky or unknown time source." -Recommendation "Review Time-Server-Toolkit output and correct time hierarchy before AD role changes." -Evidence "Source=$source; SourceType=$sourceType" -Source "Time-Server-Toolkit"
        }
    }
}

$findingRows = @()
$findingIndex = 0
foreach ($finding in @($script:findingItems | Sort-Object @{ Expression = { Get-SeverityRank -Severity $_.Severity }; Descending = $true }, DomainControllerId, Category, Finding)) {
    $findingIndex++
    $findingRows += [pscustomobject][ordered]@{
        FindingId = "FIND{0:000}" -f $findingIndex
        DomainControllerId = $finding.DomainControllerId
        HostName = $finding.HostName
        DomainName = $finding.DomainName
        SiteName = $finding.SiteName
        Category = $finding.Category
        Severity = $finding.Severity
        Status = $finding.Status
        Finding = $finding.Finding
        Recommendation = $finding.Recommendation
        Evidence = $finding.Evidence
        Source = $finding.Source
    }
}

$findingsByDc = @{}
foreach ($finding in $findingRows) {
    if ($finding.DomainControllerId) {
        if (-not $findingsByDc.ContainsKey($finding.DomainControllerId)) {
            $findingsByDc[$finding.DomainControllerId] = @()
        }
        $findingsByDc[$finding.DomainControllerId] += $finding
    }
}

function Get-PortStatusForDc {
    param(
        [Parameter(Mandatory = $true)][string]$DomainControllerId,
        [Parameter(Mandatory = $true)][string]$PortName
    )

    $row = @($portRows | Where-Object { $_.DomainControllerId -eq $DomainControllerId -and $_.PortName -eq $PortName } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        return "Unknown"
    }
    if ($row[0].Open -eq "true") {
        return "true"
    }
    if ($row[0].Open -eq "false") {
        return "false"
    }
    return $row[0].Status
}

function Get-ShareStatusForDc {
    param(
        [Parameter(Mandatory = $true)][string]$DomainControllerId,
        [Parameter(Mandatory = $true)][string]$ShareName
    )

    $row = @($shareRows | Where-Object { $_.DomainControllerId -eq $DomainControllerId -and $_.ShareName -eq $ShareName } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        return "Unknown"
    }
    return $row[0].Status
}

function Get-AggregateStatus {
    param([Parameter()][object[]]$Rows)

    $severity = Get-HighestSeverity -Rows $Rows
    return Get-StatusFromSeverity -Severity $severity
}

$healthRows = @()
foreach ($dc in $dcBaseRows) {
    $dcFindings = @()
    if ($findingsByDc.ContainsKey($dc.DomainControllerId)) {
        $dcFindings = @($findingsByDc[$dc.DomainControllerId])
    }
    $highestSeverity = Get-HighestSeverity -Rows $dcFindings
    $time = $null
    if ($timeByDc.ContainsKey($dc.DomainControllerId)) {
        $time = $timeByDc[$dc.DomainControllerId]
    }
    $dcServiceRows = @($serviceRows | Where-Object { $_.DomainControllerId -eq $dc.DomainControllerId })
    $dcShareRows = @($shareRows | Where-Object { $_.DomainControllerId -eq $dc.DomainControllerId })
    $heldRoles = if ($fsmoByDc.ContainsKey($dc.DomainControllerId)) { @($fsmoByDc[$dc.DomainControllerId]) } else { @() }
    $locatorCount = if ($locatorByDc.ContainsKey($dc.DomainControllerId)) { $locatorByDc[$dc.DomainControllerId] } else { 0 }
    $healthRows += [pscustomobject][ordered]@{
        DomainControllerId = $dc.DomainControllerId
        HostName = $dc.HostName
        Name = $dc.Name
        DomainName = $dc.DomainName
        ForestName = $dc.ForestName
        SiteName = $dc.SiteName
        IsGlobalCatalog = $dc.IsGlobalCatalog
        IsReadOnly = $dc.IsReadOnly
        Enabled = $dc.Enabled
        OperatingSystem = $dc.OperatingSystem
        OperatingSystemVersion = $dc.OperatingSystemVersion
        BuildNumber = $dc.BuildNumber
        IPv4Addresses = $dc.IPv4Addresses
        IPv6Addresses = $dc.IPv6Addresses
        LdapReachable = Get-PortStatusForDc -DomainControllerId $dc.DomainControllerId -PortName "LDAP"
        LdapsReachable = Get-PortStatusForDc -DomainControllerId $dc.DomainControllerId -PortName "LDAPS"
        GcReachable = Get-PortStatusForDc -DomainControllerId $dc.DomainControllerId -PortName "GC"
        GcLdapsReachable = Get-PortStatusForDc -DomainControllerId $dc.DomainControllerId -PortName "GC-LDAPS"
        SysvolShareStatus = Get-ShareStatusForDc -DomainControllerId $dc.DomainControllerId -ShareName "SYSVOL"
        NetlogonShareStatus = Get-ShareStatusForDc -DomainControllerId $dc.DomainControllerId -ShareName "NETLOGON"
        CoreServicesStatus = Get-AggregateStatus -Rows $dcServiceRows
        TimeSource = if ($time) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $time -Names @("Source")) } else { "NotProvided" }
        TimeSourceType = if ($time) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $time -Names @("SourceType")) } else { "NotProvided" }
        TimeServiceStatus = if ($time) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $time -Names @("ServiceStatus")) } else { "NotProvided" }
        TimeStatus = if ($time) { ConvertTo-Text -Value (Get-FirstPropertyValue -InputObject $time -Names @("CollectionStatus", "Status")) } else { "NotProvided" }
        FsmoRoles = ($heldRoles -join "; ")
        LocatorRecordCount = $locatorCount
        FindingCount = @($dcFindings).Count
        HighestSeverity = $highestSeverity
        Status = Get-StatusFromSeverity -Severity $highestSeverity
        SourceCollectionFile = $dc.SourceCollectionFile
        Notes = if (@($dcFindings).Count -gt 0) { (($dcFindings | Select-Object -First 3 | ForEach-Object { $_.Finding }) -join " ") } else { "No warning or critical findings generated." }
    }
}

$readinessRows = @()
$readinessIndex = 0
foreach ($health in $healthRows) {
    $dc = Find-DomainControllerByName -Name $health.HostName
    $dcFindings = if ($findingsByDc.ContainsKey($health.DomainControllerId)) { @($findingsByDc[$health.DomainControllerId]) } else { @() }
    $highestSeverity = $health.HighestSeverity
    $heldRoles = if ($fsmoByDc.ContainsKey($health.DomainControllerId)) { @($fsmoByDc[$health.DomainControllerId]) } else { @() }
    $domainKey = Get-NormalizedName -Value $health.DomainName
    $soleGc = $health.IsGlobalCatalog -eq "true" -and $gcCountByDomain.ContainsKey($domainKey) -and $gcCountByDomain[$domainKey] -eq 1
    $ldapReachable = $health.LdapReachable -eq "true"

    $roleTransfer = "Ready"
    if ($health.Enabled -eq "false" -or $health.IsReadOnly -eq "true" -or -not $ldapReachable -or $highestSeverity -eq "Critical") {
        $roleTransfer = "Blocked"
    }
    elseif ($highestSeverity -eq "Warning") {
        $roleTransfer = "Review"
    }

    $decommission = "Ready"
    if (@($heldRoles).Count -gt 0 -or $soleGc -or $highestSeverity -eq "Critical") {
        $decommission = "Blocked"
    }
    elseif ($highestSeverity -eq "Warning") {
        $decommission = "Review"
    }

    $migration = "Ready"
    if ($highestSeverity -eq "Critical") {
        $migration = "Blocked"
    }
    elseif ($highestSeverity -eq "Warning") {
        $migration = "Review"
    }

    $readinessIndex++
    $readinessRows += [pscustomobject][ordered]@{
        RoleReadinessId = "RR{0:000}" -f $readinessIndex
        DomainControllerId = $health.DomainControllerId
        HostName = $health.HostName
        DomainName = $health.DomainName
        SiteName = $health.SiteName
        HeldFsmoRoles = ($heldRoles -join "; ")
        IsGlobalCatalog = $health.IsGlobalCatalog
        IsReadOnly = $health.IsReadOnly
        Enabled = $health.Enabled
        IsLdapReachable = $ldapReachable.ToString().ToLowerInvariant()
        CoreServicesStatus = $health.CoreServicesStatus
        SharesStatus = Get-AggregateStatus -Rows @($shareRows | Where-Object { $_.DomainControllerId -eq $health.DomainControllerId })
        LocatorStatus = if ($health.LocatorRecordCount -gt 0) { "OK" } else { "Review" }
        TimeStatus = $health.TimeStatus
        RoleTransferReadinessStatus = $roleTransfer
        DecommissionReadinessStatus = $decommission
        MigrationReadinessStatus = $migration
        Severity = $highestSeverity
        Status = Get-StatusFromSeverity -Severity $highestSeverity
        Notes = if (@($dcFindings).Count -gt 0) { (($dcFindings | Select-Object -First 4 | ForEach-Object { $_.Finding }) -join " ") } else { "No generated readiness blockers." }
    }
}

$diagramRows = @()
$edgeIndex = 0
function Add-DiagramEdge {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceType,
        [Parameter(Mandatory = $true)][string]$Relationship,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$TargetType,
        [Parameter()][string]$DomainName,
        [Parameter()][string]$SiteName,
        [Parameter()][string]$RoleName,
        [Parameter()][string]$Severity = "Info",
        [Parameter()][string]$Status = "OK",
        [Parameter()][string]$Notes
    )

    if (-not $Source -or -not $Target) {
        return
    }

    $script:edgeIndex++
    $script:diagramRows += [pscustomobject][ordered]@{
        DcHealthEdgeId = "DCH{0:000}" -f $script:edgeIndex
        Source = $Source
        SourceType = $SourceType
        Relationship = $Relationship
        Target = $Target
        TargetType = $TargetType
        DomainName = $DomainName
        SiteName = $SiteName
        RoleName = $RoleName
        Severity = $Severity
        Status = $Status
        Notes = $Notes
    }
}

$script:diagramRows = @()
$script:edgeIndex = 0
foreach ($health in $healthRows) {
    Add-DiagramEdge -Source $health.HostName -SourceType "DomainController" -Relationship "ServesDomain" -Target $health.DomainName -TargetType "ADDomain" -DomainName $health.DomainName -SiteName $health.SiteName -Severity $health.HighestSeverity -Status $health.Status -Notes "DC health status: $($health.Status)"
    if ($health.SiteName) {
        Add-DiagramEdge -Source $health.HostName -SourceType "DomainController" -Relationship "LocatedInSite" -Target $health.SiteName -TargetType "ADSite" -DomainName $health.DomainName -SiteName $health.SiteName -Severity "Info" -Status "OK" -Notes ""
    }
    if ($health.TimeSource -and $health.TimeSource -ne "NotProvided") {
        Add-DiagramEdge -Source $health.HostName -SourceType "DomainController" -Relationship "UsesTimeSource" -Target $health.TimeSource -TargetType "TimeSource" -DomainName $health.DomainName -SiteName $health.SiteName -Severity "Info" -Status $health.TimeStatus -Notes $health.TimeSourceType
    }
}

foreach ($role in $fsmoRows) {
    Add-DiagramEdge -Source $role.RoleHolder -SourceType "DomainController" -Relationship "HoldsFsmo" -Target $role.RoleName -TargetType "FSMORole" -DomainName $role.DomainName -SiteName $role.SiteName -RoleName $role.RoleName -Severity $role.Severity -Status $role.Status -Notes $role.ScopeName
}

foreach ($finding in @($findingRows | Where-Object { $_.Severity -in @("Critical", "Warning") })) {
    if ($finding.HostName) {
        Add-DiagramEdge -Source $finding.HostName -SourceType "DomainController" -Relationship "HasFinding" -Target $finding.Category -TargetType "FindingCategory" -DomainName $finding.DomainName -SiteName $finding.SiteName -Severity $finding.Severity -Status $finding.Status -Notes $finding.Finding
    }
}
$diagramRows = $script:diagramRows

$inventory = [ordered]@{
    Metadata = [ordered]@{
        Source = "ADDomainControllerHealthCollections"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString("o")
        InputPath = $inputDirectory.Path
        CollectionCount = $collections.Count
        DomainControllerCount = $healthRows.Count
        FindingCount = $findingRows.Count
        TimeInventoryPath = $timeInventoryPath
    }
    CollectionFiles = $collectionFileEntries
    DomainControllers = $healthRows
    RoleReadiness = $readinessRows
    FSMORoles = $fsmoRows
    Services = $serviceRows
    Shares = $shareRows
    PortChecks = $portRows
    LocatorRecords = $locatorRows
    Findings = $findingRows
    DiagramEdges = $diagramRows
}

$inventoryPath = Join-Path $outputDirectory.FullName "inventory.json"
$healthCsvPath = Join-Path $outputDirectory.FullName "dc-health-summary.csv"
$readinessCsvPath = Join-Path $outputDirectory.FullName "dc-role-readiness.csv"
$fsmoCsvPath = Join-Path $outputDirectory.FullName "fsmo-roles.csv"
$servicesCsvPath = Join-Path $outputDirectory.FullName "dc-services.csv"
$sharesCsvPath = Join-Path $outputDirectory.FullName "dc-shares.csv"
$portsCsvPath = Join-Path $outputDirectory.FullName "dc-port-checks.csv"
$locatorCsvPath = Join-Path $outputDirectory.FullName "dc-locator-records.csv"
$findingsCsvPath = Join-Path $outputDirectory.FullName "dc-findings.csv"
$diagramCsvPath = Join-Path $outputDirectory.FullName "dc-health-relationship-details.csv"

Write-JsonFile -Path $inventoryPath -InputObject ([pscustomobject]$inventory)
Export-CsvRows -Path $healthCsvPath -Rows $healthRows -Columns $HealthSummaryFields
Export-CsvRows -Path $readinessCsvPath -Rows $readinessRows -Columns $ReadinessFields
Export-CsvRows -Path $fsmoCsvPath -Rows $fsmoRows -Columns $FsmoFields
Export-CsvRows -Path $servicesCsvPath -Rows $serviceRows -Columns $ServiceFields
Export-CsvRows -Path $sharesCsvPath -Rows $shareRows -Columns $ShareFields
Export-CsvRows -Path $portsCsvPath -Rows $portRows -Columns $PortFields
Export-CsvRows -Path $locatorCsvPath -Rows $locatorRows -Columns $LocatorFields
Export-CsvRows -Path $findingsCsvPath -Rows $findingRows -Columns $FindingFields
Export-CsvRows -Path $diagramCsvPath -Rows $diagramRows -Columns $DiagramFields

[pscustomobject]@{
    InputPath = $inputDirectory.Path
    CollectionCount = $collections.Count
    DomainControllerCount = $healthRows.Count
    FindingCount = $findingRows.Count
    InventoryJson = $inventoryPath
    HealthSummaryCsv = $healthCsvPath
    RoleReadinessCsv = $readinessCsvPath
    FsmoRolesCsv = $fsmoCsvPath
    ServicesCsv = $servicesCsvPath
    SharesCsv = $sharesCsvPath
    PortChecksCsv = $portsCsvPath
    LocatorRecordsCsv = $locatorCsvPath
    FindingsCsv = $findingsCsvPath
    DiagramRelationshipCsv = $diagramCsvPath
    TimeInventoryJson = $timeInventoryPath
}
