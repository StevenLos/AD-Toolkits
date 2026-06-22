#requires -Version 5.1
<#
.SYNOPSIS
Merges DNS map collection bundles into normalized inventory and CSV outputs.

.DESCRIPTION
Offline aggregation. It enriches DNS servers with AD site/subnet context,
generates deterministic DnsEdges, and writes inventory.json plus review CSVs
under output/01-merged-inventory.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath = ".\output\01-merged-inventory",

    [Parameter()]
    [string]$MetadataPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$relationshipFields = @(
    "DnsEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "ZoneName",
    "RecordType",
    "Direction",
    "SiteName",
    "SubnetName",
    "TargetSiteName",
    "TargetSubnetName",
    "DnsServer",
    "Order",
    "Priority",
    "Status",
    "SourceCollectionServer",
    "Notes"
)

function Get-ObjectPropertyValue {
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

function ConvertTo-StringArray {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ($Value.Trim()) {
            return @($Value.Trim())
        }
        return @()
    }

    $items = @()
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            if ($null -ne $item -and ([string]$item).Trim()) {
                $items += ([string]$item).Trim()
            }
        }
    }
    else {
        if (([string]$Value).Trim()) {
            $items += ([string]$Value).Trim()
        }
    }

    return $items
}

function ConvertTo-CsvValue {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return ((ConvertTo-StringArray -Value $Value) -join "; ")
    }

    return [string]$Value
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

function ConvertTo-IPv4UInt32 {
    param([Parameter(Mandatory = $true)][string]$IPAddress)

    try {
        $ip = [System.Net.IPAddress]::Parse($IPAddress)
        if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $null
        }

        $bytes = $ip.GetAddressBytes()
        return ([uint64]$bytes[0] -shl 24) -bor ([uint64]$bytes[1] -shl 16) -bor ([uint64]$bytes[2] -shl 8) -bor [uint64]$bytes[3]
    }
    catch {
        return $null
    }
}

function Get-CidrPrefixLength {
    param([Parameter()][string]$Cidr)

    if (-not $Cidr -or $Cidr -notmatch '/') {
        return $null
    }

    $parts = $Cidr.Split("/")
    $prefix = 0
    if ([int]::TryParse($parts[1], [ref]$prefix)) {
        return $prefix
    }

    return $null
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string]$Cidr
    )

    if ($Cidr -notmatch '/') {
        return $false
    }

    $parts = $Cidr.Split("/")
    $prefix = Get-CidrPrefixLength -Cidr $Cidr
    if ($null -eq $prefix -or $prefix -lt 0 -or $prefix -gt 32) {
        return $false
    }

    $ipValue = ConvertTo-IPv4UInt32 -IPAddress $IPAddress
    $networkValue = ConvertTo-IPv4UInt32 -IPAddress $parts[0]
    if ($null -eq $ipValue -or $null -eq $networkValue) {
        return $false
    }

    if ($prefix -eq 0) {
        $mask = [uint64]0
    }
    else {
        $mask = (([uint64]0xffffffff) -shl (32 - $prefix)) -band [uint64]0xffffffff
    }

    return (($ipValue -band $mask) -eq ($networkValue -band $mask))
}

function Get-CollectionTimestamp {
    param([Parameter()][object]$Json)

    $metadata = Get-ObjectPropertyValue -InputObject $Json -Names @("Metadata")
    $value = Get-ObjectPropertyValue -InputObject $metadata -Names @("TimestampUtc", "CollectionCompletedUtc", "CollectionStartedUtc")
    if (-not $value) {
        return [DateTime]::MinValue
    }

    try {
        return ([DateTime]::Parse([string]$value)).ToUniversalTime()
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Get-CollectionType {
    param([Parameter()][object]$Json)

    $metadata = Get-ObjectPropertyValue -InputObject $Json -Names @("Metadata")
    $type = Get-ObjectPropertyValue -InputObject $metadata -Names @("CollectionType")
    if ($type) {
        return [string]$type
    }

    if (Get-ObjectPropertyValue -InputObject $Json -Names @("DnsServerIdentity")) {
        return "DnsServer"
    }

    if (Get-ObjectPropertyValue -InputObject $Json -Names @("ADSites")) {
        return "ADSitesAndServices"
    }

    return "Unknown"
}

function Get-DnsCollectionServerName {
    param([Parameter()][object]$Json)

    $metadata = Get-ObjectPropertyValue -InputObject $Json -Names @("Metadata")
    $identity = Get-ObjectPropertyValue -InputObject $Json -Names @("DnsServerIdentity")
    foreach ($value in @(
        (Get-ObjectPropertyValue -InputObject $metadata -Names @("QueriedServer")),
        (Get-ObjectPropertyValue -InputObject $identity -Names @("Fqdn")),
        (Get-ObjectPropertyValue -InputObject $identity -Names @("ServerName")),
        (Get-ObjectPropertyValue -InputObject $identity -Names @("QueriedServer"))
    )) {
        if ($value -and ([string]$value).Trim()) {
            return ([string]$value).Trim()
        }
    }

    return $null
}

function Add-UniqueObject {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $normalizedKey = Get-NormalizedName -Value $Key
    if (-not $normalizedKey) {
        return
    }

    if (-not $Map.ContainsKey($normalizedKey)) {
        $Map[$normalizedKey] = $Value
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
            $out[$column] = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $row -Names @($column))
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

    $json = $InputObject | ConvertTo-Json -Depth 60
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-ServerByNameOrIp {
    param(
        [Parameter()][string]$Value,
        [Parameter(Mandatory = $true)][hashtable]$NameLookup,
        [Parameter(Mandatory = $true)][hashtable]$IpLookup
    )

    if (-not $Value) {
        return $null
    }

    foreach ($key in (Get-NameKeys -Name $Value)) {
        if ($NameLookup.ContainsKey($key)) {
            return $NameLookup[$key]
        }
    }

    $normalizedIp = $Value.Trim()
    if ($IpLookup.ContainsKey($normalizedIp)) {
        return $IpLookup[$normalizedIp]
    }

    return $null
}

function Resolve-DnsServerSite {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter()][string[]]$IPAddresses,
        [Parameter(Mandatory = $true)][hashtable]$DomainControllerLookup,
        [Parameter(Mandatory = $true)][object[]]$Subnets
    )

    foreach ($key in (Get-NameKeys -Name $ServerName)) {
        if ($DomainControllerLookup.ContainsKey($key)) {
            $dc = $DomainControllerLookup[$key]
            return [pscustomobject]@{
                SiteName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("SiteName"))
                SubnetName = ""
                Notes = "Matched domain controller hostname."
            }
        }
    }

    $matches = @()
    foreach ($ip in @($IPAddresses)) {
        foreach ($subnet in @($Subnets)) {
            $subnetName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("SubnetName"))
            if ($subnetName -and (Test-IPv4InCidr -IPAddress $ip -Cidr $subnetName)) {
                $matches += [pscustomobject]@{
                    IPAddress = $ip
                    SubnetName = $subnetName
                    PrefixLength = Get-CidrPrefixLength -Cidr $subnetName
                    SiteName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("SiteName"))
                }
            }
        }
    }

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            SiteName = "Unknown"
            SubnetName = ""
            Notes = "No matching domain controller or AD subnet was found."
        }
    }

    $siteNames = @($matches | ForEach-Object { $_.SiteName } | Where-Object { $_ } | Select-Object -Unique)
    if ($siteNames.Count -gt 1) {
        return [pscustomobject]@{
            SiteName = "Ambiguous"
            SubnetName = (($matches | Sort-Object PrefixLength -Descending | Select-Object -First 1).SubnetName)
            Notes = "Matched multiple AD sites: $($siteNames -join ', ')."
        }
    }

    $bestMatch = $matches | Sort-Object PrefixLength -Descending | Select-Object -First 1
    return [pscustomobject]@{
        SiteName = if ($bestMatch.SiteName) { $bestMatch.SiteName } else { "Unknown" }
        SubnetName = $bestMatch.SubnetName
        Notes = "Matched AD subnet $($bestMatch.SubnetName)."
    }
}

function Get-RecordDataValue {
    param(
        [Parameter()][object]$Record,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $recordData = Get-ObjectPropertyValue -InputObject $Record -Names @("RecordData")
    return Get-ObjectPropertyValue -InputObject $recordData -Names $Names
}

function Add-DnsEdgeCandidate {
    param(
        [Parameter(Mandatory = $true)][int]$Pass,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceType,
        [Parameter(Mandatory = $true)][string]$Relationship,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$TargetType,
        [Parameter()][string]$ZoneName,
        [Parameter()][string]$RecordType,
        [Parameter()][string]$Direction = "SourceToTarget",
        [Parameter()][string]$SiteName,
        [Parameter()][string]$SubnetName,
        [Parameter()][string]$TargetSiteName,
        [Parameter()][string]$TargetSubnetName,
        [Parameter()][string]$DnsServer,
        [Parameter()][string]$Order,
        [Parameter()][string]$Priority,
        [Parameter()][string]$Status = "Discovered",
        [Parameter()][string]$SourceCollectionServer,
        [Parameter()][string]$Notes
    )

    if (-not $Source -or -not $Target) {
        return
    }

    $edge = [ordered]@{}
    foreach ($field in $script:relationshipFields) {
        $edge[$field] = ""
    }

    $edge.Source = $Source
    $edge.SourceType = $SourceType
    $edge.Relationship = $Relationship
    $edge.Target = $Target
    $edge.TargetType = $TargetType
    $edge.ZoneName = $ZoneName
    $edge.RecordType = $RecordType
    $edge.Direction = $Direction
    $edge.SiteName = $SiteName
    $edge.SubnetName = $SubnetName
    $edge.TargetSiteName = $TargetSiteName
    $edge.TargetSubnetName = $TargetSubnetName
    $edge.DnsServer = $DnsServer
    $edge.Order = $Order
    $edge.Priority = $Priority
    $edge.Status = $Status
    $edge.SourceCollectionServer = $SourceCollectionServer
    $edge.Notes = $Notes

    $key = @(
        $Relationship,
        $Source,
        $SourceType,
        $Target,
        $TargetType,
        $ZoneName,
        $RecordType,
        $DnsServer,
        $Order
    ) -join "|"
    $normalizedKey = Get-NormalizedName -Value $key
    if ($script:edgeKeySet.ContainsKey($normalizedKey)) {
        return
    }
    $script:edgeKeySet[$normalizedKey] = $true

    $script:edgeCandidates += [pscustomobject]@{
        Pass = $Pass
        SortKey = $normalizedKey
        Edge = [pscustomobject]$edge
    }
}

function Write-MermaidDiagram {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Edges
    )

    $nodeIds = @{}
    $nodeIndex = 0
    function Get-MermaidNodeId {
        param([string]$Label)
        $key = Get-NormalizedName -Value $Label
        if (-not $nodeIds.ContainsKey($key)) {
            $script:nodeIndexForMermaid = $script:nodeIndexForMermaid + 1
            $nodeIds[$key] = "n$($script:nodeIndexForMermaid)"
        }
        return $nodeIds[$key]
    }

    $script:nodeIndexForMermaid = $nodeIndex
    $lines = @("flowchart LR")
    foreach ($edge in @($Edges)) {
        $source = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $edge -Names @("Source"))
        $target = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $edge -Names @("Target"))
        $sourceId = Get-MermaidNodeId -Label $source
        $targetId = Get-MermaidNodeId -Label $target
        $sourceLabel = $source.Replace('"', "'")
        $targetLabel = $target.Replace('"', "'")
        $edgeLabel = ("{0} {1}" -f $edge.DnsEdgeId, $edge.Relationship).Replace('"', "'")
        $lines += "  $sourceId[`"$sourceLabel`"] -->|`"$edgeLabel`"| $targetId[`"$targetLabel`"]"
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath was not found: $InputPath"
}

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force

$metadataOverlay = $null
if ($MetadataPath) {
    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        throw "MetadataPath was not found: $MetadataPath"
    }
    $metadataOverlay = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
}

$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse | Where-Object {
    -not $_.PSIsContainer -and ($_.Name -like "*.collection.json" -or $_.Name -like "*.sites.collection.json")
})

$collectionFileEntries = @()
$dnsCandidates = @()
$adCollections = @()
$parseWarnings = @()

foreach ($file in $files) {
    $entry = [ordered]@{
        FilePath = $file.FullName
        FileName = $file.Name
        CollectionType = "Unknown"
        Source = ""
        TimestampUtc = ""
        CollectionStatus = ""
        Included = $false
        Notes = ""
    }

    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $metadata = Get-ObjectPropertyValue -InputObject $json -Names @("Metadata")
        $type = Get-CollectionType -Json $json
        $timestampValue = Get-ObjectPropertyValue -InputObject $metadata -Names @("TimestampUtc", "CollectionCompletedUtc", "CollectionStartedUtc")
        $status = Get-ObjectPropertyValue -InputObject $metadata -Names @("CollectionStatus")

        $entry.CollectionType = $type
        $entry.TimestampUtc = ConvertTo-CsvValue -Value $timestampValue
        $entry.CollectionStatus = ConvertTo-CsvValue -Value $status

        if ($type -ieq "DnsServer") {
            $serverName = Get-DnsCollectionServerName -Json $json
            if (-not $serverName) {
                throw "DNS collection did not include a queryable server name."
            }
            $entry.Source = $serverName
            $candidate = [pscustomobject]@{
                FileEntry = $entry
                FilePath = $file.FullName
                Json = $json
                ServerName = $serverName
                Timestamp = Get-CollectionTimestamp -Json $json
            }
            $dnsCandidates += $candidate
        }
        elseif ($type -ieq "ADSitesAndServices") {
            $entry.Source = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $metadata -Names @("ForestName", "DomainName", "Server"))
            $entry.Included = $true
            $adCollections += [pscustomobject]@{
                FileEntry = $entry
                FilePath = $file.FullName
                Json = $json
                Timestamp = Get-CollectionTimestamp -Json $json
            }
        }
        else {
            $entry.Notes = "Skipped unknown collection type."
        }
    }
    catch {
        $entry.Notes = "Skipped malformed collection: $($_.Exception.Message)"
        $parseWarnings += [pscustomobject]@{
            FilePath = $file.FullName
            Message = $_.Exception.Message
        }
    }

    $collectionFileEntries += $entry
}

$latestByServer = @{}
foreach ($candidate in $dnsCandidates) {
    $key = Get-NormalizedName -Value $candidate.ServerName
    if (-not $latestByServer.ContainsKey($key) -or $candidate.Timestamp -gt $latestByServer[$key].Timestamp) {
        $latestByServer[$key] = $candidate
    }
}

$dnsCollections = @()
foreach ($candidate in $dnsCandidates) {
    $key = Get-NormalizedName -Value $candidate.ServerName
    if ($latestByServer[$key].FilePath -eq $candidate.FilePath) {
        $candidate.FileEntry.Included = $true
        $dnsCollections += $candidate
    }
    else {
        $candidate.FileEntry.Included = $false
        $candidate.FileEntry.Notes = "Superseded by newer collection for $($candidate.ServerName)."
    }
}

$adSiteMap = @{}
$adSubnetMap = @{}
$adSiteLinkMap = @{}
$domainControllerMap = @{}

foreach ($collection in $adCollections) {
    foreach ($site in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $collection.Json -Names @("ADSites")))) {
        $siteName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("SiteName", "Name"))
        if ($siteName) {
            Add-UniqueObject -Map $adSiteMap -Key $siteName -Value ([pscustomobject]@{
                SiteName = $siteName
                DistinguishedName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("DistinguishedName"))
                Description = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Description"))
                Location = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Location"))
                SourceCollectionFile = $collection.FilePath
            })
        }
    }

    foreach ($subnet in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $collection.Json -Names @("ADSubnets")))) {
        $subnetName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("SubnetName", "Name"))
        if ($subnetName) {
            Add-UniqueObject -Map $adSubnetMap -Key $subnetName -Value ([pscustomobject]@{
                SubnetName = $subnetName
                SiteName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("SiteName"))
                SiteDistinguishedName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("SiteDistinguishedName"))
                Description = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Description"))
                Location = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Location"))
                SourceCollectionFile = $collection.FilePath
            })
        }
    }

    foreach ($siteLink in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $collection.Json -Names @("ADSiteLinks")))) {
        $siteLinkName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("SiteLinkName", "Name"))
        if ($siteLinkName) {
            Add-UniqueObject -Map $adSiteLinkMap -Key $siteLinkName -Value ([pscustomobject]@{
                SiteLinkName = $siteLinkName
                SitesIncluded = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("SitesIncluded"))
                Cost = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("Cost"))
                ReplicationFrequencyInMinutes = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("ReplicationFrequencyInMinutes"))
                Options = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("Options"))
                SourceCollectionFile = $collection.FilePath
            })
        }
    }

    foreach ($dc in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $collection.Json -Names @("DomainControllers")))) {
        $hostName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
        if ($hostName) {
            Add-UniqueObject -Map $domainControllerMap -Key $hostName -Value ([pscustomobject]@{
                Name = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Name"))
                HostName = $hostName
                Domain = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Domain"))
                Forest = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Forest"))
                SiteName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("SiteName", "Site"))
                IPv4Addresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IPv4Addresses", "IPv4Address"))
                IPv6Addresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IPv6Addresses", "IPv6Address"))
                IsGlobalCatalog = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IsGlobalCatalog"))
                OperatingSystem = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("OperatingSystem"))
                SourceCollectionFile = $collection.FilePath
            })
        }
    }
}

$adSites = @($adSiteMap.Values | Sort-Object SiteName)
$adSubnets = @($adSubnetMap.Values | Sort-Object SubnetName)
$adSiteLinks = @($adSiteLinkMap.Values | Sort-Object SiteLinkName)
$domainControllers = @($domainControllerMap.Values | Sort-Object HostName)

$dcLookup = @{}
foreach ($dc in $domainControllers) {
    foreach ($name in @($dc.HostName, $dc.Name)) {
        foreach ($key in (Get-NameKeys -Name $name)) {
            if ($key -and -not $dcLookup.ContainsKey($key)) {
                $dcLookup[$key] = $dc
            }
        }
    }
}

$dnsServers = @()
$zones = @()
$records = @()
$forwarders = @()
$conditionalForwarders = @()
$delegations = @()
$nameServers = @()
$rootHints = @()

foreach ($collection in $dnsCollections) {
    $json = $collection.Json
    $metadata = Get-ObjectPropertyValue -InputObject $json -Names @("Metadata")
    $identity = Get-ObjectPropertyValue -InputObject $json -Names @("DnsServerIdentity")
    $serverName = $collection.ServerName
    $ipAddresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $identity -Names @("IPAddresses", "IPAddress"))
    $siteInfo = Resolve-DnsServerSite -ServerName $serverName -IPAddresses $ipAddresses -DomainControllerLookup $dcLookup -Subnets $adSubnets
    $sourceCollectionServer = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $metadata -Names @("QueriedServer"))
    if (-not $sourceCollectionServer) {
        $sourceCollectionServer = $serverName
    }

    $dnsServers += [pscustomobject]@{
        Name = $serverName
        QueriedServer = $sourceCollectionServer
        Fqdn = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $identity -Names @("Fqdn"))
        IPAddresses = $ipAddresses
        SiteName = $siteInfo.SiteName
        SubnetName = $siteInfo.SubnetName
        CollectionStatus = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $metadata -Names @("CollectionStatus"))
        SourceCollectionFile = $collection.FilePath
        SourceCollectionServer = $sourceCollectionServer
        Notes = $siteInfo.Notes
    }

    foreach ($forwarder in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $json -Names @("Forwarders")))) {
        $forwarders += [pscustomobject]@{
            DnsServer = $serverName
            IPAddress = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $forwarder -Names @("IPAddress", "Target"))
            Order = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $forwarder -Names @("Order"))
            UseRootHint = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $forwarder -Names @("UseRootHint"))
            Timeout = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $forwarder -Names @("Timeout"))
            EnableReordering = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $forwarder -Names @("EnableReordering"))
            SiteName = $siteInfo.SiteName
            SubnetName = $siteInfo.SubnetName
            SourceCollectionServer = $sourceCollectionServer
        }
    }

    foreach ($conditionalForwarder in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $json -Names @("ConditionalForwarders")))) {
        $conditionalForwarders += [pscustomobject]@{
            DnsServer = $serverName
            ZoneName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("ZoneName", "Name"))
            MasterServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("MasterServers", "IPAddress"))
            ReplicationScope = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("ReplicationScope"))
            DirectoryPartitionName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("DirectoryPartitionName", "DirectoryPartition"))
            SiteName = $siteInfo.SiteName
            SubnetName = $siteInfo.SubnetName
            SourceCollectionServer = $sourceCollectionServer
        }
    }

    foreach ($rootHint in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $json -Names @("RootHints")))) {
        $rootHints += [pscustomobject]@{
            DnsServer = $serverName
            NameServer = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $rootHint -Names @("NameServer", "HostName", "Name"))
            IPAddresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $rootHint -Names @("IPAddresses", "IPAddress"))
            SiteName = $siteInfo.SiteName
            SubnetName = $siteInfo.SubnetName
            SourceCollectionServer = $sourceCollectionServer
        }
    }

    foreach ($recordSummary in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $json -Names @("RecordSummary")))) {
        $records += [pscustomobject]@{
            DnsServer = $serverName
            ZoneName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $recordSummary -Names @("ZoneName"))
            RecordType = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $recordSummary -Names @("RecordType"))
            Count = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $recordSummary -Names @("Count"))
            SampleCount = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $recordSummary -Names @("SampleCount"))
            SourceCollectionServer = $sourceCollectionServer
        }
    }

    foreach ($zone in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $json -Names @("Zones")))) {
        $zoneName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ZoneName", "Name"))
        if (-not $zoneName) {
            continue
        }

        $zoneRow = [pscustomobject]@{
            DnsServer = $serverName
            ZoneName = $zoneName
            ZoneType = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ZoneType"))
            IsReverseLookupZone = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("IsReverseLookupZone"))
            IsDsIntegrated = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("IsDsIntegrated"))
            ReplicationScope = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ReplicationScope"))
            DirectoryPartitionName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("DirectoryPartitionName", "DirectoryPartition"))
            DynamicUpdate = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("DynamicUpdate"))
            AgingEnabled = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("AgingEnabled"))
            SecureSecondaries = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("SecureSecondaries"))
            SecondaryServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("SecondaryServers"))
            MasterServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("MasterServers"))
            Notify = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("Notify"))
            NotifyServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("NotifyServers"))
            SiteName = $siteInfo.SiteName
            SubnetName = $siteInfo.SubnetName
            SourceCollectionServer = $sourceCollectionServer
        }
        $zones += $zoneRow

        $existingConditionalForZone = @($conditionalForwarders | Where-Object { $_.DnsServer -eq $serverName -and $_.ZoneName -eq $zoneName })
        if ($zoneRow.ZoneType -match "Forwarder" -and $existingConditionalForZone.Count -eq 0) {
            $conditionalForwarders += [pscustomobject]@{
                DnsServer = $serverName
                ZoneName = $zoneName
                MasterServers = $zoneRow.MasterServers
                ReplicationScope = $zoneRow.ReplicationScope
                DirectoryPartitionName = $zoneRow.DirectoryPartitionName
                SiteName = $siteInfo.SiteName
                SubnetName = $siteInfo.SubnetName
                SourceCollectionServer = $sourceCollectionServer
            }
        }

        foreach ($nsRecord in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("NameServerRecords")))) {
            $nsName = ConvertTo-CsvValue -Value (Get-RecordDataValue -Record $nsRecord -Names @("NameServer", "NameServerName", "DomainName"))
            if ($nsName) {
                $nameServers += [pscustomobject]@{
                    DnsServer = $serverName
                    ZoneName = $zoneName
                    NameServer = $nsName
                    HostName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $nsRecord -Names @("HostName"))
                    SiteName = $siteInfo.SiteName
                    SubnetName = $siteInfo.SubnetName
                    SourceCollectionServer = $sourceCollectionServer
                }
            }
        }

        foreach ($delegation in (ConvertTo-ObjectArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("Delegations")))) {
            $delegations += [pscustomobject]@{
                DnsServer = $serverName
                ParentZoneName = $zoneName
                ChildZoneName = ConvertTo-CsvValue -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("ChildZoneName", "Name", "ZoneName"))
                NameServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("NameServers", "NameServer"))
                IPAddresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("IPAddresses", "IPAddress"))
                SiteName = $siteInfo.SiteName
                SubnetName = $siteInfo.SubnetName
                SourceCollectionServer = $sourceCollectionServer
            }
        }
    }
}

$serverNameLookup = @{}
$serverIpLookup = @{}
foreach ($server in $dnsServers) {
    foreach ($name in @($server.Name, $server.Fqdn, $server.QueriedServer)) {
        foreach ($key in (Get-NameKeys -Name $name)) {
            if ($key -and -not $serverNameLookup.ContainsKey($key)) {
                $serverNameLookup[$key] = $server
            }
        }
    }
    foreach ($ip in @($server.IPAddresses)) {
        if ($ip -and -not $serverIpLookup.ContainsKey($ip)) {
            $serverIpLookup[$ip] = $server
        }
    }
}

$script:edgeCandidates = @()
$script:edgeKeySet = @{}

foreach ($zone in ($zones | Sort-Object DnsServer, ZoneName)) {
    if ($zone.ZoneType -match "Forwarder") {
        continue
    }
    Add-DnsEdgeCandidate -Pass 1 -Source $zone.DnsServer -SourceType "DnsServer" -Relationship "HostsZone" -Target $zone.ZoneName -TargetType "DnsZone" -ZoneName $zone.ZoneName -RecordType "SOA" -Direction "SourceToTarget" -SiteName $zone.SiteName -SubnetName $zone.SubnetName -DnsServer $zone.DnsServer -Status "Discovered" -SourceCollectionServer $zone.SourceCollectionServer -Notes $zone.ZoneType
}

foreach ($forwarder in ($forwarders | Sort-Object DnsServer, Order, IPAddress)) {
    $target = $forwarder.IPAddress
    if (-not $target) {
        continue
    }
    $targetServer = Get-ServerByNameOrIp -Value $target -NameLookup $serverNameLookup -IpLookup $serverIpLookup
    $targetType = "ExternalDns"
    $targetSite = ""
    $targetSubnet = ""
    if ($targetServer) {
        $targetType = "DnsServer"
        $targetSite = $targetServer.SiteName
        $targetSubnet = $targetServer.SubnetName
    }
    Add-DnsEdgeCandidate -Pass 2 -Source $forwarder.DnsServer -SourceType "DnsServer" -Relationship "ForwardsTo" -Target $target -TargetType $targetType -ZoneName "" -RecordType "Forwarder" -Direction "SourceToTarget" -SiteName $forwarder.SiteName -SubnetName $forwarder.SubnetName -TargetSiteName $targetSite -TargetSubnetName $targetSubnet -DnsServer $forwarder.DnsServer -Order $forwarder.Order -Status "Discovered" -SourceCollectionServer $forwarder.SourceCollectionServer -Notes "UseRootHint=$($forwarder.UseRootHint)"
}

foreach ($conditionalForwarder in ($conditionalForwarders | Sort-Object DnsServer, ZoneName)) {
    $masters = @(ConvertTo-StringArray -Value $conditionalForwarder.MasterServers)
    if ($masters.Count -eq 0) {
        $masters = @($conditionalForwarder.ZoneName)
    }
    $order = 0
    foreach ($master in $masters) {
        $order++
        $targetServer = Get-ServerByNameOrIp -Value $master -NameLookup $serverNameLookup -IpLookup $serverIpLookup
        $targetType = if ($targetServer) { "DnsServer" } else { "ExternalDns" }
        $targetSite = if ($targetServer) { $targetServer.SiteName } else { "" }
        $targetSubnet = if ($targetServer) { $targetServer.SubnetName } else { "" }
        Add-DnsEdgeCandidate -Pass 3 -Source $conditionalForwarder.DnsServer -SourceType "DnsServer" -Relationship "ConditionalForwarder" -Target $master -TargetType $targetType -ZoneName $conditionalForwarder.ZoneName -RecordType "ConditionalForwarder" -Direction "SourceToTarget" -SiteName $conditionalForwarder.SiteName -SubnetName $conditionalForwarder.SubnetName -TargetSiteName $targetSite -TargetSubnetName $targetSubnet -DnsServer $conditionalForwarder.DnsServer -Order ([string]$order) -Status "Discovered" -SourceCollectionServer $conditionalForwarder.SourceCollectionServer -Notes $conditionalForwarder.ReplicationScope
    }
}

foreach ($delegation in ($delegations | Sort-Object DnsServer, ParentZoneName, ChildZoneName)) {
    $targets = @(ConvertTo-StringArray -Value $delegation.NameServers)
    if ($targets.Count -eq 0) {
        $targets = @(ConvertTo-StringArray -Value $delegation.IPAddresses)
    }
    if ($targets.Count -eq 0 -and $delegation.ChildZoneName) {
        $targets = @($delegation.ChildZoneName)
    }

    foreach ($target in $targets) {
        Add-DnsEdgeCandidate -Pass 4 -Source $delegation.ParentZoneName -SourceType "DnsZone" -Relationship "DelegatesTo" -Target $target -TargetType "NameServer" -ZoneName $delegation.ChildZoneName -RecordType "NS" -Direction "SourceToTarget" -SiteName $delegation.SiteName -SubnetName $delegation.SubnetName -DnsServer $delegation.DnsServer -Status "Discovered" -SourceCollectionServer $delegation.SourceCollectionServer -Notes "Parent zone: $($delegation.ParentZoneName)"
    }
}

foreach ($nameServer in ($nameServers | Sort-Object DnsServer, ZoneName, NameServer)) {
    $targetServer = Get-ServerByNameOrIp -Value $nameServer.NameServer -NameLookup $serverNameLookup -IpLookup $serverIpLookup
    $targetType = if ($targetServer) { "DnsServer" } else { "NameServer" }
    $targetSite = if ($targetServer) { $targetServer.SiteName } else { "" }
    $targetSubnet = if ($targetServer) { $targetServer.SubnetName } else { "" }
    Add-DnsEdgeCandidate -Pass 5 -Source $nameServer.ZoneName -SourceType "DnsZone" -Relationship "AuthoritativeNS" -Target $nameServer.NameServer -TargetType $targetType -ZoneName $nameServer.ZoneName -RecordType "NS" -Direction "SourceToTarget" -SiteName $nameServer.SiteName -SubnetName $nameServer.SubnetName -TargetSiteName $targetSite -TargetSubnetName $targetSubnet -DnsServer $nameServer.DnsServer -Status "Discovered" -SourceCollectionServer $nameServer.SourceCollectionServer -Notes "Authoritative name server."
}

foreach ($rootHint in ($rootHints | Sort-Object DnsServer, NameServer)) {
    $target = $rootHint.NameServer
    if (-not $target) {
        $target = (ConvertTo-StringArray -Value $rootHint.IPAddresses | Select-Object -First 1)
    }
    if (-not $target) {
        continue
    }
    Add-DnsEdgeCandidate -Pass 6 -Source $rootHint.DnsServer -SourceType "DnsServer" -Relationship "RootHint" -Target $target -TargetType "RootHint" -ZoneName "." -RecordType "NS" -Direction "SourceToTarget" -SiteName $rootHint.SiteName -SubnetName $rootHint.SubnetName -DnsServer $rootHint.DnsServer -Status "Discovered" -SourceCollectionServer $rootHint.SourceCollectionServer -Notes ("IPAddresses=" + ((ConvertTo-StringArray -Value $rootHint.IPAddresses) -join "; "))
}

$dnsEdges = @()
$sortedCandidates = @($script:edgeCandidates | Sort-Object Pass, SortKey)
$edgeCount = $sortedCandidates.Count
$edgeWidth = [Math]::Max(2, ([string]$edgeCount).Length)
$edgeIndex = 0
foreach ($candidate in $sortedCandidates) {
    $edgeIndex++
    $edge = $candidate.Edge
    $edge.DnsEdgeId = "D$($edgeIndex.ToString(("D{0}" -f $edgeWidth)))"
    $dnsEdges += $edge
}

$inventoryMetadata = [ordered]@{
    Source = "DnsMapCollections"
    GeneratedAtUtc = ([DateTime]::UtcNow).ToString("o")
    InputPath = (Resolve-Path -LiteralPath $InputPath).Path
    MetadataPath = if ($MetadataPath) { (Resolve-Path -LiteralPath $MetadataPath).Path } else { $null }
    MetadataOverlay = $metadataOverlay
    CollectionFileCount = $collectionFileEntries.Count
    IncludedDnsCollectionCount = $dnsCollections.Count
    IncludedADSitesCollectionCount = $adCollections.Count
    ParseWarningCount = $parseWarnings.Count
}

$inventory = [pscustomobject]@{
    Metadata = [pscustomobject]$inventoryMetadata
    CollectionFiles = @($collectionFileEntries | ForEach-Object { [pscustomobject]$_ })
    DnsServers = @($dnsServers | Sort-Object SiteName, Name)
    ADSites = $adSites
    ADSubnets = $adSubnets
    ADSiteLinks = $adSiteLinks
    DomainControllers = $domainControllers
    Zones = @($zones | Sort-Object DnsServer, ZoneName)
    Records = @($records | Sort-Object DnsServer, ZoneName, RecordType)
    Forwarders = @($forwarders | Sort-Object DnsServer, Order, IPAddress)
    ConditionalForwarders = @($conditionalForwarders | Sort-Object DnsServer, ZoneName)
    Delegations = @($delegations | Sort-Object DnsServer, ParentZoneName, ChildZoneName)
    NameServers = @($nameServers | Sort-Object DnsServer, ZoneName, NameServer)
    RootHints = @($rootHints | Sort-Object DnsServer, NameServer)
    DnsEdges = $dnsEdges
}

$inventoryJsonPath = Join-Path $outputDirectory.FullName "inventory.json"
$relationshipCsvPath = Join-Path $outputDirectory.FullName "dns-relationship-details.csv"
$zonesCsvPath = Join-Path $outputDirectory.FullName "dns-zones.csv"
$forwardersCsvPath = Join-Path $outputDirectory.FullName "dns-forwarders.csv"
$conditionalForwardersCsvPath = Join-Path $outputDirectory.FullName "dns-conditional-forwarders.csv"
$recordSummaryCsvPath = Join-Path $outputDirectory.FullName "dns-record-summary.csv"
$mermaidPath = Join-Path $outputDirectory.FullName "current-state.mmd"

Write-JsonFile -Path $inventoryJsonPath -InputObject $inventory
Export-CsvRows -Path $relationshipCsvPath -Rows $dnsEdges -Columns $relationshipFields
Export-CsvRows -Path $zonesCsvPath -Rows $inventory.Zones -Columns @("DnsServer", "ZoneName", "ZoneType", "IsReverseLookupZone", "IsDsIntegrated", "ReplicationScope", "DirectoryPartitionName", "DynamicUpdate", "AgingEnabled", "SecureSecondaries", "SecondaryServers", "MasterServers", "Notify", "NotifyServers", "SiteName", "SubnetName", "SourceCollectionServer")
Export-CsvRows -Path $forwardersCsvPath -Rows $inventory.Forwarders -Columns @("DnsServer", "IPAddress", "Order", "UseRootHint", "Timeout", "EnableReordering", "SiteName", "SubnetName", "SourceCollectionServer")
Export-CsvRows -Path $conditionalForwardersCsvPath -Rows $inventory.ConditionalForwarders -Columns @("DnsServer", "ZoneName", "MasterServers", "ReplicationScope", "DirectoryPartitionName", "SiteName", "SubnetName", "SourceCollectionServer")
Export-CsvRows -Path $recordSummaryCsvPath -Rows $inventory.Records -Columns @("DnsServer", "ZoneName", "RecordType", "Count", "SampleCount", "SourceCollectionServer")
Write-MermaidDiagram -Path $mermaidPath -Edges $dnsEdges

[pscustomobject]@{
    InventoryJson = $inventoryJsonPath
    RelationshipCsv = $relationshipCsvPath
    ZonesCsv = $zonesCsvPath
    ForwardersCsv = $forwardersCsvPath
    ConditionalForwardersCsv = $conditionalForwardersCsvPath
    RecordSummaryCsv = $recordSummaryCsvPath
    Mermaid = $mermaidPath
    CollectionFileCount = $collectionFileEntries.Count
    IncludedDnsCollectionCount = $dnsCollections.Count
    IncludedADSitesCollectionCount = $adCollections.Count
    DnsServerCount = @($inventory.DnsServers).Count
    DnsEdgeCount = @($inventory.DnsEdges).Count
    ParseWarningCount = $parseWarnings.Count
}
