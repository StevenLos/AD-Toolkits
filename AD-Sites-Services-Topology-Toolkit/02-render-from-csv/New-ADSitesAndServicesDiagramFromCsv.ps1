[CmdletBinding()]
param(
    [Alias("InputCsv", "PathCsv", "ManifestCsv")]
    [string]$ConfigCsv,

    [string]$InputPath,

    [string]$OutputPath,

    [string]$Name,

    [string]$Title,

    [string]$Subtitle,

    [string]$PythonCommand,

    [ValidateSet("bipartite", "ring")]
    [string]$LayoutMode = "ring",

    [int]$DenseLinkThreshold = 20,

    [int]$DenseSiteThreshold = 15,

    [switch]$UseExample,

    [switch]$SkipPreflight
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

function Resolve-PythonCommand {
    param([string]$RequestedCommand)

    if ($RequestedCommand) {
        $resolved = Get-Command $RequestedCommand -ErrorAction SilentlyContinue
        if (-not $resolved) {
            throw "PythonCommand was provided but was not found: $RequestedCommand"
        }
        return $resolved.Source
    }

    foreach ($command in @("python3", "python", "py")) {
        $resolved = Get-Command $command -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Source
        }
    }

    throw "No Python command was found. Install Python or pass -PythonCommand."
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
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
$safeName = if ($Name) { $Name } else { Get-Setting -Settings $settings -Name "Name" -Default "ad-sites-diagram" }
$diagramTitle = if ($Title) { $Title } else { Get-Setting -Settings $settings -Name "Title" -Default "Active Directory Sites And Services Diagram" }
$diagramSubtitle = if ($Subtitle) { $Subtitle } else { Get-Setting -Settings $settings -Name "Subtitle" -Default "AD sites site links domain controllers and supporting network review tables" }
$pythonRequested = if ($PythonCommand) { $PythonCommand } else { Get-Setting -Settings $settings -Name "PythonCommand" -Default "" }
$layoutRequested = if ($PSBoundParameters.ContainsKey("LayoutMode")) { $LayoutMode } else { Get-Setting -Settings $settings -Name "LayoutMode" -Default "ring" }
$denseLinkRequested = if ($PSBoundParameters.ContainsKey("DenseLinkThreshold")) { $DenseLinkThreshold } else { [int](Get-Setting -Settings $settings -Name "DenseLinkThreshold" -Default "20") }
$denseSiteRequested = if ($PSBoundParameters.ContainsKey("DenseSiteThreshold")) { $DenseSiteThreshold } else { [int](Get-Setting -Settings $settings -Name "DenseSiteThreshold" -Default "15") }

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

if (-not $SkipPreflight) {
    $preflight = Join-Path $projectRoot "01-setup/Test-ADSitesAndServicesDiagramEnvironment.ps1"
    $preflightArgs = @{
        InputPath = $inputDirectory
        OutputPath = $outputDirectory
    }
    if ($ConfigCsv) {
        $preflightArgs["ConfigCsv"] = Resolve-ProjectPath -Path $ConfigCsv -MustExist
    }
    if ($pythonRequested) {
        $preflightArgs["PythonCommand"] = $pythonRequested
    }
    $preflightResult = & $preflight @preflightArgs
    $preflightResult | Write-Output
}

$python = Resolve-PythonCommand -RequestedCommand $pythonRequested
$renderer = Join-Path $PSScriptRoot "Render-ADSitesAndServicesDiagram.py"
if (-not (Test-Path -LiteralPath $renderer)) {
    throw "Renderer not found: $renderer"
}
$renderer = (Resolve-Path -LiteralPath $renderer).Path

$fileSafeName = ($safeName -replace '[^A-Za-z0-9._-]', '-').Trim("-")
if (-not $fileSafeName) {
    $fileSafeName = "ad-sites-diagram"
}
$svgPath = Join-Path $outputDirectory "$fileSafeName.svg"
$inventoryPath = Join-Path $outputDirectory "$fileSafeName.inventory.json"

Invoke-ExternalCommand -FilePath $python -ArgumentList @(
    $renderer,
    "--objects-csv", $objectsPath,
    "--links-csv", $linksPath,
    "--ports-csv", $portsPath,
    "--expansion-csv", $expansionPath,
    "--subnets-csv", $subnetsPath,
    "--replication-connections-csv", $replicationConnectionsPath,
    "--replication-partner-metadata-csv", $replicationPartnerMetadataPath,
    "--replication-failures-csv", $replicationFailuresPath,
    "--replication-topology-csv", $replicationTopologyPath,
    "--replication-health-csv", $replicationHealthPath,
    "--output", $svgPath,
    "--inventory-output", $inventoryPath,
    "--title", $diagramTitle,
    "--subtitle", $diagramSubtitle,
    "--layout-mode", $layoutRequested,
    "--dense-link-threshold", [string]$denseLinkRequested,
    "--dense-site-threshold", [string]$denseSiteRequested
)

[pscustomobject]@{
    Svg = $svgPath
    InventoryJson = $inventoryPath
    InputPath = $inputDirectory
    OutputPath = $outputDirectory
    Name = $safeName
}
