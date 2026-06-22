[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RelationshipCsv,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Name,

    [string]$RendererPath,

    [string]$PythonCommand,

    [string]$BrowserPath,

    [switch]$SkipPng
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

    throw "No Python command was found. Install Python or pass -PythonCommand with the path to python.exe."
}

function Resolve-BrowserPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "BrowserPath was provided but was not found: $RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($command in @("msedge", "chrome", "google-chrome", "chromium", "chromium-browser")) {
        $resolved = Get-Command $command -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Source
        }
    }

    return $null
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-CsvColumnValue {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row,

        [Parameter(Mandatory = $true)]
        [string]$ColumnName
    )

    foreach ($property in $Row.PSObject.Properties) {
        if ($property.Name -ieq $ColumnName) {
            return ([string]$property.Value).Trim()
        }
    }

    return ""
}

function Test-AllowedValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues
    )

    foreach ($allowed in $AllowedValues) {
        if ($Value -ieq $allowed) {
            return $true
        }
    }

    return $false
}

function Test-ForestConfigRelationshipCsv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $requiredColumns = @(
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
    $allowedObjectTypes = @(
        "Forest",
        "Domain",
        "Schema",
        "NamingContext",
        "ApplicationPartition",
        "DnsApplicationPartition",
        "DomainController",
        "GlobalCatalog",
        "OptionalFeature",
        "Suffix"
    )
    $allowedRelationships = @(
        "ContainsDomain",
        "HasNamingContext",
        "HasApplicationPartition",
        "HasDnsApplicationPartition",
        "ReplicatedTo",
        "SchemaMaster",
        "DomainNamingMaster",
        "EnabledOptionalFeature",
        "ConfiguredSuffix"
    )
    $allowedStatuses = @("Observed", "Planned", "Review", "Removed")

    $header = Get-Content -LiteralPath $Path -TotalCount 1
    if (-not $header) {
        throw "CSV has no header row: $Path"
    }

    $columns = @($header -split "," | ForEach-Object { $_.Trim().Trim('"') })
    foreach ($requiredColumn in $requiredColumns) {
        if ($columns -notcontains $requiredColumn) {
            throw "CSV is missing required column '$requiredColumn': $Path"
        }
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    $edgeIds = @{}
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        foreach ($requiredValueColumn in @("ForestConfigEdgeId", "Source", "SourceType", "Relationship", "Target", "TargetType")) {
            $value = Get-CsvColumnValue -Row $row -ColumnName $requiredValueColumn
            if (-not $value) {
                throw "CSV row $rowNumber column '$requiredValueColumn' must not be blank."
            }
        }

        $edgeId = Get-CsvColumnValue -Row $row -ColumnName "ForestConfigEdgeId"
        if ($edgeIds.ContainsKey($edgeId)) {
            throw "CSV row $rowNumber has duplicate ForestConfigEdgeId '$edgeId'."
        }
        $edgeIds[$edgeId] = $true

        foreach ($typeColumn in @("SourceType", "TargetType")) {
            $typeValue = Get-CsvColumnValue -Row $row -ColumnName $typeColumn
            if (-not (Test-AllowedValue -Value $typeValue -AllowedValues $allowedObjectTypes)) {
                throw "CSV row $rowNumber column '$typeColumn' has unsupported value '$typeValue'."
            }
        }

        $relationship = Get-CsvColumnValue -Row $row -ColumnName "Relationship"
        if (-not (Test-AllowedValue -Value $relationship -AllowedValues $allowedRelationships)) {
            throw "CSV row $rowNumber column 'Relationship' has unsupported value '$relationship'."
        }

        $status = Get-CsvColumnValue -Row $row -ColumnName "Status"
        if ($status -and -not (Test-AllowedValue -Value $status -AllowedValues $allowedStatuses)) {
            throw "CSV row $rowNumber column 'Status' has unsupported value '$status'."
        }
    }

    [pscustomobject]@{
        RowCount = $rows.Count
        EdgeCount = $edgeIds.Count
    }
}

function Get-SvgSize {
    param([Parameter(Mandatory = $true)][string]$SvgPath)

    [xml]$doc = Get-Content -LiteralPath $SvgPath -Raw
    [pscustomobject]@{
        Width = [int][double]$doc.DocumentElement.GetAttribute("width")
        Height = [int][double]$doc.DocumentElement.GetAttribute("height")
    }
}

function Convert-SvgToPng {
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$SvgPath,
        [Parameter(Mandatory = $true)][string]$PngPath
    )

    if (Test-Path -LiteralPath $PngPath) {
        Remove-Item -LiteralPath $PngPath -Force
    }

    $size = Get-SvgSize -SvgPath $SvgPath
    $svgUri = [System.Uri]::new((Resolve-Path -LiteralPath $SvgPath).Path).AbsoluteUri
    $userDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("adforest-csv-render-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null

    $arguments = @(
        "--headless=new",
        "--hide-scrollbars",
        "--disable-gpu",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-sync",
        "--disable-extensions",
        "--no-first-run",
        "--no-default-browser-check",
        "--user-data-dir=$userDataDir",
        "--screenshot=$PngPath",
        "--window-size=$($size.Width),$($size.Height)",
        $svgUri
    )

    $startProcessArgs = @{
        FilePath = $Browser
        ArgumentList = $arguments
        PassThru = $true
    }
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        $startProcessArgs["WindowStyle"] = "Hidden"
    }

    $process = Start-Process @startProcessArgs
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $lastLength = -1
    $stableCount = 0
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $PngPath) {
            $length = (Get-Item -LiteralPath $PngPath).Length
            if ($length -gt 0 -and $length -eq $lastLength) {
                $stableCount++
            }
            else {
                $stableCount = 0
            }
            $lastLength = $length
            if ($stableCount -ge 2) {
                $process.Kill()
                $process.WaitForExit()
                break
            }
        }
    }

    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }

    if (-not (Test-Path -LiteralPath $PngPath)) {
        throw "Browser render did not create PNG: $PngPath"
    }
}

if ($RendererPath) {
    $renderer = $RendererPath
}
else {
    $renderer = Join-Path (Split-Path -Parent $PSScriptRoot) "03-render-from-discovery\Convert-ADForestConfigurationInventoryToSvg.py"
}
if (-not (Test-Path -LiteralPath $renderer)) {
    throw "Renderer not found: $renderer"
}

$renderer = (Resolve-Path -LiteralPath $renderer).Path
$python = Resolve-PythonCommand -RequestedCommand $PythonCommand
$csvPath = (Resolve-Path -LiteralPath $RelationshipCsv).Path
$validation = Test-ForestConfigRelationshipCsv -Path $csvPath
$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force

if ($Name) {
    $safeName = ($Name -replace '[^A-Za-z0-9._-]', '-').Trim("-")
}
else {
    $safeName = ([System.IO.Path]::GetFileNameWithoutExtension($csvPath) -replace '[^A-Za-z0-9._-]', '-').Trim("-")
}
if (-not $safeName) {
    $safeName = "forest-config"
}

$combinedSvg = Join-Path $outputDirectory.FullName "$safeName-combined.svg"
$combinedPng = Join-Path $outputDirectory.FullName "$safeName-combined.png"
$partitionsSvg = Join-Path $outputDirectory.FullName "$safeName-partitions.svg"
$partitionsPng = Join-Path $outputDirectory.FullName "$safeName-partitions.png"
$detailsCsv = Join-Path $outputDirectory.FullName "$safeName.forest-config-relationships.csv"

Invoke-ExternalCommand -FilePath $python -ArgumentList @(
    $renderer,
    "--csv", $csvPath,
    "--output", $combinedSvg,
    "--view", "combined",
    "--details-csv", $detailsCsv
)

Invoke-ExternalCommand -FilePath $python -ArgumentList @(
    $renderer,
    "--csv", $csvPath,
    "--output", $partitionsSvg,
    "--view", "partitions"
)

$browser = $null
if (-not $SkipPng) {
    $browser = Resolve-BrowserPath -RequestedPath $BrowserPath
    if ($browser) {
        Convert-SvgToPng -Browser $browser -SvgPath $combinedSvg -PngPath $combinedPng
        Convert-SvgToPng -Browser $browser -SvgPath $partitionsSvg -PngPath $partitionsPng
    }
    else {
        Write-Warning "No supported browser renderer was found. SVG files were generated, but PNG files were skipped."
    }
}

[pscustomobject]@{
    InputCsv = $csvPath
    CombinedSvg = $combinedSvg
    CombinedPng = if (Test-Path -LiteralPath $combinedPng) { $combinedPng } else { $null }
    PartitionsSvg = $partitionsSvg
    PartitionsPng = if (Test-Path -LiteralPath $partitionsPng) { $partitionsPng } else { $null }
    DetailsCsv = $detailsCsv
    RowCount = $validation.RowCount
    EdgeCount = $validation.EdgeCount
    Browser = $browser
    Python = $python
}

