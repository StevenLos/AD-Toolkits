[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [switch]$SkipRender
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$exampleRoot = Join-Path $ProjectRoot "04-examples/mock-forest-sites"
$rawPath = Join-Path $exampleRoot "raw"
$inputPath = Join-Path $exampleRoot "input"
$outputPath = Join-Path $exampleRoot "output"
$configCsv = Join-Path $exampleRoot "diagram-inputs.csv"

$converter = Join-Path $ProjectRoot "01-discovery/Convert-ADSitesAndServicesExportToDiagramCsv.ps1"
$preflight = Join-Path $ProjectRoot "01-setup/Test-ADSitesAndServicesDiagramEnvironment.ps1"
$renderer = Join-Path $ProjectRoot "02-render-from-csv/New-ADSitesAndServicesDiagramFromCsv.ps1"

& $converter `
    -RawPath $rawPath `
    -InputPath $inputPath `
    -OutputPath $outputPath `
    -Name "mock-forest-sites" `
    -Title "Mock Active Directory Sites And Services Diagram" `
    -Subtitle "Offline mock forest showing AD sites site links domain controllers and subnets" `
    -Force `
    -PassThru | Out-Null

$preflightResult = & $preflight -ConfigCsv $configCsv
if ($preflightResult.Status -ne "OK") {
    throw "Preflight did not return OK."
}

if (-not $SkipRender) {
    & $renderer -ConfigCsv $configCsv -SkipPreflight | Out-Null
}

$expectedFiles = @(
    "input/diagram-objects.csv",
    "input/line-of-sight-links.csv",
    "input/ports-protocols.csv",
    "input/ad-site-domain-controller-expansion.csv",
    "input/ad-site-subnets.csv",
    "input/replication-connections.csv",
    "input/replication-partner-metadata.csv",
    "input/replication-failures.csv",
    "input/replication-topology-edges.csv",
    "input/replication-health-summary.csv",
    "output/transform-summary.json"
)
if (-not $SkipRender) {
    $expectedFiles += @(
        "output/mock-forest-sites.svg",
        "output/mock-forest-sites.inventory.json"
    )
}

foreach ($relativePath in $expectedFiles) {
    $path = Join-Path $exampleRoot $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Expected output file was not created: $path"
    }
}

function Count-CsvRows {
    param([string]$Path)
    return @((Import-Csv -LiteralPath $Path)).Count
}

$counts = [ordered]@{
    Sites = Count-CsvRows -Path (Join-Path $inputPath "diagram-objects.csv")
    LineOfSightLinks = Count-CsvRows -Path (Join-Path $inputPath "line-of-sight-links.csv")
    Ports = Count-CsvRows -Path (Join-Path $inputPath "ports-protocols.csv")
    DomainControllers = Count-CsvRows -Path (Join-Path $inputPath "ad-site-domain-controller-expansion.csv")
    Subnets = Count-CsvRows -Path (Join-Path $inputPath "ad-site-subnets.csv")
    ReplicationConnections = Count-CsvRows -Path (Join-Path $inputPath "replication-connections.csv")
    ReplicationPartnerMetadata = Count-CsvRows -Path (Join-Path $inputPath "replication-partner-metadata.csv")
    ReplicationFailures = Count-CsvRows -Path (Join-Path $inputPath "replication-failures.csv")
    ReplicationTopologyEdges = Count-CsvRows -Path (Join-Path $inputPath "replication-topology-edges.csv")
    ReplicationHealthSummary = Count-CsvRows -Path (Join-Path $inputPath "replication-health-summary.csv")
}

$expectedCounts = @{
    Sites = 5
    LineOfSightLinks = 5
    Ports = 80
    DomainControllers = 5
    Subnets = 7
    ReplicationConnections = 3
    ReplicationPartnerMetadata = 4
    ReplicationFailures = 1
    ReplicationTopologyEdges = 8
    ReplicationHealthSummary = 5
}
foreach ($name in $expectedCounts.Keys) {
    if ($counts[$name] -ne $expectedCounts[$name]) {
        throw "Unexpected $name count. Expected $($expectedCounts[$name]); found $($counts[$name])."
    }
}

if (-not $SkipRender) {
    $inventoryPath = Join-Path $outputPath "mock-forest-sites.inventory.json"
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $inventoryNameMap = @{
        Ports = "PortRows"
    }
    foreach ($name in $expectedCounts.Keys) {
        $inventoryName = if ($inventoryNameMap.ContainsKey($name)) { $inventoryNameMap[$name] } else { $name }
        if ($inventory.Counts.$inventoryName -ne $expectedCounts[$name]) {
            throw "Unexpected inventory $inventoryName count. Expected $($expectedCounts[$name]); found $($inventory.Counts.$inventoryName)."
        }
    }

    $svgPath = Join-Path $outputPath "mock-forest-sites.svg"
    if ((Get-Item -LiteralPath $svgPath).Length -lt 1000) {
        throw "SVG output looks too small to be valid: $svgPath"
    }
}

[pscustomobject]@{
    Status = "OK"
    ProjectRoot = $ProjectRoot
    Counts = [pscustomobject]$counts
    Rendered = -not $SkipRender
}
