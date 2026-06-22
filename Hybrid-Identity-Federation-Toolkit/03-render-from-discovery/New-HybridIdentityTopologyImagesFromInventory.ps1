[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InventoryJson,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Name = "current-state",

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
    $userDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hybrid-identity-render-" + [System.Guid]::NewGuid().ToString("N"))
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
    $renderer = Join-Path $PSScriptRoot "Convert-HybridIdentityInventoryToSvg.py"
}
if (-not (Test-Path -LiteralPath $renderer)) {
    throw "Renderer not found: $renderer"
}

$renderer = (Resolve-Path -LiteralPath $renderer).Path
$python = Resolve-PythonCommand -RequestedCommand $PythonCommand
$inventoryPath = (Resolve-Path -LiteralPath $InventoryJson).Path
$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$safeName = ($Name -replace '[^A-Za-z0-9._-]', '-').Trim("-")
if (-not $safeName) {
    $safeName = "current-state"
}

Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json | Out-Null

$combinedSvg = Join-Path $outputDirectory.FullName "$safeName-combined.svg"
$combinedPng = Join-Path $outputDirectory.FullName "$safeName-combined.png"
$federationSvg = Join-Path $outputDirectory.FullName "$safeName-federation.svg"
$federationPng = Join-Path $outputDirectory.FullName "$safeName-federation.png"
$detailsCsv = Join-Path $outputDirectory.FullName "$safeName.topology-relationships.csv"

Invoke-ExternalCommand -FilePath $python -ArgumentList @(
    $renderer,
    "--inventory", $inventoryPath,
    "--output", $combinedSvg,
    "--view", "combined",
    "--details-csv", $detailsCsv
)

Invoke-ExternalCommand -FilePath $python -ArgumentList @(
    $renderer,
    "--inventory", $inventoryPath,
    "--output", $federationSvg,
    "--view", "federation"
)

$browser = $null
if (-not $SkipPng) {
    $browser = Resolve-BrowserPath -RequestedPath $BrowserPath
    if ($browser) {
        Convert-SvgToPng -Browser $browser -SvgPath $combinedSvg -PngPath $combinedPng
        Convert-SvgToPng -Browser $browser -SvgPath $federationSvg -PngPath $federationPng
    }
    else {
        Write-Warning "No supported browser renderer was found. SVG files were generated, but PNG files were skipped."
    }
}

[pscustomobject]@{
    InputInventory = $inventoryPath
    CombinedSvg = $combinedSvg
    CombinedPng = if (Test-Path -LiteralPath $combinedPng) { $combinedPng } else { $null }
    FederationSvg = $federationSvg
    FederationPng = if (Test-Path -LiteralPath $federationPng) { $federationPng } else { $null }
    DetailsCsv = $detailsCsv
    Browser = $browser
    Python = $python
}
