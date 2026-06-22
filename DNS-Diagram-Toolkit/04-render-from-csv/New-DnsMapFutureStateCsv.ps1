[CmdletBinding()]
param(
    [string]$CurrentCsv = ".\output\02-current-state-images\current-state.dns-relationship-details.csv",

    [string]$OutputCsv = ".\input\manual-csv\future-state.dns-relationship-details.csv",

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CsvHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $header = Get-Content -LiteralPath $Path -TotalCount 1
    if (-not $header) {
        throw "CurrentCsv does not contain a header row: $Path"
    }

    return @($header -split "," | ForEach-Object { $_.Trim().Trim('"') })
}

function Assert-RequiredColumns {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Columns,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($requiredColumn in @("DnsEdgeId", "Source", "SourceType", "Relationship", "Target", "TargetType")) {
        if ($Columns -notcontains $requiredColumn) {
            throw "CurrentCsv is missing required column '$requiredColumn': $Path"
        }
    }
}

$currentCsvPath = (Resolve-Path -LiteralPath $CurrentCsv).Path
$columns = Get-CsvHeader -Path $currentCsvPath
Assert-RequiredColumns -Columns $columns -Path $currentCsvPath

$outputDirectory = Split-Path -Parent $OutputCsv
if ($outputDirectory) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

if ((Test-Path -LiteralPath $OutputCsv) -and -not $Force) {
    throw "OutputCsv already exists: $OutputCsv. Use -Force to overwrite it."
}

Copy-Item -LiteralPath $currentCsvPath -Destination $OutputCsv -Force:$Force
$outputCsvPath = (Resolve-Path -LiteralPath $OutputCsv).Path

[pscustomobject]@{
    CurrentCsv = $currentCsvPath
    FutureStateCsv = $outputCsvPath
    NextStep = "Edit FutureStateCsv, then render it with New-DnsMapImagesFromCsv.ps1 -DnsRelationshipCsv FutureStateCsv."
}
