#requires -Version 5.1
<#
.SYNOPSIS
Merges Windows Time collection JSON files into a normalized inventory and CSVs.

.DESCRIPTION
Reads *.collection.json files produced by Export-TimeServerCollection.ps1 and
writes inventory.json, time-relationship-details.csv, and time-server-summary.csv.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath = ".\output\01-merged-inventory",

    [Parameter()]
    [switch]$Recurse
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RelationshipFields = @(
    "TimeEdgeId",
    "SourceServer",
    "Relationship",
    "Target",
    "TargetType",
    "ActiveSource",
    "SourceType",
    "IsTimeServer",
    "NtpServerEnabled",
    "NtpClientEnabled",
    "Udp123Listening",
    "W32TimeType",
    "ServiceStatus",
    "Stratum",
    "LastSuccessfulSyncTime",
    "Offset",
    "Status",
    "CollectionServer",
    "Notes"
)

$SummaryFields = @(
    "ServerName",
    "Fqdn",
    "IPAddress",
    "IsTimeServer",
    "Source",
    "SourceType",
    "W32TimeType",
    "NtpServerEnabled",
    "NtpClientEnabled",
    "Udp123Listening",
    "ServiceStatus",
    "DomainRole",
    "Stratum",
    "LastSuccessfulSyncTime",
    "Status",
    "Evidence"
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

function Get-ServerName {
    param([Parameter(Mandatory = $true)][object]$Collection)

    $name = ConvertTo-Text -Value (Get-PropertyValue -InputObject $Collection -Path @("ServerIdentity", "ComputerName"))
    if ($name) {
        return $name
    }

    $queried = ConvertTo-Text -Value (Get-PropertyValue -InputObject $Collection -Path @("Metadata", "QueriedServer"))
    if ($queried) {
        return $queried
    }

    return "Unknown"
}

function Get-WarningText {
    param([Parameter()][object]$Collection)

    $items = @()
    foreach ($warning in @($Collection.CollectionWarnings)) {
        $step = ConvertTo-Text -Value (Get-PropertyValue -InputObject $warning -Path @("Step"))
        $message = ConvertTo-Text -Value (Get-PropertyValue -InputObject $warning -Path @("Message"))
        if ($step -or $message) {
            $items += "${step}: $message".Trim(": ")
        }
    }

    foreach ($errorItem in @($Collection.CollectionErrors)) {
        $step = ConvertTo-Text -Value (Get-PropertyValue -InputObject $errorItem -Path @("Step"))
        $message = ConvertTo-Text -Value (Get-PropertyValue -InputObject $errorItem -Path @("Message"))
        if ($step -or $message) {
            $items += "ERROR ${step}: $message".Trim(": ")
        }
    }

    return ($items -join "; ")
}

function Get-TargetInfo {
    param(
        [Parameter()][string]$Source,
        [Parameter()][string]$SourceType
    )

    $sourceText = $Source.Trim()
    $typeText = $SourceType.Trim()

    if ($typeText -eq "LocalClock") {
        return [pscustomobject]@{
            Relationship = "UsesLocalClock"
            Target = if ($sourceText) { $sourceText } else { "Local Clock" }
            TargetType = "LocalClock"
        }
    }

    if ($typeText -like "Hypervisor*") {
        return [pscustomobject]@{
            Relationship = "UsesHypervisor"
            Target = if ($sourceText) { $sourceText } else { "Hypervisor Time Provider" }
            TargetType = "Hypervisor"
        }
    }

    if ($typeText -eq "None") {
        return [pscustomobject]@{
            Relationship = "UnknownSource"
            Target = "No configured sync source"
            TargetType = "None"
        }
    }

    if (-not $sourceText) {
        return [pscustomobject]@{
            Relationship = "UnknownSource"
            Target = "Unknown"
            TargetType = "Unknown"
        }
    }

    if ($typeText -eq "DomainHierarchy") {
        return [pscustomobject]@{
            Relationship = "SyncsFrom"
            Target = $sourceText
            TargetType = "DomainTimeSource"
        }
    }

    if ($typeText -eq "ManualNtp") {
        return [pscustomobject]@{
            Relationship = "SyncsFrom"
            Target = ($sourceText -split ',', 2)[0]
            TargetType = "NtpPeer"
        }
    }

    return [pscustomobject]@{
        Relationship = "SyncsFrom"
        Target = ($sourceText -split ',', 2)[0]
        TargetType = "TimeSource"
    }
}

function New-RelationshipRow {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$SourceServer,
        [Parameter(Mandatory = $true)][string]$Relationship,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$TargetType,
        [Parameter(Mandatory = $true)][object]$Collection,
        [Parameter()][string]$Notes
    )

    $classification = Get-PropertyValue -InputObject $Collection -Path @("Classification")
    $timeService = Get-PropertyValue -InputObject $Collection -Path @("TimeService")

    [pscustomobject][ordered]@{
        TimeEdgeId = "T{0:00}" -f $Index
        SourceServer = $SourceServer
        Relationship = $Relationship
        Target = $Target
        TargetType = $TargetType
        ActiveSource = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Source"))
        SourceType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("SourceType"))
        IsTimeServer = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("IsTimeServer"))
        NtpServerEnabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("NtpServerEnabled"))
        NtpClientEnabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("NtpClientEnabled"))
        Udp123Listening = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("Udp123Listening"))
        W32TimeType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("W32TimeType"))
        ServiceStatus = ConvertTo-Text -Value (Get-PropertyValue -InputObject $timeService -Path @("Status"))
        Stratum = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Stratum"))
        LastSuccessfulSyncTime = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("LastSuccessfulSyncTime"))
        Offset = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Offset"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $Collection -Path @("Metadata", "CollectionStatus"))
        CollectionServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $Collection -Path @("Metadata", "QueriedServer"))
        Notes = $Notes
    }
}

$inputDirectory = Resolve-Path -LiteralPath $InputPath
$getChildItemParams = @{
    LiteralPath = $inputDirectory.Path
    Filter = "*.collection.json"
    File = $true
}
if ($Recurse) {
    $getChildItemParams["Recurse"] = $true
}

$collectionFiles = @(Get-ChildItem @getChildItemParams | Sort-Object FullName)
if ($collectionFiles.Count -eq 0) {
    throw "No *.collection.json files were found in $($inputDirectory.Path)."
}

$collections = @()
foreach ($file in $collectionFiles) {
    $json = Get-Content -LiteralPath $file.FullName -Raw
    $collection = $json | ConvertFrom-Json
    $collections += [pscustomobject]@{
        File = $file.FullName
        Data = $collection
    }
}

$servers = @()
$edges = @()
$edgeIndex = 0

foreach ($collectionItem in $collections) {
    $collection = $collectionItem.Data
    $serverName = Get-ServerName -Collection $collection
    $classification = Get-PropertyValue -InputObject $collection -Path @("Classification")
    $identity = Get-PropertyValue -InputObject $collection -Path @("ServerIdentity")
    $timeService = Get-PropertyValue -InputObject $collection -Path @("TimeService")
    $warningText = Get-WarningText -Collection $collection
    $evidence = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Evidence"))

    $servers += [pscustomobject][ordered]@{
        ServerName = $serverName
        QueriedServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $collection -Path @("Metadata", "QueriedServer"))
        Fqdn = ConvertTo-Text -Value (Get-PropertyValue -InputObject $identity -Path @("Fqdn"))
        IPAddress = ConvertTo-Text -Value (Get-PropertyValue -InputObject $identity -Path @("IPAddresses"))
        Domain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $identity -Path @("Domain"))
        DomainRole = ConvertTo-Text -Value (Get-PropertyValue -InputObject $identity -Path @("DomainRole"))
        OperatingSystem = ConvertTo-Text -Value (Get-PropertyValue -InputObject $identity -Path @("OperatingSystem"))
        IsTimeServer = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("IsTimeServer"))
        Source = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Source"))
        SourceType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("SourceType"))
        W32TimeType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("W32TimeType"))
        NtpServerEnabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("NtpServerEnabled"))
        NtpClientEnabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("NtpClientEnabled"))
        Udp123Listening = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $classification -Path @("Udp123Listening"))
        ServiceStatus = ConvertTo-Text -Value (Get-PropertyValue -InputObject $timeService -Path @("Status"))
        Stratum = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Stratum"))
        LastSuccessfulSyncTime = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("LastSuccessfulSyncTime"))
        Offset = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Offset"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $collection -Path @("Metadata", "CollectionStatus"))
        Evidence = $evidence
        Warnings = $warningText
        CollectionFile = $collectionItem.File
    }

    $activeSource = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("Source"))
    $sourceType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $classification -Path @("SourceType"))
    $targetInfo = Get-TargetInfo -Source $activeSource -SourceType $sourceType
    $edgeIndex++
    $notes = @($evidence, $warningText) | Where-Object { $_ } | Select-Object -First 2
    $edges += New-RelationshipRow -Index $edgeIndex -SourceServer $serverName -Relationship $targetInfo.Relationship -Target $targetInfo.Target -TargetType $targetInfo.TargetType -Collection $collection -Notes ($notes -join "; ")

    foreach ($peer in @($collection.ManualPeers)) {
        $peerName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $peer -Path @("PeerName"))
        if (-not $peerName) {
            $peerName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $peer -Path @("Peer"))
        }
        if (-not $peerName) {
            continue
        }

        if ($peerName -ieq $targetInfo.Target -and $targetInfo.Relationship -eq "SyncsFrom") {
            continue
        }

        $edgeIndex++
        $flags = ConvertTo-Text -Value (Get-PropertyValue -InputObject $peer -Path @("Flags"))
        $peerNotes = if ($flags) { "Configured peer flags: $flags" } else { "Configured peer" }
        $edges += New-RelationshipRow -Index $edgeIndex -SourceServer $serverName -Relationship "ConfiguredPeer" -Target $peerName -TargetType "NtpPeer" -Collection $collection -Notes $peerNotes
    }
}

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$inventoryPath = Join-Path $outputDirectory.FullName "inventory.json"
$relationshipCsvPath = Join-Path $outputDirectory.FullName "time-relationship-details.csv"
$summaryCsvPath = Join-Path $outputDirectory.FullName "time-server-summary.csv"

$inventory = [ordered]@{
    Metadata = [ordered]@{
        Source = "TimeServerCollections"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString("o")
        CollectionCount = $collections.Count
        ServerCount = $servers.Count
        RelationshipCount = $edges.Count
    }
    CollectionFiles = @($collections | ForEach-Object { $_.File })
    Servers = $servers
    TimeEdges = $edges
}

([pscustomobject]$inventory) | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
$edges | Select-Object $RelationshipFields | Export-Csv -LiteralPath $relationshipCsvPath -NoTypeInformation -Encoding UTF8
$servers | Select-Object $SummaryFields | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation -Encoding UTF8

[pscustomobject]@{
    InputPath = $inputDirectory.Path
    CollectionCount = $collections.Count
    InventoryJson = $inventoryPath
    RelationshipCsv = $relationshipCsvPath
    ServerSummaryCsv = $summaryCsvPath
}
