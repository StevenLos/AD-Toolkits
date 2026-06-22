#requires -Version 5.1
<#
.SYNOPSIS
Merges AD forest configuration collection bundles into inventory and CSV outputs.

.DESCRIPTION
Offline aggregation. Reads *.forest-config.collection.json files and writes
inventory.json, review CSVs, relationship CSV, findings, and a simple Mermaid
diagram under output/01-merged-inventory.
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

$ForestSummaryFields = @(
    "ForestName",
    "RootDomain",
    "ForestMode",
    "ForestModeLevel",
    "SchemaMaster",
    "DomainNamingMaster",
    "ConfigurationNamingContext",
    "SchemaNamingContext",
    "RootDomainNamingContext",
    "PartitionsContainer",
    "DomainCount",
    "SiteCount",
    "GlobalCatalogCount",
    "UpnSuffixes",
    "SpnSuffixes",
    "TombstoneLifetimeDays",
    "DeletedObjectLifetimeDays",
    "CollectionStatus",
    "SourceCollection",
    "Notes"
)

$DomainSummaryFields = @(
    "ForestName",
    "DnsRoot",
    "NetBIOSName",
    "DomainMode",
    "DomainModeLevel",
    "DistinguishedName",
    "ParentDomain",
    "ChildDomains",
    "PDCEmulator",
    "RIDMaster",
    "InfrastructureMaster",
    "ReplicaDirectoryServers",
    "ReadOnlyReplicaDirectoryServers",
    "DomainControllerCount",
    "GlobalCatalogCount",
    "MachineAccountQuota",
    "NTMixedDomain",
    "SourceCollection",
    "Notes"
)

$SchemaSummaryFields = @(
    "ForestName",
    "SchemaNamingContext",
    "ObjectVersion",
    "ProductHint",
    "SchemaMaster",
    "SchemaWhenCreated",
    "SchemaWhenChanged",
    "SchemaUpdateAllowed",
    "SourceCollection",
    "Notes"
)

$NamingContextFields = @(
    "NamingContext",
    "Type",
    "DnsRoot",
    "NetBIOSName",
    "Enabled",
    "IsRootDseAdvertised",
    "IsDefault",
    "IsConfiguration",
    "IsSchema",
    "IsDomain",
    "IsApplication",
    "IsDnsApplication",
    "ReplicaLocations",
    "ReadOnlyReplicaLocations",
    "SourceCollection",
    "Notes"
)

$ApplicationPartitionFields = @(
    "PartitionName",
    "NamingContext",
    "DnsRoot",
    "PartitionType",
    "IsDnsApplicationPartition",
    "ReplicaLocationServers",
    "ReplicaLocationSites",
    "ReplicaLocationDns",
    "ReadOnlyReplicaLocations",
    "Enabled",
    "BehaviorVersion",
    "SourceCollection",
    "Notes"
)

$OptionalFeatureFields = @(
    "FeatureName",
    "FeatureGuid",
    "FeatureScope",
    "RequiredForestMode",
    "EnabledScopes",
    "IsEnabled",
    "IsRecycleBinFeature",
    "SourceCollection",
    "Notes"
)

$FindingFields = @(
    "Severity",
    "Category",
    "ObjectType",
    "ObjectName",
    "Finding",
    "Impact",
    "Recommendation",
    "Evidence",
    "SourceCollection"
)

$RelationshipFields = @(
    "ForestConfigEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "PartitionType",
    "NamingContext",
    "DomainName",
    "ReplicaServers",
    "Status",
    "SourceCollection",
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

function ConvertTo-StringList {
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

    return @($items)
}

function ConvertTo-CsvValue {
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
        return ((ConvertTo-StringList -Value $Value) -join "; ")
    }

    return ([string]$Value).Trim()
}

function Get-CollectionNotes {
    param([Parameter()][object]$Collection)

    $items = @()
    foreach ($warning in @((Get-PropertyValue -InputObject $Collection -Path @("CollectionWarnings")))) {
        $step = ConvertTo-Text -Value (Get-PropertyValue -InputObject $warning -Path @("Step"))
        $message = ConvertTo-Text -Value (Get-PropertyValue -InputObject $warning -Path @("Message"))
        if ($step -or $message) {
            $items += "${step}: $message".Trim(": ")
        }
    }
    foreach ($errorItem in @((Get-PropertyValue -InputObject $Collection -Path @("CollectionErrors")))) {
        $step = ConvertTo-Text -Value (Get-PropertyValue -InputObject $errorItem -Path @("Step"))
        $message = ConvertTo-Text -Value (Get-PropertyValue -InputObject $errorItem -Path @("Message"))
        if ($step -or $message) {
            $items += "ERROR ${step}: $message".Trim(": ")
        }
    }

    return ($items -join "; ")
}

function Get-SourceCollectionName {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    return $File.Name
}

function Get-ReplicaServers {
    param([Parameter()][object]$Partition)

    $servers = @()
    foreach ($replica in @((Get-PropertyValue -InputObject $Partition -Path @("ReplicaLocations")))) {
        $server = ConvertTo-Text -Value (Get-PropertyValue -InputObject $replica -Path @("ServerName"))
        if ($server) {
            $servers += $server
        }
    }
    return @($servers | Sort-Object -Unique)
}

function Get-ReplicaSites {
    param([Parameter()][object]$Partition)

    $sites = @()
    foreach ($replica in @((Get-PropertyValue -InputObject $Partition -Path @("ReplicaLocations")))) {
        $site = ConvertTo-Text -Value (Get-PropertyValue -InputObject $replica -Path @("SiteName"))
        if ($site) {
            $sites += $site
        }
    }
    return @($sites | Sort-Object -Unique)
}

function Get-ReadOnlyReplicaServers {
    param([Parameter()][object]$Partition)

    $servers = @()
    foreach ($replica in @((Get-PropertyValue -InputObject $Partition -Path @("ReadOnlyReplicaLocations")))) {
        $server = ConvertTo-Text -Value (Get-PropertyValue -InputObject $replica -Path @("ServerName"))
        if ($server) {
            $servers += $server
        }
    }
    return @($servers | Sort-Object -Unique)
}

function Test-LegacyFunctionalLevel {
    param([Parameter()][string]$Mode)

    if (-not $Mode) {
        return $false
    }

    return ($Mode -match "2000|2003|2008")
}

function Export-CsvRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Fields,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value ($Fields -join ",") -Encoding UTF8
        return
    }

    $normalizedRows = @()
    foreach ($row in $Rows) {
        $map = [ordered]@{}
        foreach ($field in $Fields) {
            $map[$field] = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $row -Path @($field))
        }
        $normalizedRows += [pscustomobject]$map
    }

    $normalizedRows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-NormalizedKey {
    param([Parameter()][string]$Value)

    if (-not $Value) {
        return ""
    }
    return $Value.Trim().ToLowerInvariant()
}

function Select-UniqueRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][scriptblock]$KeyScript
    )

    $seen = @{}
    $result = @()
    foreach ($row in $Rows) {
        $key = [string](& $KeyScript $row)
        if (-not $key) {
            $key = [Guid]::NewGuid().ToString("N")
        }
        $normalized = Get-NormalizedKey -Value $key
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result += $row
        }
    }
    return @($result)
}

function ConvertTo-MermaidId {
    param([Parameter()][string]$Value)

    $text = if ($Value) { $Value } else { "Unknown" }
    $hash = [Math]::Abs($text.ToLowerInvariant().GetHashCode())
    return "N$hash"
}

function ConvertTo-MermaidLabel {
    param([Parameter()][string]$Value)

    if (-not $Value) {
        return "Unknown"
    }
    return ($Value -replace '"', "'")
}

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath not found: $InputPath"
}

$getChildItemParams = @{
    Path = $InputPath
    Filter = "*.forest-config.collection.json"
    File = $true
}
if ($Recurse) {
    $getChildItemParams["Recurse"] = $true
}

$collectionFiles = @(Get-ChildItem @getChildItemParams | Sort-Object FullName)
if ($collectionFiles.Count -eq 0) {
    throw "No *.forest-config.collection.json files were found under $InputPath"
}

$sourceCollections = @()
$forestRows = @()
$domainRows = @()
$schemaRows = @()
$namingContextRows = @()
$applicationPartitionRows = @()
$optionalFeatureRows = @()
$findingRows = @()
$script:relationships = @()
$script:edgeCounter = 1

function Add-Relationship {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceType,
        [Parameter(Mandatory = $true)][string]$Relationship,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$TargetType,
        [Parameter()][string]$PartitionType,
        [Parameter()][string]$NamingContext,
        [Parameter()][string]$DomainName,
        [Parameter()][string[]]$ReplicaServers = @(),
        [Parameter()][string]$Status = "Observed",
        [Parameter()][string]$SourceCollection,
        [Parameter()][string]$Notes
    )

    if (-not $Source -or -not $Target) {
        return
    }

    $script:relationships += [pscustomobject]@{
        ForestConfigEdgeId = ("F{0:D3}" -f $script:edgeCounter)
        Source = $Source
        SourceType = $SourceType
        Relationship = $Relationship
        Target = $Target
        TargetType = $TargetType
        PartitionType = $PartitionType
        NamingContext = $NamingContext
        DomainName = $DomainName
        ReplicaServers = ($ReplicaServers -join "; ")
        Status = $Status
        SourceCollection = $SourceCollection
        Notes = $Notes
    }
    $script:edgeCounter++
}

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$ObjectType,
        [Parameter(Mandatory = $true)][string]$ObjectName,
        [Parameter(Mandatory = $true)][string]$Finding,
        [Parameter()][string]$Impact,
        [Parameter()][string]$Recommendation,
        [Parameter()][string]$Evidence,
        [Parameter()][string]$SourceCollection
    )

    $script:findingRows += [pscustomobject]@{
        Severity = $Severity
        Category = $Category
        ObjectType = $ObjectType
        ObjectName = $ObjectName
        Finding = $Finding
        Impact = $Impact
        Recommendation = $Recommendation
        Evidence = $Evidence
        SourceCollection = $SourceCollection
    }
}

foreach ($file in $collectionFiles) {
    $sourceCollection = Get-SourceCollectionName -File $file
    $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $metadata = Get-PropertyValue -InputObject $json -Path @("Metadata")
    $forest = Get-PropertyValue -InputObject $json -Path @("Forest")
    $rootDse = Get-PropertyValue -InputObject $json -Path @("RootDSE")
    $schema = Get-PropertyValue -InputObject $json -Path @("Schema")
    $directorySettings = Get-PropertyValue -InputObject $json -Path @("DirectoryServiceSettings")
    $sitesGcContext = Get-PropertyValue -InputObject $json -Path @("SitesGcContext")
    $notes = Get-CollectionNotes -Collection $json

    $forestName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("Name"))
    if (-not $forestName) {
        $forestName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Path @("RequestedForestName"))
    }
    if (-not $forestName) {
        $forestName = "UnknownForest"
    }

    $sourceCollections += [pscustomobject]@{
        FileName = $sourceCollection
        FullName = $file.FullName
        CollectionType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Path @("CollectionType"))
        CollectionStatus = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Path @("CollectionStatus"))
        TimestampUtc = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Path @("TimestampUtc"))
        ForestName = $forestName
        Notes = $notes
    }

    $siteCount = ConvertTo-Text -Value (Get-PropertyValue -InputObject $sitesGcContext -Path @("SiteCount"))
    if (-not $siteCount) {
        $siteCount = @((Get-PropertyValue -InputObject $sitesGcContext -Path @("Sites"))).Count
    }
    $globalCatalogCount = @((Get-PropertyValue -InputObject $sitesGcContext -Path @("GlobalCatalogs"))).Count

    $forestRows += [pscustomobject]@{
        ForestName = $forestName
        RootDomain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("RootDomain"))
        ForestMode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("ForestMode"))
        ForestModeLevel = ConvertTo-Text -Value (Get-PropertyValue -InputObject $rootDse -Path @("forestFunctionality"))
        SchemaMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("SchemaMaster"))
        DomainNamingMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("DomainNamingMaster"))
        ConfigurationNamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $rootDse -Path @("configurationNamingContext"))
        SchemaNamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $rootDse -Path @("schemaNamingContext"))
        RootDomainNamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $rootDse -Path @("rootDomainNamingContext"))
        PartitionsContainer = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("PartitionsContainer"))
        DomainCount = @((Get-PropertyValue -InputObject $forest -Path @("Domains"))).Count
        SiteCount = $siteCount
        GlobalCatalogCount = $globalCatalogCount
        UpnSuffixes = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $forest -Path @("UPNSuffixes"))
        SpnSuffixes = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $forest -Path @("SPNSuffixes"))
        TombstoneLifetimeDays = ConvertTo-Text -Value (Get-PropertyValue -InputObject $directorySettings -Path @("tombstoneLifetime"))
        DeletedObjectLifetimeDays = ConvertTo-Text -Value (Get-PropertyValue -InputObject $directorySettings -Path @("msDS-DeletedObjectLifetime"))
        CollectionStatus = ConvertTo-Text -Value (Get-PropertyValue -InputObject $metadata -Path @("CollectionStatus"))
        SourceCollection = $sourceCollection
        Notes = $notes
    }

    foreach ($domain in @((Get-PropertyValue -InputObject $json -Path @("Domains")))) {
        if ($null -eq $domain) {
            continue
        }

        $domainName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DNSRoot"))
        $domainControllers = @((Get-PropertyValue -InputObject $sitesGcContext -Path @("DomainControllers")) | Where-Object {
            (ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Path @("DomainName"))) -ieq $domainName
        })
        $domainGlobalCatalogs = @($domainControllers | Where-Object {
            (ConvertTo-Text -Value (Get-PropertyValue -InputObject $_ -Path @("IsGlobalCatalog"))) -eq "true"
        })

        $domainRows += [pscustomobject]@{
            ForestName = $forestName
            DnsRoot = $domainName
            NetBIOSName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("NetBIOSName"))
            DomainMode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DomainMode"))
            DomainModeLevel = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DomainSettings", "msDS-Behavior-Version"))
            DistinguishedName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DistinguishedName"))
            ParentDomain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("ParentDomain"))
            ChildDomains = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $domain -Path @("ChildDomains"))
            PDCEmulator = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("PDCEmulator"))
            RIDMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("RIDMaster"))
            InfrastructureMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("InfrastructureMaster"))
            ReplicaDirectoryServers = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $domain -Path @("ReplicaDirectoryServers"))
            ReadOnlyReplicaDirectoryServers = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $domain -Path @("ReadOnlyReplicaDirectoryServers"))
            DomainControllerCount = $domainControllers.Count
            GlobalCatalogCount = $domainGlobalCatalogs.Count
            MachineAccountQuota = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DomainSettings", "ms-DS-MachineAccountQuota"))
            NTMixedDomain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DomainSettings", "nTMixedDomain"))
            SourceCollection = $sourceCollection
            Notes = $notes
        }

        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "ContainsDomain" -Target $domainName -TargetType "Domain" -NamingContext (ConvertTo-Text -Value (Get-PropertyValue -InputObject $domain -Path @("DistinguishedName"))) -DomainName $domainName -SourceCollection $sourceCollection
    }

    $schemaRows += [pscustomobject]@{
        ForestName = $forestName
        SchemaNamingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("NamingContext"))
        ObjectVersion = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("ObjectVersion"))
        ProductHint = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("ProductHint"))
        SchemaMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("SchemaMaster"))
        SchemaWhenCreated = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("WhenCreated"))
        SchemaWhenChanged = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("WhenChanged"))
        SchemaUpdateAllowed = ""
        SourceCollection = $sourceCollection
        Notes = $notes
    }

    $schemaMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $schema -Path @("SchemaMaster"))
    if ($schemaMaster) {
        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "SchemaMaster" -Target $schemaMaster -TargetType "DomainController" -SourceCollection $sourceCollection
    }

    $domainNamingMaster = ConvertTo-Text -Value (Get-PropertyValue -InputObject $forest -Path @("DomainNamingMaster"))
    if ($domainNamingMaster) {
        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "DomainNamingMaster" -Target $domainNamingMaster -TargetType "DomainController" -SourceCollection $sourceCollection
    }

    $partitionByNc = @{}
    foreach ($partition in @((Get-PropertyValue -InputObject $json -Path @("Partitions")))) {
        $partitionNc = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("NamingContext"))
        if ($partitionNc) {
            $partitionByNc[$partitionNc.ToLowerInvariant()] = $partition
        }
    }

    foreach ($nc in @((Get-PropertyValue -InputObject $json -Path @("NamingContexts")))) {
        if ($null -eq $nc) {
            continue
        }

        $namingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("NamingContext"))
        $matchingPartition = $null
        if ($namingContext -and $partitionByNc.ContainsKey($namingContext.ToLowerInvariant())) {
            $matchingPartition = $partitionByNc[$namingContext.ToLowerInvariant()]
        }
        $replicaServers = if ($matchingPartition) { Get-ReplicaServers -Partition $matchingPartition } else { @() }
        $readOnlyReplicaServers = if ($matchingPartition) { Get-ReadOnlyReplicaServers -Partition $matchingPartition } else { @() }
        $type = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("Type"))

        $namingContextRows += [pscustomobject]@{
            NamingContext = $namingContext
            Type = $type
            DnsRoot = ConvertTo-Text -Value (Get-PropertyValue -InputObject $matchingPartition -Path @("DnsRoot"))
            NetBIOSName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $matchingPartition -Path @("NetBIOSName"))
            Enabled = ConvertTo-Text -Value (Get-PropertyValue -InputObject $matchingPartition -Path @("Enabled"))
            IsRootDseAdvertised = "true"
            IsDefault = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsDefault"))
            IsConfiguration = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsConfiguration"))
            IsSchema = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsSchema"))
            IsDomain = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsDomain"))
            IsApplication = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsApplication"))
            IsDnsApplication = ConvertTo-Text -Value (Get-PropertyValue -InputObject $nc -Path @("IsDnsApplication"))
            ReplicaLocations = ($replicaServers -join "; ")
            ReadOnlyReplicaLocations = ($readOnlyReplicaServers -join "; ")
            SourceCollection = $sourceCollection
            Notes = $notes
        }

        if ($namingContext) {
            Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "HasNamingContext" -Target $namingContext -TargetType "NamingContext" -PartitionType $type -NamingContext $namingContext -SourceCollection $sourceCollection
        }
    }

    foreach ($partition in @((Get-PropertyValue -InputObject $json -Path @("Partitions")))) {
        if ($null -eq $partition) {
            continue
        }

        $partitionType = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("PartitionType"))
        $isApplication = ($partitionType -in @("Application", "DNSApplication"))
        if (-not $isApplication) {
            continue
        }

        $replicaServers = Get-ReplicaServers -Partition $partition
        $replicaSites = Get-ReplicaSites -Partition $partition
        $readOnlyReplicaServers = Get-ReadOnlyReplicaServers -Partition $partition
        $partitionName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("Name"))
        $namingContext = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("NamingContext"))
        $targetType = if ($partitionType -eq "DNSApplication") { "DnsApplicationPartition" } else { "ApplicationPartition" }
        $relationship = if ($partitionType -eq "DNSApplication") { "HasDnsApplicationPartition" } else { "HasApplicationPartition" }

        $applicationPartitionRows += [pscustomobject]@{
            PartitionName = $partitionName
            NamingContext = $namingContext
            DnsRoot = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("DnsRoot"))
            PartitionType = $partitionType
            IsDnsApplicationPartition = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("IsDnsApplicationPartition"))
            ReplicaLocationServers = ($replicaServers -join "; ")
            ReplicaLocationSites = ($replicaSites -join "; ")
            ReplicaLocationDns = ConvertTo-CsvValue -Value (Get-PropertyValue -InputObject $partition -Path @("RawReplicaLocationDns"))
            ReadOnlyReplicaLocations = ($readOnlyReplicaServers -join "; ")
            Enabled = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("Enabled"))
            BehaviorVersion = ConvertTo-Text -Value (Get-PropertyValue -InputObject $partition -Path @("BehaviorVersion"))
            SourceCollection = $sourceCollection
            Notes = $notes
        }

        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship $relationship -Target $namingContext -TargetType $targetType -PartitionType $partitionType -NamingContext $namingContext -ReplicaServers $replicaServers -SourceCollection $sourceCollection

        foreach ($replicaServer in $replicaServers) {
            Add-Relationship -Source $namingContext -SourceType $targetType -Relationship "ReplicatedTo" -Target $replicaServer -TargetType "DomainController" -PartitionType $partitionType -NamingContext $namingContext -ReplicaServers @($replicaServer) -SourceCollection $sourceCollection
        }
    }

    foreach ($feature in @((Get-PropertyValue -InputObject $json -Path @("OptionalFeatures")))) {
        if ($null -eq $feature) {
            continue
        }

        $featureName = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("Name"))
        $enabledScopes = ConvertTo-StringList -Value (Get-PropertyValue -InputObject $feature -Path @("EnabledScopes"))
        $isEnabled = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("IsEnabled"))

        $optionalFeatureRows += [pscustomobject]@{
            FeatureName = $featureName
            FeatureGuid = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("FeatureGUID"))
            FeatureScope = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("FeatureScope"))
            RequiredForestMode = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("RequiredForestMode"))
            EnabledScopes = ($enabledScopes -join "; ")
            IsEnabled = $isEnabled
            IsRecycleBinFeature = ConvertTo-Text -Value (Get-PropertyValue -InputObject $feature -Path @("IsRecycleBinFeature"))
            SourceCollection = $sourceCollection
            Notes = $notes
        }

        if ($isEnabled -eq "true") {
            Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "EnabledOptionalFeature" -Target $featureName -TargetType "OptionalFeature" -SourceCollection $sourceCollection -Notes ("Enabled scopes: " + ($enabledScopes -join "; "))
        }
    }

    foreach ($suffix in ConvertTo-StringList -Value (Get-PropertyValue -InputObject $forest -Path @("UPNSuffixes"))) {
        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "ConfiguredSuffix" -Target $suffix -TargetType "Suffix" -SourceCollection $sourceCollection -Notes "UPN suffix"
    }
    foreach ($suffix in ConvertTo-StringList -Value (Get-PropertyValue -InputObject $forest -Path @("SPNSuffixes"))) {
        Add-Relationship -Source $forestName -SourceType "Forest" -Relationship "ConfiguredSuffix" -Target $suffix -TargetType "Suffix" -SourceCollection $sourceCollection -Notes "SPN suffix"
    }
}

$forestRows = Select-UniqueRows -Rows $forestRows -KeyScript { param($row) "$($row.ForestName)|$($row.SourceCollection)" }
$domainRows = Select-UniqueRows -Rows $domainRows -KeyScript { param($row) "$($row.ForestName)|$($row.DnsRoot)" }
$schemaRows = Select-UniqueRows -Rows $schemaRows -KeyScript { param($row) "$($row.ForestName)|$($row.ObjectVersion)|$($row.SchemaMaster)" }
$namingContextRows = Select-UniqueRows -Rows $namingContextRows -KeyScript { param($row) "$($row.NamingContext)|$($row.SourceCollection)" }
$applicationPartitionRows = Select-UniqueRows -Rows $applicationPartitionRows -KeyScript { param($row) "$($row.NamingContext)|$($row.SourceCollection)" }
$optionalFeatureRows = Select-UniqueRows -Rows $optionalFeatureRows -KeyScript { param($row) "$($row.FeatureName)|$($row.SourceCollection)" }

foreach ($forestRow in $forestRows) {
    if ($forestRow.CollectionStatus -eq "Failed") {
        Add-Finding -Severity "High" -Category "Collection" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Collection failed." -Impact "Inventory may be incomplete." -Recommendation "Resolve collection errors and rerun discovery." -Evidence $forestRow.Notes -SourceCollection $forestRow.SourceCollection
    }
    elseif ($forestRow.CollectionStatus -eq "CompletedWithWarnings") {
        Add-Finding -Severity "Medium" -Category "Collection" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Collection completed with warnings." -Impact "Some attributes may be missing." -Recommendation "Review collection warnings before migration planning." -Evidence $forestRow.Notes -SourceCollection $forestRow.SourceCollection
    }

    if (Test-LegacyFunctionalLevel -Mode $forestRow.ForestMode) {
        Add-Finding -Severity "High" -Category "Compatibility" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Forest functional level is legacy." -Impact "Legacy forest mode can constrain migration tooling and target compatibility." -Recommendation "Review application and domain controller dependencies before raising functional levels." -Evidence $forestRow.ForestMode -SourceCollection $forestRow.SourceCollection
    }

    if (-not $forestRow.TombstoneLifetimeDays) {
        Add-Finding -Severity "Medium" -Category "Lifecycle" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Tombstone lifetime was not readable." -Impact "Object recovery and lingering object planning may need manual validation." -Recommendation "Validate tombstone lifetime from Directory Service settings." -SourceCollection $forestRow.SourceCollection
    }
    else {
        $tombstone = 0
        if ([int]::TryParse([string]$forestRow.TombstoneLifetimeDays, [ref]$tombstone) -and $tombstone -lt 180) {
            Add-Finding -Severity "Medium" -Category "Lifecycle" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Tombstone lifetime is below 180 days." -Impact "Shorter recovery windows can increase migration rollback risk." -Recommendation "Review backup, restore, and lingering object procedures." -Evidence $forestRow.TombstoneLifetimeDays -SourceCollection $forestRow.SourceCollection
        }
    }

    if (-not $forestRow.DeletedObjectLifetimeDays) {
        Add-Finding -Severity "Info" -Category "Lifecycle" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "Deleted object lifetime is not explicitly configured." -Impact "Deleted object lifetime usually inherits tombstone lifetime." -Recommendation "Confirm this inheritance is acceptable for migration recovery planning." -SourceCollection $forestRow.SourceCollection
    }

    if ([int]$forestRow.GlobalCatalogCount -eq 0) {
        Add-Finding -Severity "Medium" -Category "TopologyContext" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "No global catalogs were collected." -Impact "GC placement context is missing from this review." -Recommendation "Confirm collector permissions and domain controller discovery." -SourceCollection $forestRow.SourceCollection
    }
}

foreach ($domainRow in $domainRows) {
    if (Test-LegacyFunctionalLevel -Mode $domainRow.DomainMode) {
        Add-Finding -Severity "High" -Category "Compatibility" -ObjectType "Domain" -ObjectName $domainRow.DnsRoot -Finding "Domain functional level is legacy." -Impact "Legacy domain mode can constrain domain controller operating system upgrades and migration options." -Recommendation "Review domain controller and application dependencies before changing domain mode." -Evidence $domainRow.DomainMode -SourceCollection $domainRow.SourceCollection
    }

    if ($domainRow.NTMixedDomain -and $domainRow.NTMixedDomain -ne "0") {
        Add-Finding -Severity "High" -Category "Compatibility" -ObjectType "Domain" -ObjectName $domainRow.DnsRoot -Finding "Domain mixed mode flag is non-zero." -Impact "Mixed mode can indicate legacy compatibility constraints." -Recommendation "Validate domain mode and legacy dependency status." -Evidence $domainRow.NTMixedDomain -SourceCollection $domainRow.SourceCollection
    }
}

foreach ($schemaRow in $schemaRows) {
    if ($schemaRow.ProductHint -eq "Unknown schema version") {
        Add-Finding -Severity "Medium" -Category "Schema" -ObjectType "Schema" -ObjectName $schemaRow.SchemaNamingContext -Finding "Schema objectVersion is unknown to toolkit mapping." -Impact "Schema compatibility should be manually validated." -Recommendation "Confirm schema version against Microsoft documentation for the target migration." -Evidence $schemaRow.ObjectVersion -SourceCollection $schemaRow.SourceCollection
    }
}

foreach ($partitionRow in $applicationPartitionRows) {
    if (-not $partitionRow.ReplicaLocationServers) {
        Add-Finding -Severity "Medium" -Category "Partition" -ObjectType "ApplicationPartition" -ObjectName $partitionRow.NamingContext -Finding "Application partition has no parsed replica locations." -Impact "Partition availability and DNS application partition coverage may need manual validation." -Recommendation "Review msDS-NC-Replica-Locations for this partition." -Evidence $partitionRow.ReplicaLocationDns -SourceCollection $partitionRow.SourceCollection
    }
}

$recycleBinRows = @($optionalFeatureRows | Where-Object { $_.IsRecycleBinFeature -eq "true" })
foreach ($forestRow in $forestRows) {
    $enabledRecycleBin = @($recycleBinRows | Where-Object { $_.SourceCollection -eq $forestRow.SourceCollection -and $_.IsEnabled -eq "true" })
    if ($enabledRecycleBin.Count -eq 0) {
        Add-Finding -Severity "Medium" -Category "OptionalFeature" -ObjectType "Forest" -ObjectName $forestRow.ForestName -Finding "AD Recycle Bin does not appear enabled." -Impact "Deleted object recovery during migration may be more limited." -Recommendation "Confirm Recycle Bin status and recovery requirements before migration." -SourceCollection $forestRow.SourceCollection
    }
}

$relationships = Select-UniqueRows -Rows $script:relationships -KeyScript {
    param($row)
    "$($row.Source)|$($row.Relationship)|$($row.Target)|$($row.NamingContext)|$($row.SourceCollection)"
}

$inventory = [ordered]@{
    Metadata = [ordered]@{
        Source = "ADForestConfigurationCollections"
        GeneratedAtUtc = ([DateTime]::UtcNow.ToString("o"))
        CollectionFileCount = $collectionFiles.Count
    }
    SourceCollections = @($sourceCollections)
    ForestSummary = @($forestRows)
    DomainSummary = @($domainRows)
    SchemaSummary = @($schemaRows)
    NamingContexts = @($namingContextRows)
    ApplicationPartitions = @($applicationPartitionRows)
    OptionalFeatures = @($optionalFeatureRows)
    Findings = @($findingRows)
    Relationships = @($relationships)
}

$inventoryPath = Join-Path $outputDirectory.FullName "inventory.json"
$forestSummaryPath = Join-Path $outputDirectory.FullName "forest-summary.csv"
$domainSummaryPath = Join-Path $outputDirectory.FullName "domain-summary.csv"
$schemaSummaryPath = Join-Path $outputDirectory.FullName "schema-summary.csv"
$namingContextsPath = Join-Path $outputDirectory.FullName "naming-contexts.csv"
$applicationPartitionsPath = Join-Path $outputDirectory.FullName "application-partitions.csv"
$optionalFeaturesPath = Join-Path $outputDirectory.FullName "optional-features.csv"
$findingsPath = Join-Path $outputDirectory.FullName "forest-config-findings.csv"
$relationshipsPath = Join-Path $outputDirectory.FullName "forest-config-relationships.csv"
$mermaidPath = Join-Path $outputDirectory.FullName "current-state.mmd"

$inventory | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
Export-CsvRows -Rows $forestRows -Fields $ForestSummaryFields -Path $forestSummaryPath
Export-CsvRows -Rows $domainRows -Fields $DomainSummaryFields -Path $domainSummaryPath
Export-CsvRows -Rows $schemaRows -Fields $SchemaSummaryFields -Path $schemaSummaryPath
Export-CsvRows -Rows $namingContextRows -Fields $NamingContextFields -Path $namingContextsPath
Export-CsvRows -Rows $applicationPartitionRows -Fields $ApplicationPartitionFields -Path $applicationPartitionsPath
Export-CsvRows -Rows $optionalFeatureRows -Fields $OptionalFeatureFields -Path $optionalFeaturesPath
Export-CsvRows -Rows $findingRows -Fields $FindingFields -Path $findingsPath
Export-CsvRows -Rows $relationships -Fields $RelationshipFields -Path $relationshipsPath

$mmdLines = @("graph LR")
foreach ($relationship in @($relationships)) {
    $sourceLabel = ConvertTo-MermaidLabel -Value ("$($relationship.SourceType): $($relationship.Source)")
    $targetLabel = ConvertTo-MermaidLabel -Value ("$($relationship.TargetType): $($relationship.Target)")
    $sourceId = ConvertTo-MermaidId -Value $sourceLabel
    $targetId = ConvertTo-MermaidId -Value $targetLabel
    $edgeLabel = ConvertTo-MermaidLabel -Value ("$($relationship.ForestConfigEdgeId) $($relationship.Relationship)")
    $mmdLines += "  $sourceId[""$sourceLabel""] -->|""$edgeLabel""| $targetId[""$targetLabel""]"
}
Set-Content -LiteralPath $mermaidPath -Value $mmdLines -Encoding UTF8

[pscustomobject]@{
    InventoryJson = $inventoryPath
    ForestSummaryCsv = $forestSummaryPath
    DomainSummaryCsv = $domainSummaryPath
    SchemaSummaryCsv = $schemaSummaryPath
    NamingContextsCsv = $namingContextsPath
    ApplicationPartitionsCsv = $applicationPartitionsPath
    OptionalFeaturesCsv = $optionalFeaturesPath
    FindingsCsv = $findingsPath
    RelationshipsCsv = $relationshipsPath
    Mermaid = $mermaidPath
    CollectionFileCount = $collectionFiles.Count
    FindingCount = @($findingRows).Count
    RelationshipCount = @($relationships).Count
}
