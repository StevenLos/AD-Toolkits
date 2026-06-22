[CmdletBinding()]
param(
    [Alias("InputCsv", "PathCsv", "ManifestCsv")]
    [string]$ConfigCsv,

    [string]$InputPath,

    [string]$OutputPath,

    [string]$PythonCommand,

    [switch]$UseExample
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-ProjectPath {
    param(
        [string]$Path,
        [string]$BasePath = $projectRoot,
        [switch]$MustExist
    )

    if (-not $Path) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $candidate = $Path
    }
    else {
        $cwdCandidate = Join-Path (Get-Location) $Path
        if (Test-Path -LiteralPath $cwdCandidate) {
            $candidate = (Resolve-Path -LiteralPath $cwdCandidate).Path
        }
        else {
            $candidate = Join-Path $BasePath $Path
        }
    }

    if ($MustExist -and -not (Test-Path -LiteralPath $candidate)) {
        throw "Path not found: $candidate"
    }
    return $candidate
}

function Read-SettingsCsv {
    param([string]$Path)

    $settings = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if ($row.Setting) {
            $settings[$row.Setting] = $row.Value
        }
    }
    return $settings
}

function Get-Setting {
    param(
        [hashtable]$Settings,
        [string]$Name,
        [string]$Default
    )

    if ($Settings.ContainsKey($Name) -and $Settings[$Name]) {
        return $Settings[$Name]
    }
    return $Default
}

function Resolve-InputFile {
    param(
        [string]$InputDirectory,
        [string]$Value
    )

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }
    return (Join-Path $InputDirectory $Value)
}

function Import-RequiredCsv {
    param(
        [string]$Path,
        [string[]]$RequiredColumns
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required CSV not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    $headers = @()
    if ($rows.Count -gt 0) {
        $headers = @($rows[0].PSObject.Properties.Name)
    }
    else {
        $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
        if ($firstLine) {
            $headers = @($firstLine -split ',')
        }
    }

    foreach ($column in $RequiredColumns) {
        if ($headers -notcontains $column) {
            throw "CSV '$Path' is missing required column '$column'."
        }
    }

    return $rows
}

function Assert-UniqueValues {
    param(
        [object[]]$Rows,
        [string]$Column,
        [string]$Path
    )

    $seen = @{}
    $rowNumber = 1
    foreach ($row in $Rows) {
        $rowNumber++
        $value = [string]$row.$Column
        if (-not $value) {
            throw "CSV '$Path' row $rowNumber has blank required ID column '$Column'."
        }
        if ($seen.ContainsKey($value)) {
            throw "CSV '$Path' row $rowNumber duplicates $Column '$value'."
        }
        $seen[$value] = $true
    }
}

if ($UseExample -and -not $ConfigCsv) {
    $ConfigCsv = Join-Path $projectRoot "04-examples/mock-forest-sites/diagram-inputs.csv"
}
if (-not $ConfigCsv -and -not $InputPath) {
    $ConfigCsv = Join-Path $projectRoot "03-templates/My-ADSS-Project-Template/diagram-inputs.csv"
}

$settings = @{}
if ($ConfigCsv) {
    $configPath = Resolve-ProjectPath -Path $ConfigCsv -MustExist
    $settings = Read-SettingsCsv -Path $configPath
}

$inputDirectory = if ($InputPath) { Resolve-ProjectPath -Path $InputPath -MustExist } else { Resolve-ProjectPath -Path (Get-Setting -Settings $settings -Name "InputPath" -Default ".\input") -MustExist }
$outputDirectory = if ($OutputPath) { Resolve-ProjectPath -Path $OutputPath } else { Resolve-ProjectPath -Path (Get-Setting -Settings $settings -Name "OutputPath" -Default ".\output") }
$pythonRequested = if ($PythonCommand) { $PythonCommand } else { Get-Setting -Settings $settings -Name "PythonCommand" -Default "" }

if ($pythonRequested) {
    $resolvedPython = Get-Command $pythonRequested -ErrorAction SilentlyContinue
    if (-not $resolvedPython) {
        throw "PythonCommand was provided but was not found: $pythonRequested"
    }
}
else {
    $resolvedPython = $null
    foreach ($command in @("python3", "python", "py")) {
        $resolvedPython = Get-Command $command -ErrorAction SilentlyContinue
        if ($resolvedPython) { break }
    }
    if (-not $resolvedPython) {
        throw "No Python command was found. Install Python or pass -PythonCommand."
    }
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$objectsPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ObjectsCsv" -Default "diagram-objects.csv")
$linksPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "LineOfSightLinksCsv" -Default "line-of-sight-links.csv")
$portsPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "PortsProtocolsCsv" -Default "ports-protocols.csv")
$expansionPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ExpansionCsv" -Default "ad-site-domain-controller-expansion.csv")
$subnetsPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "SubnetsCsv" -Default "ad-site-subnets.csv")
$replicationConnectionsPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ReplicationConnectionsCsv" -Default "replication-connections.csv")
$replicationPartnerMetadataPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ReplicationPartnerMetadataCsv" -Default "replication-partner-metadata.csv")
$replicationFailuresPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ReplicationFailuresCsv" -Default "replication-failures.csv")
$replicationTopologyPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ReplicationTopologyEdgesCsv" -Default "replication-topology-edges.csv")
$replicationHealthPath = Resolve-InputFile -InputDirectory $inputDirectory -Value (Get-Setting -Settings $settings -Name "ReplicationHealthSummaryCsv" -Default "replication-health-summary.csv")

$objects = Import-RequiredCsv -Path $objectsPath -RequiredColumns @("ObjectId", "ObjectName", "ObjectType", "DisplayLabel", "DisplayOrder", "Notes")
$links = Import-RequiredCsv -Path $linksPath -RequiredColumns @("LineOfSightId", "SourceObjectId", "TargetObjectId", "Direction", "Label", "Status", "Notes")
$ports = Import-RequiredCsv -Path $portsPath -RequiredColumns @("RequirementId", "LineOfSightId", "Protocol", "Port", "Service", "Purpose", "Status", "Notes")
$expansion = Import-RequiredCsv -Path $expansionPath -RequiredColumns @("ExpansionId", "SiteObjectId", "SiteName", "ServerName", "ServerRole", "Status")
$subnets = Import-RequiredCsv -Path $subnetsPath -RequiredColumns @("SubnetId", "SiteObjectId", "SiteName", "SubnetName", "Cidr", "Status", "Notes")
$replicationConnections = Import-RequiredCsv -Path $replicationConnectionsPath -RequiredColumns @("ConnectionId", "ConnectionName", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "Transport", "Notes")
$replicationPartnerMetadata = Import-RequiredCsv -Path $replicationPartnerMetadataPath -RequiredColumns @("MetadataId", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "LastSuccess", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "Status", "Notes")
$replicationFailures = Import-RequiredCsv -Path $replicationFailuresPath -RequiredColumns @("FailureId", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "Status", "Notes")
$replicationTopology = Import-RequiredCsv -Path $replicationTopologyPath -RequiredColumns @("ReplicationEdgeId", "EvidenceType", "SourceServer", "SourceSite", "DestinationServer", "DestinationSite", "NamingContext", "LastSuccess", "LastFailure", "ConsecutiveFailureCount", "ResultCode", "ResultMessage", "Status", "EvidenceId", "Notes")
$replicationHealth = Import-RequiredCsv -Path $replicationHealthPath -RequiredColumns @("DomainController", "SiteName", "PartnerMetadataCount", "ConfiguredConnectionCount", "FailureCount", "QueueOperationCount", "LastSuccess", "LastFailure", "Status", "Notes")

Assert-UniqueValues -Rows $objects -Column "ObjectId" -Path $objectsPath
Assert-UniqueValues -Rows $links -Column "LineOfSightId" -Path $linksPath
Assert-UniqueValues -Rows $ports -Column "RequirementId" -Path $portsPath
Assert-UniqueValues -Rows $expansion -Column "ExpansionId" -Path $expansionPath
Assert-UniqueValues -Rows $subnets -Column "SubnetId" -Path $subnetsPath
Assert-UniqueValues -Rows $replicationConnections -Column "ConnectionId" -Path $replicationConnectionsPath
Assert-UniqueValues -Rows $replicationPartnerMetadata -Column "MetadataId" -Path $replicationPartnerMetadataPath
Assert-UniqueValues -Rows $replicationFailures -Column "FailureId" -Path $replicationFailuresPath
Assert-UniqueValues -Rows $replicationTopology -Column "ReplicationEdgeId" -Path $replicationTopologyPath

$objectIds = @{}
foreach ($object in $objects) {
    $objectIds[[string]$object.ObjectId] = $object
}
$linkIds = @{}
foreach ($link in $links) {
    $linkIds[[string]$link.LineOfSightId] = $link
}

$pairMap = @{}
$rowNumber = 1
foreach ($link in $links) {
    $rowNumber++
    foreach ($column in @("SourceObjectId", "TargetObjectId")) {
        $objectId = [string]$link.$column
        if (-not $objectIds.ContainsKey($objectId)) {
            throw "CSV '$linksPath' row $rowNumber references unknown object '$objectId' in $column."
        }
    }
    if ($link.SourceObjectId -eq $link.TargetObjectId) {
        throw "CSV '$linksPath' row $rowNumber links an object to itself: $($link.SourceObjectId)."
    }
    $pair = @([string]$link.SourceObjectId, [string]$link.TargetObjectId) | Sort-Object
    $pairKey = "$($pair[0])|$($pair[1])"
    if ($pairMap.ContainsKey($pairKey)) {
        throw "CSV '$linksPath' row $rowNumber duplicates unordered site pair '$pairKey'."
    }
    $pairMap[$pairKey] = $true
    if ($link.Notes -notmatch "site link") {
        Write-Warning "Line-of-sight link '$($link.LineOfSightId)' notes do not mention the source AD site link."
    }
}

$rowNumber = 1
foreach ($port in $ports) {
    $rowNumber++
    if (-not $linkIds.ContainsKey([string]$port.LineOfSightId)) {
        throw "CSV '$portsPath' row $rowNumber references unknown LineOfSightId '$($port.LineOfSightId)'."
    }
}

$rowNumber = 1
foreach ($row in $expansion) {
    $rowNumber++
    if (-not $objectIds.ContainsKey([string]$row.SiteObjectId)) {
        throw "CSV '$expansionPath' row $rowNumber references unknown SiteObjectId '$($row.SiteObjectId)'."
    }
}

$rowNumber = 1
foreach ($row in $subnets) {
    $rowNumber++
    if ($row.SiteObjectId -and -not $objectIds.ContainsKey([string]$row.SiteObjectId)) {
        throw "CSV '$subnetsPath' row $rowNumber references unknown SiteObjectId '$($row.SiteObjectId)'."
    }
    if (-not $row.SiteObjectId) {
        Write-Warning "Subnet '$($row.SubnetName)' is not assigned to a known site."
    }
}

$validEvidenceTypes = @("ConfiguredConnection", "ObservedPartnerMetadata", "ReplicationFailure", "ReplicationQueue")
$rowNumber = 1
foreach ($row in $replicationTopology) {
    $rowNumber++
    if ($validEvidenceTypes -notcontains $row.EvidenceType) {
        throw "CSV '$replicationTopologyPath' row $rowNumber has unsupported EvidenceType '$($row.EvidenceType)'."
    }
    if ($row.EvidenceType -eq "ConfiguredConnection" -and $row.Notes -notmatch "configured") {
        Write-Warning "Replication edge '$($row.ReplicationEdgeId)' is configured evidence but notes do not clearly say configured."
    }
    if ($row.EvidenceType -eq "ObservedPartnerMetadata" -and $row.Notes -notmatch "observed") {
        Write-Warning "Replication edge '$($row.ReplicationEdgeId)' is observed metadata but notes do not clearly say observed."
    }
    if (-not $row.SourceServer -or -not $row.DestinationServer) {
        Write-Warning "Replication edge '$($row.ReplicationEdgeId)' has a blank source or destination server."
    }
}

foreach ($object in $objects) {
    $siteId = [string]$object.ObjectId
    $siteSubnetCount = @($subnets | Where-Object { $_.SiteObjectId -eq $siteId }).Count
    $siteDcCount = @($expansion | Where-Object { $_.SiteObjectId -eq $siteId }).Count
    if ($siteSubnetCount -eq 0) {
        Write-Warning "Site '$($object.ObjectName)' has no subnet rows."
    }
    if ($siteDcCount -eq 0) {
        Write-Warning "Site '$($object.ObjectName)' has no discovered domain controllers. This can be expected when automatic site coverage is in use."
    }
}

[pscustomobject]@{
    Status = "OK"
    InputPath = $inputDirectory
    OutputPath = $outputDirectory
    PythonCommand = $resolvedPython.Source
    SiteCount = $objects.Count
    LineOfSightLinkCount = $links.Count
    PortRequirementCount = $ports.Count
    DomainControllerCount = $expansion.Count
    SubnetCount = $subnets.Count
    ReplicationConnectionCount = $replicationConnections.Count
    ReplicationPartnerMetadataCount = $replicationPartnerMetadata.Count
    ReplicationFailureCount = $replicationFailures.Count
    ReplicationTopologyEdgeCount = $replicationTopology.Count
    ReplicationHealthSummaryCount = $replicationHealth.Count
}
