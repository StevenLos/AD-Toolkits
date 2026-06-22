[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RawPath,

    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$OutputPath,

    [string]$Name,

    [string]$Title,

    [string]$Subtitle,

    [ValidateSet("Site", "Domain", "SiteAndDomain")]
    [string]$ObjectMode = "Site",

    [ValidateSet("Pairwise", "Hub")]
    [string]$LinkExpansionMode = "Pairwise",

    [string]$PortProfile,

    [switch]$Force,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ObjectMode -ne "Site") {
    throw "Only -ObjectMode Site is implemented for the MVP."
}
if ($LinkExpansionMode -ne "Pairwise") {
    throw "Only -LinkExpansionMode Pairwise is implemented for the MVP."
}

$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $cwdPath = Join-Path (Get-Location) $Path
    if (Test-Path -LiteralPath $cwdPath) {
        return (Resolve-Path -LiteralPath $cwdPath).Path
    }

    return (Join-Path $projectRoot $Path)
}

function ConvertTo-ObjectArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += $item
        }
        return $items
    }
    return @($Value)
}

function Get-PropertyValue {
    param(
        [object]$InputObject,
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
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    if ($Value -is [string]) {
        return $Value.Trim()
    }
    if ($Value -is [bool]) {
        return $Value.ToString()
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $text = ConvertTo-Text -Value $item
            if ($text) {
                $items += $text
            }
        }
        return ($items -join "; ")
    }
    return ([string]$Value).Trim()
}

function ConvertTo-StringList {
    param([object]$Value)

    $textItems = @()
    foreach ($item in (ConvertTo-ObjectArray -Value $Value)) {
        $text = ConvertTo-Text -Value $item
        if ($text) {
            foreach ($part in ($text -split ';')) {
                $trimmed = $part.Trim()
                if ($trimmed) {
                    $textItems += $trimmed
                }
            }
        }
    }

    return @($textItems | Select-Object -Unique)
}

function ConvertFrom-DistinguishedNameName {
    param([string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return ""
    }
    if ($DistinguishedName -match '^CN=([^,]+)') {
        return ($Matches[1] -replace '\\,', ',')
    }
    return $DistinguishedName
}

function ConvertTo-SafeIdSegment {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value.ToUpperInvariant() -replace '[^A-Z0-9]+', '-'
    $safe = $safe.Trim("-")
    if (-not $safe) {
        return "UNKNOWN"
    }
    return $safe
}

function ConvertTo-Note {
    param([string[]]$Parts)

    return (($Parts | Where-Object { $_ -and $_.Trim() }) -join " ")
}

function Write-GeneratedCsv {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Columns
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "Output file already exists. Pass -Force to overwrite: $Path"
    }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    if ($Rows.Count -eq 0 -and $Columns) {
        Set-Content -LiteralPath $Path -Value ($Columns -join ",") -Encoding UTF8
        return
    }
    if ($Columns) {
        $Rows | Select-Object -Property $Columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
}

function ConvertTo-ProjectRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($projectRoot)
    if (-not $resolvedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $resolvedRoot = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    if ($resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedPath.Substring($resolvedRoot.Length).Replace([System.IO.Path]::DirectorySeparatorChar, "/")
    }

    return $Path
}

function Get-DefaultPortProfile {
    $rows = @(
        [pscustomobject]@{ Protocol = "TCP"; Port = "53"; Service = "DNS"; Purpose = "DNS queries and large DNS responses where TCP is required." }
        [pscustomobject]@{ Protocol = "UDP"; Port = "53"; Service = "DNS"; Purpose = "Standard DNS queries." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "88"; Service = "Kerberos"; Purpose = "Kerberos authentication." }
        [pscustomobject]@{ Protocol = "UDP"; Port = "88"; Service = "Kerberos"; Purpose = "Kerberos authentication." }
        [pscustomobject]@{ Protocol = "UDP"; Port = "123"; Service = "NTP"; Purpose = "Time synchronization required for Kerberos clock-skew tolerance." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "135"; Service = "RPC Endpoint Mapper"; Purpose = "RPC endpoint discovery." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "389"; Service = "LDAP"; Purpose = "Directory lookup and LDAP operations." }
        [pscustomobject]@{ Protocol = "UDP"; Port = "389"; Service = "LDAP"; Purpose = "LDAP locator and related operations where required." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "445"; Service = "SMB"; Purpose = "SYSVOL, NETLOGON, and file-based domain services where required." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "464"; Service = "Kerberos Password Change"; Purpose = "Kerberos password change." }
        [pscustomobject]@{ Protocol = "UDP"; Port = "464"; Service = "Kerberos Password Change"; Purpose = "Kerberos password change." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "636"; Service = "LDAPS"; Purpose = "Secure LDAP where used." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "3268"; Service = "Global Catalog"; Purpose = "Global Catalog LDAP." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "3269"; Service = "Global Catalog SSL"; Purpose = "Secure Global Catalog LDAP." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "9389"; Service = "AD Web Services"; Purpose = "ADWS access for AD PowerShell discovery and management tooling where required." }
        [pscustomobject]@{ Protocol = "TCP"; Port = "49152-65535"; Service = "Dynamic RPC"; Purpose = "Modern Windows dynamic RPC range, configurable." }
    )

    return $rows
}

function Read-PortProfile {
    param([string]$Profile)

    if ($Profile -and $Profile -ne "default-ad-ds") {
        $profilePath = Resolve-ProjectPath -Path $Profile
        if (Test-Path -LiteralPath $profilePath) {
            $rows = @(Import-Csv -LiteralPath $profilePath)
            foreach ($row in $rows) {
                foreach ($column in @("Protocol", "Port", "Service", "Purpose")) {
                    if (-not $row.PSObject.Properties[$column]) {
                        throw "Custom port profile is missing required column '$column': $profilePath"
                    }
                }
            }
            return $rows
        }
        throw "PortProfile must be 'default-ad-ds' or a CSV path. Not found: $Profile"
    }

    return @(Get-DefaultPortProfile)
}

$rawDirectory = Resolve-ProjectPath -Path $RawPath
if (-not (Test-Path -LiteralPath $rawDirectory)) {
    throw "RawPath not found: $rawDirectory"
}
$inputDirectory = Resolve-ProjectPath -Path $InputPath
$outputDirectory = if ($OutputPath) { Resolve-ProjectPath -Path $OutputPath } else { Join-Path (Split-Path -Parent $inputDirectory) "output" }
New-Item -ItemType Directory -Path $inputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$collectionFiles = @(Get-ChildItem -LiteralPath $rawDirectory -File -Filter "*.sites.collection.json" | Sort-Object Name)
if ($collectionFiles.Count -eq 0) {
    $collectionFiles = @(Get-ChildItem -LiteralPath $rawDirectory -File -Filter "*.json" | Sort-Object Name)
}
if ($collectionFiles.Count -eq 0) {
    throw "No AD Sites collection JSON files were found in RawPath: $rawDirectory"
}

$collections = @()
foreach ($file in $collectionFiles) {
    $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    if (-not (Get-PropertyValue -InputObject $json -Names @("ADSites"))) {
        Write-Warning "Skipping JSON file without ADSites: $($file.FullName)"
        continue
    }
    $collections += [pscustomobject]@{
        Path = $file.FullName
        Json = $json
    }
}
if ($collections.Count -eq 0) {
    throw "No usable AD Sites collection JSON files were found in RawPath: $rawDirectory"
}

$settingsPath = Join-Path (Split-Path -Parent $inputDirectory) "discovery-settings.csv"
$environmentDefault = "Production"
$providerDefault = "On-Premises"
$zoneDefault = "Directory Services"
if (Test-Path -LiteralPath $settingsPath) {
    foreach ($setting in @(Import-Csv -LiteralPath $settingsPath)) {
        if ($setting.Setting -eq "EnvironmentDefault" -and $setting.Value) { $environmentDefault = $setting.Value }
        if ($setting.Setting -eq "ProviderDefault" -and $setting.Value) { $providerDefault = $setting.Value }
        if ($setting.Setting -eq "ZoneDefault" -and $setting.Value) { $zoneDefault = $setting.Value }
        if (-not $PortProfile -and $setting.Setting -eq "PortProfile" -and $setting.Value) { $PortProfile = $setting.Value }
    }
}

$warnings = @()
$siteMap = [ordered]@{}
$subnets = @()
$siteLinks = @()
$domainControllers = @()
$replicationConnections = @()
$replicationPartnerMetadata = @()
$replicationFailures = @()
$replicationTopologyEdges = @()
$replicationHealthSummary = @()
$forestNames = @()
$domainNames = @()

foreach ($collection in $collections) {
    $metadata = Get-PropertyValue -InputObject $collection.Json -Names @("Metadata")
    $forest = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Names @("ForestName"))
    $domain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Names @("DomainName"))
    if ($forest) { $forestNames += $forest }
    if ($domain) { $domainNames += $domain }

    foreach ($site in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ADSites")))) {
        $siteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $site -Names @("SiteName", "Name"))
        if (-not $siteName) {
            $warnings += "Skipped site row without a SiteName from $($collection.Path)."
            continue
        }
        if (-not $siteMap.Contains($siteName)) {
            $siteMap[$siteName] = $site
        }
    }

    foreach ($subnet in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ADSubnets", "Subnets")))) {
        $subnets += $subnet
    }
    foreach ($siteLink in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ADSiteLinks", "SiteLinks")))) {
        $siteLinks += $siteLink
    }
    foreach ($dc in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("DomainControllers")))) {
        $domainControllers += $dc
    }
    foreach ($row in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ReplicationConnections")))) {
        $replicationConnections += $row
    }
    foreach ($row in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ReplicationPartnerMetadata")))) {
        $replicationPartnerMetadata += $row
    }
    foreach ($row in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ReplicationFailures")))) {
        $replicationFailures += $row
    }
    foreach ($row in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ReplicationTopologyEdges")))) {
        $replicationTopologyEdges += $row
    }
    foreach ($row in (ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collection.Json -Names @("ReplicationHealthSummary")))) {
        $replicationHealthSummary += $row
    }
}

$siteNames = @($siteMap.Keys | Sort-Object)
if ($siteNames.Count -eq 0) {
    throw "No AD sites were found in the collection JSON files."
}

$siteIdMap = @{}
$usedIds = @{}
foreach ($siteName in $siteNames) {
    $baseId = "SITE-" + (ConvertTo-SafeIdSegment -Value $siteName)
    $candidate = $baseId
    $suffix = 2
    while ($usedIds.ContainsKey($candidate)) {
        $candidate = "$baseId-$suffix"
        $suffix++
    }
    $usedIds[$candidate] = $true
    $siteIdMap[$siteName] = $candidate
}

$subnetsBySite = @{}
foreach ($siteName in $siteNames) {
    $subnetsBySite[$siteName] = @()
}
foreach ($subnet in $subnets) {
    $subnetName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("SubnetName", "Name", "Cidr"))
    $siteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("SiteName"))
    if (-not $siteName) {
        $siteDn = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Site", "SiteDistinguishedName"))
        $siteName = ConvertFrom-DistinguishedNameName -DistinguishedName $siteDn
    }
    if ($siteName -and $subnetsBySite.ContainsKey($siteName)) {
        $subnetsBySite[$siteName] += $subnetName
    }
    elseif ($subnetName) {
        $warnings += "Subnet '$subnetName' has no known site assignment."
    }
}

$dcsBySite = @{}
foreach ($siteName in $siteNames) {
    $dcsBySite[$siteName] = @()
}
foreach ($dc in $domainControllers) {
    $siteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("SiteName", "Site"))
    $hostName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
    if ($siteName -and $dcsBySite.ContainsKey($siteName)) {
        $dcsBySite[$siteName] += $dc
    }
    elseif ($hostName) {
        $warnings += "Domain controller '$hostName' maps to unknown site '$siteName'."
    }
}

$diagramObjects = @()
$displayOrder = 1
foreach ($siteName in $siteNames) {
    $site = $siteMap[$siteName]
    $siteSubnets = @($subnetsBySite[$siteName] | Where-Object { $_ } | Sort-Object -Unique)
    $siteDcs = @($dcsBySite[$siteName])
    $description = ConvertTo-Text -Value (Get-PropertyValue -InputObject $site -Names @("Description"))
    $distinguishedName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $site -Names @("DistinguishedName"))
    if ($siteSubnets.Count -eq 0) {
        $warnings += "Site '$siteName' has no assigned subnets."
    }
    if ($siteDcs.Count -eq 0) {
        $warnings += "Site '$siteName' has no discovered domain controllers. This can be expected when automatic site coverage is in use."
    }
    $networkCidr = ($siteSubnets -join "; ")
    if ($networkCidr.Length -gt 180) {
        $networkCidr = "$($siteSubnets.Count) assigned subnets"
    }
    $diagramObjects += [pscustomobject]@{
        ObjectId = $siteIdMap[$siteName]
        ObjectName = $siteName
        ObjectType = "ADSite"
        DisplayLabel = $siteName
        Group = "Active Directory Sites"
        Location = ConvertTo-Text -Value (Get-PropertyValue -InputObject $site -Names @("Location"))
        Environment = $environmentDefault
        Zone = $zoneDefault
        NetworkCidr = $networkCidr
        Provider = $providerDefault
        Role = "AD replication site"
        DisplayOrder = $displayOrder
        Notes = ConvertTo-Note -Parts @($description, "Subnets: $($siteSubnets.Count).", "Domain controllers: $($siteDcs.Count).", "DN: $distinguishedName")
    }
    $displayOrder++
}

$pairMap = @{}
$contributorMap = @{}
foreach ($siteLink in $siteLinks) {
    $linkName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $siteLink -Names @("SiteLinkName", "Name"))
    if (-not $linkName) {
        $linkName = "Unnamed site link"
    }
    $sitesIncludedRaw = Get-PropertyValue -InputObject $siteLink -Names @("SitesIncluded", "Sites")
    $sitesIncluded = @()
    foreach ($siteValue in (ConvertTo-StringList -Value $sitesIncludedRaw)) {
        if ($siteValue -match '^CN=') {
            $sitesIncluded += ConvertFrom-DistinguishedNameName -DistinguishedName $siteValue
        }
        else {
            $sitesIncluded += $siteValue
        }
    }
    $sitesIncluded = @($sitesIncluded | Where-Object { $_ } | Select-Object -Unique)
    $knownSites = @($sitesIncluded | Where-Object { $siteIdMap.ContainsKey($_) } | Sort-Object)
    $unknownSites = @($sitesIncluded | Where-Object { -not $siteIdMap.ContainsKey($_) })
    foreach ($unknownSite in $unknownSites) {
        $warnings += "Site link '$linkName' references unknown site '$unknownSite'."
    }
    if ($knownSites.Count -lt 2) {
        $warnings += "Site link '$linkName' references fewer than two known sites and was skipped."
        continue
    }

    $transport = ConvertTo-Text -Value (Get-PropertyValue -InputObject $siteLink -Names @("Transport", "InterSiteTransportProtocol"))
    if (-not $transport) { $transport = "IP" }
    $cost = ConvertTo-Text -Value (Get-PropertyValue -InputObject $siteLink -Names @("Cost"))
    $frequency = ConvertTo-Text -Value (Get-PropertyValue -InputObject $siteLink -Names @("ReplicationFrequencyInMinutes"))
    $dn = ConvertTo-Text -Value (Get-PropertyValue -InputObject $siteLink -Names @("DistinguishedName"))
    if (-not $frequency) {
        $warnings += "Site link '$linkName' has no replication frequency."
    }

    for ($i = 0; $i -lt $knownSites.Count; $i++) {
        for ($j = $i + 1; $j -lt $knownSites.Count; $j++) {
            $siteA = $knownSites[$i]
            $siteB = $knownSites[$j]
            $idA = $siteIdMap[$siteA]
            $idB = $siteIdMap[$siteB]
            $ids = @($idA, $idB) | Sort-Object
            $pairKey = "$($ids[0])|$($ids[1])"
            if (-not $pairMap.ContainsKey($pairKey)) {
                $pairMap[$pairKey] = [pscustomobject]@{
                    SourceObjectId = $ids[0]
                    TargetObjectId = $ids[1]
                }
                $contributorMap[$pairKey] = @()
            }
            $contributorMap[$pairKey] += [pscustomobject]@{
                SiteLinkName = $linkName
                Transport = $transport
                Cost = $cost
                ReplicationFrequencyInMinutes = $frequency
                SitesIncluded = ($knownSites -join "; ")
                DistinguishedName = $dn
            }
        }
    }
}

$lineOfSightLinks = @()
foreach ($pairKey in ($pairMap.Keys | Sort-Object)) {
    $pair = $pairMap[$pairKey]
    $contributors = @($contributorMap[$pairKey])
    $contributorNames = @($contributors | ForEach-Object { $_.SiteLinkName } | Sort-Object -Unique)
    $label = if ($contributorNames.Count -eq 1) { $contributorNames[0] } else { "Multiple site links ($($contributorNames.Count))" }
    $lineOfSightLinks += [pscustomobject]@{
        LineOfSightId = "LOS-$($pair.SourceObjectId)-$($pair.TargetObjectId)"
        SourceObjectId = $pair.SourceObjectId
        TargetObjectId = $pair.TargetObjectId
        Direction = "Bidirectional"
        Label = $label
        Status = "Discovered"
        Notes = "Derived from AD site link configuration; not proof of active bridgehead replication. Contributors: " + (($contributors | ForEach-Object { "$($_.SiteLinkName) [$($_.Transport), cost $($_.Cost), every $($_.ReplicationFrequencyInMinutes) min]" }) -join "; ")
    }
}
if ($lineOfSightLinks.Count -eq 0) {
    $warnings += "No line-of-sight links were generated from AD site links."
}

$portProfileRows = @(Read-PortProfile -Profile $PortProfile)
$portsProtocols = @()
foreach ($link in $lineOfSightLinks) {
    $index = 1
    foreach ($portRow in $portProfileRows) {
        $portsProtocols += [pscustomobject]@{
            RequirementId = "PORT-$($link.LineOfSightId)-" + $index.ToString("00")
            LineOfSightId = $link.LineOfSightId
            Protocol = ConvertTo-Text -Value (Get-PropertyValue -InputObject $portRow -Names @("Protocol"))
            Port = ConvertTo-Text -Value (Get-PropertyValue -InputObject $portRow -Names @("Port"))
            Service = ConvertTo-Text -Value (Get-PropertyValue -InputObject $portRow -Names @("Service"))
            Purpose = ConvertTo-Text -Value (Get-PropertyValue -InputObject $portRow -Names @("Purpose"))
            Direction = "Bidirectional"
            Required = "Review"
            Status = "ReviewRequired"
            Notes = "Firewall review starting point. Validate actual required scope before implementing."
        }
        $index++
    }
}

$dcExpansion = @()
$compatDcExpansion = @()
$dcIndex = 1
foreach ($dc in ($domainControllers | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SiteName", "Site")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("HostName", "DNSHostName", "Name")) })) {
    $siteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("SiteName", "Site"))
    if (-not $siteIdMap.ContainsKey($siteName)) {
        continue
    }
    $hostName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
    $ipAddress = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("IPv4Addresses", "IPv4Address"))
    $isGc = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("IsGlobalCatalog"))
    $isRodc = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("IsReadOnly"))
    $roleNotes = @()
    if ($isGc -eq "True") { $roleNotes += "Global Catalog" }
    if ($isRodc -eq "True") { $roleNotes += "RODC" }
    if (-not $ipAddress) {
        $warnings += "Domain controller '$hostName' has no resolved IP address."
    }
    $domainName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("Domain"))
    if (-not $domainName) {
        $domainName = @($domainNames | Sort-Object -Unique | Select-Object -First 1)
    }
    $dcExpansion += [pscustomobject]@{
        ExpansionId = "DC-" + $dcIndex.ToString("000")
        SiteObjectId = $siteIdMap[$siteName]
        SiteName = $siteName
        DomainName = $domainName
        ServerName = $hostName
        ServerRole = "Domain Controller"
        Environment = $environmentDefault
        Location = ""
        NetworkZone = $zoneDefault
        IpAddress = $ipAddress
        IsGlobalCatalog = $isGc
        IsReadOnly = $isRodc
        OperatingSystem = ConvertTo-Text -Value (Get-PropertyValue -InputObject $dc -Names @("OperatingSystem"))
        InScope = "Yes"
        Status = "Discovered"
        Notes = ($roleNotes -join "; ")
    }
    $compatDcExpansion += [pscustomobject]@{
        DomainObjectId = $siteIdMap[$siteName]
        DomainName = $siteName
        ServerName = $hostName
        ServerRole = "Domain Controller"
        Environment = $environmentDefault
        Location = ""
        NetworkZone = $zoneDefault
        IpAddress = $ipAddress
        InScope = "Yes"
        Status = "Discovered"
        Notes = ($roleNotes -join "; ")
    }
    $dcIndex++
}

$subnetRows = @()
$subnetIndex = 1
foreach ($subnet in ($subnets | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SiteName")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SubnetName", "Name", "Cidr")) })) {
    $subnetName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("SubnetName", "Name", "Cidr"))
    $siteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("SiteName"))
    if (-not $siteName) {
        $siteName = ConvertFrom-DistinguishedNameName -DistinguishedName (ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Site", "SiteDistinguishedName")))
    }
    $siteObjectId = if ($siteIdMap.ContainsKey($siteName)) { $siteIdMap[$siteName] } else { "" }
    $subnetRows += [pscustomobject]@{
        SubnetId = "SUBNET-" + $subnetIndex.ToString("000")
        SiteObjectId = $siteObjectId
        SiteName = $siteName
        SubnetName = $subnetName
        Cidr = if ((ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Cidr")))) { ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Cidr")) } else { $subnetName }
        Location = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Location"))
        Description = ConvertTo-Text -Value (Get-PropertyValue -InputObject $subnet -Names @("Description"))
        InScope = if ($siteObjectId) { "Yes" } else { "Review" }
        Status = "Discovered"
        Notes = if ($siteObjectId) { "" } else { "Subnet is not assigned to a known AD site." }
    }
    $subnetIndex++
}

$replicationConnectionRows = @()
foreach ($row in ($replicationConnections | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SourceServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("DestinationServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("ConnectionName")) })) {
    $replicationConnectionRows += [pscustomobject]@{
        ConnectionId = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConnectionId"))
        ConnectionName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConnectionName"))
        SourceServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceServer"))
        SourceSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceSite"))
        DestinationServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationServer"))
        DestinationSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationSite"))
        Transport = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Transport"))
        Enabled = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Enabled"))
        AutoGenerated = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("AutoGenerated"))
        Options = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Options"))
        Schedule = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Schedule"))
        DistinguishedName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DistinguishedName"))
        WhenCreated = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("WhenCreated"))
        WhenChanged = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("WhenChanged"))
        Notes = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Notes"))
    }
}

$replicationPartnerMetadataRows = @()
foreach ($row in ($replicationPartnerMetadata | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SourceServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("DestinationServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("NamingContext")) })) {
    $replicationPartnerMetadataRows += [pscustomobject]@{
        MetadataId = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("MetadataId"))
        Direction = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Direction"))
        SourceServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceServer"))
        SourceSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceSite"))
        DestinationServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationServer"))
        DestinationSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationSite"))
        NamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("NamingContext"))
        LastSuccess = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastSuccess"))
        LastFailure = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastFailure"))
        ConsecutiveFailureCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConsecutiveFailureCount"))
        ResultCode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultCode"))
        ResultMessage = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultMessage"))
        Transport = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Transport"))
        PartnerAddress = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("PartnerAddress"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Status"))
        Notes = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Notes"))
    }
}

$replicationFailureRows = @()
foreach ($row in ($replicationFailures | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("DestinationServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SourceServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("NamingContext")) })) {
    $replicationFailureRows += [pscustomobject]@{
        FailureId = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("FailureId"))
        SourceServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceServer"))
        SourceSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceSite"))
        DestinationServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationServer"))
        DestinationSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationSite"))
        NamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("NamingContext"))
        FirstFailure = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("FirstFailure"))
        LastFailure = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastFailure"))
        ConsecutiveFailureCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConsecutiveFailureCount"))
        ResultCode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultCode"))
        ResultMessage = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultMessage"))
        FailureType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("FailureType"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Status"))
        Notes = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Notes"))
    }
}

$replicationTopologyRows = @()
$rplIndex = 1
foreach ($row in ($replicationTopologyEdges | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("EvidenceType")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SourceServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("DestinationServer")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("NamingContext")) })) {
    $edgeId = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ReplicationEdgeId", "EdgeId"))
    if (-not $edgeId) {
        $edgeId = "RPL" + $rplIndex.ToString("000")
    }
    $replicationTopologyRows += [pscustomobject]@{
        ReplicationEdgeId = $edgeId
        EvidenceType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("EvidenceType"))
        SourceServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceServer"))
        SourceSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SourceSite"))
        DestinationServer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationServer"))
        DestinationSite = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DestinationSite"))
        NamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("NamingContext"))
        Transport = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Transport"))
        LastSuccess = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastSuccess"))
        LastFailure = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastFailure"))
        ConsecutiveFailureCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConsecutiveFailureCount"))
        ResultCode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultCode"))
        ResultMessage = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ResultMessage"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Status"))
        EvidenceId = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("EvidenceId"))
        Notes = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Notes"))
    }
    $rplIndex++
}

$replicationHealthRows = @()
foreach ($row in ($replicationHealthSummary | Sort-Object { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("SiteName")) }, { ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Names @("DomainController")) })) {
    $replicationHealthRows += [pscustomobject]@{
        DomainController = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("DomainController"))
        SiteName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("SiteName"))
        PartnerMetadataCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("PartnerMetadataCount"))
        ConfiguredConnectionCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("ConfiguredConnectionCount"))
        FailureCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("FailureCount"))
        QueueOperationCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("QueueOperationCount"))
        LastSuccess = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastSuccess"))
        LastFailure = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("LastFailure"))
        Status = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Status"))
        Notes = ConvertTo-Text -Value (Get-PropertyValue -InputObject $row -Names @("Notes"))
    }
}

$diagramInputsPath = Join-Path (Split-Path -Parent $inputDirectory) "diagram-inputs.csv"
if (-not (Test-Path -LiteralPath $diagramInputsPath)) {
    $manifestRows = @(
        [pscustomobject]@{ Setting = "Name"; Value = $(if ($Name) { $Name } else { "ad-sites-diagram" }); Notes = "Used for output file names" }
        [pscustomobject]@{ Setting = "Title"; Value = $(if ($Title) { $Title } else { "Active Directory Sites And Services Diagram" }); Notes = "Shown at the top of the generated SVG" }
        [pscustomobject]@{ Setting = "Subtitle"; Value = $(if ($Subtitle) { $Subtitle } else { "AD sites site links domain controllers and supporting network review tables" }); Notes = "Shown under the title in the generated SVG" }
        [pscustomobject]@{ Setting = "InputPath"; Value = $InputPath; Notes = "Folder containing normalized diagram CSV files" }
        [pscustomobject]@{ Setting = "OutputPath"; Value = $(if ($OutputPath) { $OutputPath } else { (Join-Path (Split-Path -Parent $InputPath) "output") }); Notes = "Folder where generated SVG and inventory JSON are written" }
        [pscustomobject]@{ Setting = "ObjectsCsv"; Value = "diagram-objects.csv"; Notes = "Relative to InputPath unless rooted" }
        [pscustomobject]@{ Setting = "LineOfSightLinksCsv"; Value = "line-of-sight-links.csv"; Notes = "Relative to InputPath unless rooted" }
        [pscustomobject]@{ Setting = "PortsProtocolsCsv"; Value = "ports-protocols.csv"; Notes = "Relative to InputPath unless rooted" }
        [pscustomobject]@{ Setting = "ExpansionCsv"; Value = "ad-site-domain-controller-expansion.csv"; Notes = "Preferred AD Sites expansion CSV" }
        [pscustomobject]@{ Setting = "SubnetsCsv"; Value = "ad-site-subnets.csv"; Notes = "AD subnet support table CSV" }
        [pscustomobject]@{ Setting = "ReplicationConnectionsCsv"; Value = "replication-connections.csv"; Notes = "Configured replication connection objects" }
        [pscustomobject]@{ Setting = "ReplicationPartnerMetadataCsv"; Value = "replication-partner-metadata.csv"; Notes = "Observed replication partner metadata" }
        [pscustomobject]@{ Setting = "ReplicationFailuresCsv"; Value = "replication-failures.csv"; Notes = "Observed replication failures" }
        [pscustomobject]@{ Setting = "ReplicationTopologyEdgesCsv"; Value = "replication-topology-edges.csv"; Notes = "Configured and observed replication topology evidence" }
        [pscustomobject]@{ Setting = "ReplicationHealthSummaryCsv"; Value = "replication-health-summary.csv"; Notes = "Per-domain-controller replication health summary" }
        [pscustomobject]@{ Setting = "AdDomainServerExpansionCsv"; Value = "ad-domain-server-expansion.csv"; Notes = "Compatibility CSV for older sample renderer patterns" }
        [pscustomobject]@{ Setting = "LayoutMode"; Value = "ring"; Notes = "AD Sites MVP uses ring layout" }
        [pscustomobject]@{ Setting = "DenseLinkThreshold"; Value = "20"; Notes = "Hide inline link labels above this link count" }
        [pscustomobject]@{ Setting = "DenseSiteThreshold"; Value = "15"; Notes = "Hide inline link labels above this site count" }
        [pscustomobject]@{ Setting = "PythonCommand"; Value = ""; Notes = "Optional path or command name for Python 3" }
    )
    Write-GeneratedCsv -Rows $manifestRows -Path $diagramInputsPath
}

$objectsPath = Join-Path $inputDirectory "diagram-objects.csv"
$linksPath = Join-Path $inputDirectory "line-of-sight-links.csv"
$portsPath = Join-Path $inputDirectory "ports-protocols.csv"
$dcPath = Join-Path $inputDirectory "ad-site-domain-controller-expansion.csv"
$subnetsPath = Join-Path $inputDirectory "ad-site-subnets.csv"
$compatPath = Join-Path $inputDirectory "ad-domain-server-expansion.csv"
$replicationConnectionsPath = Join-Path $inputDirectory "replication-connections.csv"
$replicationPartnerMetadataPath = Join-Path $inputDirectory "replication-partner-metadata.csv"
$replicationFailuresPath = Join-Path $inputDirectory "replication-failures.csv"
$replicationTopologyPath = Join-Path $inputDirectory "replication-topology-edges.csv"
$replicationHealthPath = Join-Path $inputDirectory "replication-health-summary.csv"

Write-GeneratedCsv -Rows $diagramObjects -Path $objectsPath
Write-GeneratedCsv -Rows $lineOfSightLinks -Path $linksPath
Write-GeneratedCsv -Rows $portsProtocols -Path $portsPath
Write-GeneratedCsv -Rows $dcExpansion -Path $dcPath
Write-GeneratedCsv -Rows $subnetRows -Path $subnetsPath
Write-GeneratedCsv -Rows $compatDcExpansion -Path $compatPath
Write-GeneratedCsv -Rows $replicationConnectionRows -Path $replicationConnectionsPath -Columns @("ConnectionId", "ConnectionName", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "Transport", "Enabled", "AutoGenerated", "Options", "Schedule", "DistinguishedName", "WhenCreated", "WhenChanged", "Notes")
Write-GeneratedCsv -Rows $replicationPartnerMetadataRows -Path $replicationPartnerMetadataPath -Columns @("MetadataId", "Direction", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "LastSuccess", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "Transport", "PartnerAddress", "Status", "Notes")
Write-GeneratedCsv -Rows $replicationFailureRows -Path $replicationFailuresPath -Columns @("FailureId", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "FirstFailure", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "FailureType", "Status", "Notes")
Write-GeneratedCsv -Rows $replicationTopologyRows -Path $replicationTopologyPath -Columns @("ReplicationEdgeId", "EvidenceType", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "Transport", "LastSuccess", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "Status", "EvidenceId", "Notes")
Write-GeneratedCsv -Rows $replicationHealthRows -Path $replicationHealthPath -Columns @("DomainController", "SiteName", "PartnerMetadataCount", "ConfiguredConnectionCount", "FailureCount", "QueueOperationCount", "LastSuccess", "LastFailure", "Status", "Notes")

$summary = [ordered]@{
    GeneratedUtc = [DateTime]::UtcNow.ToString("o")
    SourceFiles = @($collections.Path | ForEach-Object { ConvertTo-ProjectRelativePath -Path $_ })
    ForestNames = @($forestNames | Sort-Object -Unique)
    DomainNames = @($domainNames | Sort-Object -Unique)
    Counts = [ordered]@{
        Sites = $diagramObjects.Count
        SiteLinksRaw = $siteLinks.Count
        LineOfSightLinks = $lineOfSightLinks.Count
        PortsProtocols = $portsProtocols.Count
        DomainControllers = $dcExpansion.Count
        Subnets = $subnetRows.Count
        ReplicationConnections = $replicationConnectionRows.Count
        ReplicationPartnerMetadata = $replicationPartnerMetadataRows.Count
        ReplicationFailures = $replicationFailureRows.Count
        ReplicationTopologyEdges = $replicationTopologyRows.Count
        ReplicationHealthSummary = $replicationHealthRows.Count
        Warnings = $warnings.Count
    }
    LineOfSightContributors = [ordered]@{}
    Warnings = @($warnings)
}
foreach ($pairKey in ($contributorMap.Keys | Sort-Object)) {
    $pair = $pairMap[$pairKey]
    $summary.LineOfSightContributors["LOS-$($pair.SourceObjectId)-$($pair.TargetObjectId)"] = @($contributorMap[$pairKey])
}
$summaryPath = Join-Path $outputDirectory "transform-summary.json"
if ((Test-Path -LiteralPath $summaryPath) -and -not $Force) {
    throw "Output file already exists. Pass -Force to overwrite: $summaryPath"
}
([pscustomobject]$summary) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

foreach ($warning in $warnings) {
    Write-Warning $warning
}

$result = [pscustomobject]@{
    InputPath = $inputDirectory
    OutputPath = $outputDirectory
    ObjectsCsv = $objectsPath
    LineOfSightLinksCsv = $linksPath
    PortsProtocolsCsv = $portsPath
    ExpansionCsv = $dcPath
    SubnetsCsv = $subnetsPath
    ReplicationConnectionsCsv = $replicationConnectionsPath
    ReplicationPartnerMetadataCsv = $replicationPartnerMetadataPath
    ReplicationFailuresCsv = $replicationFailuresPath
    ReplicationTopologyEdgesCsv = $replicationTopologyPath
    ReplicationHealthSummaryCsv = $replicationHealthPath
    CompatibilityExpansionCsv = $compatPath
    DiagramInputsCsv = $diagramInputsPath
    TransformSummaryJson = $summaryPath
    SiteCount = $diagramObjects.Count
    LineOfSightLinkCount = $lineOfSightLinks.Count
    DomainControllerCount = $dcExpansion.Count
    SubnetCount = $subnetRows.Count
    ReplicationTopologyEdgeCount = $replicationTopologyRows.Count
    ReplicationFailureCount = $replicationFailureRows.Count
    WarningCount = $warnings.Count
}

if ($PassThru) {
    $result
}
else {
    $result | Format-List
}
