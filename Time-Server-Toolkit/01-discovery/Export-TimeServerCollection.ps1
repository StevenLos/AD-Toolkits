#requires -Version 5.1
<#
.SYNOPSIS
Collects Windows Time source and time-server evidence from one or more servers.

.DESCRIPTION
Writes one self-contained *.collection.json file per queried server. Full
collection uses WinRM for remote servers so registry, service, CIM, and UDP/123
listener evidence is captured from the target itself.

Use -NoWinRM for a reduced collection based on w32tm /computer:<server>.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\input\discovery-collections",

    [Parameter()]
    [string[]]$Server = @($env:COMPUTERNAME),

    [Parameter()]
    [string]$ServerListPath,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [switch]$NoWinRM,

    [Parameter()]
    [switch]$NoClobber
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    if (-not $safe) {
        return "time-server"
    }
    return $safe
}

function ConvertTo-PlainValue {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Net.IPAddress]) {
        return $Value.IPAddressToString
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    if ($Value -is [TimeSpan]) {
        return $Value.ToString()
    }

    if ($Value.GetType().IsPrimitive -or $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-PlainValue -Value $item
        }
        return $items
    }

    return [string]$Value
}

function ConvertFrom-W32TmKeyValue {
    param([Parameter()][string[]]$Lines)

    $map = [ordered]@{}
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*([^:]+):\s*(.*)$') {
            $key = ($matches[1].Trim() -replace '\s+', '')
            $value = $matches[2].Trim()
            if ($map.Contains($key)) {
                $key = "$key$($map.Count)"
            }
            $map[$key] = $value
        }
    }

    return [pscustomobject]$map
}

function Get-W32TmValue {
    param(
        [Parameter()][object]$Values,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Values) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Values.PSObject.Properties[$name]
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function Split-TimePeerList {
    param([Parameter()][string]$PeerText)

    if (-not $PeerText) {
        return @()
    }

    $peers = @()
    foreach ($entry in ($PeerText -split '\s+')) {
        $trimmed = $entry.Trim()
        if (-not $trimmed) {
            continue
        }

        $parts = $trimmed -split ',', 2
        $peers += [pscustomobject]@{
            PeerName = $parts[0]
            Flags = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            Raw = $trimmed
        }
    }

    return $peers
}

function ConvertFrom-W32TmPeers {
    param([Parameter()][string[]]$Lines)

    $peers = @()
    $current = $null
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*Peer:\s*(.+)\s*$') {
            if ($current) {
                $peers += [pscustomobject]$current
            }
            $current = [ordered]@{
                Peer = $matches[1].Trim()
            }
            continue
        }

        if ($current -and $line -match '^\s*([^:]+):\s*(.*)$') {
            $key = ($matches[1].Trim() -replace '\s+', '')
            $current[$key] = $matches[2].Trim()
        }
    }

    if ($current) {
        $peers += [pscustomobject]$current
    }

    return $peers
}

function Test-EnabledValue {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    $text = ([string]$Value).Trim()
    return $text -in @("1", "true", "True", "TRUE", "yes", "Yes", "enabled", "Enabled")
}

function Get-NumericPrefix {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ($text -match '^[-+]?\d+(\.\d+)?') {
        return $matches[0]
    }

    return $text
}

function Test-IsLocalComputer {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $name = $ComputerName.Trim()
    if ($name -in @(".", "localhost", "127.0.0.1", "::1", $env:COMPUTERNAME)) {
        return $true
    }

    if ($env:USERDNSDOMAIN) {
        $fqdn = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
        if ($name -ieq $fqdn) {
            return $true
        }
    }

    return $false
}

function New-CommandResult {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][int]$ExitCode = 0,
        [Parameter()][string[]]$Lines = @()
    )

    [pscustomobject]@{
        Command = $Command
        ExitCode = $ExitCode
        Lines = @($Lines)
        Raw = (@($Lines) -join [Environment]::NewLine)
    }
}

function Invoke-W32TmCommand {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

    $output = @(& w32tm @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    return New-CommandResult -Command "w32tm $($ArgumentList -join ' ')" -ExitCode $exitCode -Lines $output
}

function Invoke-RemoteW32TmCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string[]]$QueryArguments
    )

    $arguments = @("/query", "/computer:$ComputerName") + $QueryArguments
    return Invoke-W32TmCommand -ArgumentList $arguments
}

function Get-LimitedTimeProbe {
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $status = Invoke-RemoteW32TmCommand -ComputerName $ComputerName -QueryArguments @("/status", "/verbose")
    $source = Invoke-RemoteW32TmCommand -ComputerName $ComputerName -QueryArguments @("/source")
    $configuration = Invoke-RemoteW32TmCommand -ComputerName $ComputerName -QueryArguments @("/configuration")
    $peers = Invoke-RemoteW32TmCommand -ComputerName $ComputerName -QueryArguments @("/peers")

    $statusValues = ConvertFrom-W32TmKeyValue -Lines $status.Lines
    $activeSource = (($source.Lines | Where-Object { $_.Trim() } | Select-Object -First 1) -as [string])
    if (-not $activeSource) {
        $activeSource = Get-W32TmValue -Values $statusValues -Names @("Source")
    }

    $type = $null
    $configValues = ConvertFrom-W32TmKeyValue -Lines $configuration.Lines
    $type = Get-W32TmValue -Values $configValues -Names @("Type")
    $manualPeers = @(Split-TimePeerList -PeerText (Get-W32TmValue -Values $configValues -Names @("NtpServer")))

    $sourceType = "Unknown"
    if ($activeSource -match 'Local CMOS|Free-running|LOCL|Local Clock') {
        $sourceType = "LocalClock"
    }
    elseif ($activeSource -match 'VM IC|VMICTime|Hyper-V|Hypervisor') {
        $sourceType = "Hypervisor"
    }
    elseif ($type -eq "NT5DS") {
        $sourceType = "DomainHierarchy"
    }
    elseif ($type -eq "NTP" -or $manualPeers.Count -gt 0) {
        $sourceType = "ManualNtp"
    }
    elseif ($type -eq "NoSync") {
        $sourceType = "None"
    }

    [pscustomobject]@{
        ServerIdentity = [pscustomobject]@{
            QueriedServer = $ComputerName
            ComputerName = $ComputerName
            Fqdn = $null
            IPAddresses = @()
            Domain = $null
            DomainRole = $null
            OperatingSystem = $null
        }
        TimeService = $null
        Registry = $null
        Network = [pscustomobject]@{
            Udp123Listening = $null
            Udp123LocalAddresses = @()
        }
        W32Tm = [pscustomobject]@{
            Status = [pscustomobject]@{
                Command = $status.Command
                ExitCode = $status.ExitCode
                Values = $statusValues
                Raw = $status.Raw
            }
            Source = [pscustomobject]@{
                Command = $source.Command
                ExitCode = $source.ExitCode
                Value = $activeSource
                Raw = $source.Raw
            }
            Configuration = [pscustomobject]@{
                Command = $configuration.Command
                ExitCode = $configuration.ExitCode
                Values = $configValues
                Raw = $configuration.Raw
            }
            Peers = [pscustomobject]@{
                Command = $peers.Command
                ExitCode = $peers.ExitCode
                Values = @(ConvertFrom-W32TmPeers -Lines $peers.Lines)
                Raw = $peers.Raw
            }
        }
        ManualPeers = $manualPeers
        Classification = [pscustomobject]@{
            IsTimeServer = $null
            Source = $activeSource
            SourceType = $sourceType
            W32TimeType = $type
            NtpServerEnabled = $null
            NtpClientEnabled = $null
            Udp123Listening = $null
            Stratum = Get-NumericPrefix -Value (Get-W32TmValue -Values $statusValues -Names @("Stratum"))
            LastSuccessfulSyncTime = Get-W32TmValue -Values $statusValues -Names @("LastSuccessfulSyncTime")
            Offset = Get-W32TmValue -Values $statusValues -Names @("PhaseOffset", "ClockOffset")
            Evidence = @("Reduced collection: remote w32tm only")
        }
        CollectionWarnings = @(
            [pscustomobject]@{
                Step = "NoWinRM"
                Message = "Reduced collection was used. Registry, service, CIM, and UDP/123 listener evidence were not captured."
            }
        )
    }
}

$timeProbeScript = {
    param([Parameter(Mandatory = $true)][string]$QueriedServer)

    Set-StrictMode -Version 2.0
    $ErrorActionPreference = "Stop"
    $warnings = @()

    function Add-Warning {
        param(
            [Parameter(Mandatory = $true)][string]$Step,
            [Parameter(Mandatory = $true)][string]$Message
        )

        $script:warnings += [pscustomobject]@{
            Step = $Step
            Message = $Message
        }
    }

    function ConvertTo-PlainValue {
        param([Parameter()][object]$Value)

        if ($null -eq $Value) {
            return $null
        }

        if ($Value -is [string]) {
            return $Value
        }

        if ($Value -is [System.Net.IPAddress]) {
            return $Value.IPAddressToString
        }

        if ($Value -is [DateTime]) {
            return $Value.ToUniversalTime().ToString("o")
        }

        if ($Value -is [TimeSpan]) {
            return $Value.ToString()
        }

        if ($Value.GetType().IsPrimitive -or $Value -is [decimal]) {
            return $Value
        }

        if ($Value -is [System.Collections.IEnumerable]) {
            $items = @()
            foreach ($item in $Value) {
                $items += ConvertTo-PlainValue -Value $item
            }
            return $items
        }

        return [string]$Value
    }

    function ConvertFrom-W32TmKeyValue {
        param([Parameter()][string[]]$Lines)

        $map = [ordered]@{}
        foreach ($line in @($Lines)) {
            if ($line -match '^\s*([^:]+):\s*(.*)$') {
                $key = ($matches[1].Trim() -replace '\s+', '')
                $value = $matches[2].Trim()
                if ($map.Contains($key)) {
                    $key = "$key$($map.Count)"
                }
                $map[$key] = $value
            }
        }

        return [pscustomobject]$map
    }

    function Get-W32TmValue {
        param(
            [Parameter()][object]$Values,
            [Parameter(Mandatory = $true)][string[]]$Names
        )

        if ($null -eq $Values) {
            return $null
        }

        foreach ($name in $Names) {
            $property = $Values.PSObject.Properties[$name]
            if ($property) {
                return $property.Value
            }
        }

        return $null
    }

    function Split-TimePeerList {
        param([Parameter()][string]$PeerText)

        if (-not $PeerText) {
            return @()
        }

        $peers = @()
        foreach ($entry in ($PeerText -split '\s+')) {
            $trimmed = $entry.Trim()
            if (-not $trimmed) {
                continue
            }

            $parts = $trimmed -split ',', 2
            $peers += [pscustomobject]@{
                PeerName = $parts[0]
                Flags = if ($parts.Count -gt 1) { $parts[1] } else { "" }
                Raw = $trimmed
            }
        }

        return $peers
    }

    function ConvertFrom-W32TmPeers {
        param([Parameter()][string[]]$Lines)

        $peers = @()
        $current = $null
        foreach ($line in @($Lines)) {
            if ($line -match '^\s*Peer:\s*(.+)\s*$') {
                if ($current) {
                    $peers += [pscustomobject]$current
                }
                $current = [ordered]@{
                    Peer = $matches[1].Trim()
                }
                continue
            }

            if ($current -and $line -match '^\s*([^:]+):\s*(.*)$') {
                $key = ($matches[1].Trim() -replace '\s+', '')
                $current[$key] = $matches[2].Trim()
            }
        }

        if ($current) {
            $peers += [pscustomobject]$current
        }

        return $peers
    }

    function Test-EnabledValue {
        param([Parameter()][object]$Value)

        if ($null -eq $Value) {
            return $false
        }

        $text = ([string]$Value).Trim()
        return $text -in @("1", "true", "True", "TRUE", "yes", "Yes", "enabled", "Enabled")
    }

    function Get-NumericPrefix {
        param([Parameter()][object]$Value)

        if ($null -eq $Value) {
            return $null
        }

        $text = ([string]$Value).Trim()
        if ($text -match '^[-+]?\d+(\.\d+)?') {
            return $matches[0]
        }

        return $text
    }

    function Invoke-Step {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
        )

        try {
            return & $ScriptBlock
        }
        catch {
            Add-Warning -Step $Name -Message $_.Exception.Message
            return $null
        }
    }

    function Invoke-W32TmCommand {
        param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

        try {
            $output = @(& w32tm @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        catch {
            $output = @($_.Exception.Message)
            $exitCode = 1
        }

        [pscustomobject]@{
            Command = "w32tm $($ArgumentList -join ' ')"
            ExitCode = $exitCode
            Lines = @($output)
            Raw = (@($output) -join [Environment]::NewLine)
        }
    }

    function Get-RegistryPathValues {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string[]]$Names
        )

        $values = [ordered]@{}
        $item = Invoke-Step -Name "Read registry $Path" -ScriptBlock {
            Get-ItemProperty -LiteralPath $Path
        }

        foreach ($name in $Names) {
            $value = $null
            if ($item -and $item.PSObject.Properties[$name]) {
                $value = ConvertTo-PlainValue -Value $item.$name
            }
            $values[$name] = $value
        }

        return [pscustomobject]$values
    }

    function Resolve-LocalAddresses {
        param([Parameter(Mandatory = $true)][string]$Name)

        try {
            return @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString })
        }
        catch {
            Add-Warning -Step "Resolve DNS $Name" -Message $_.Exception.Message
            return @()
        }
    }

    function Get-SourceType {
        param(
            [Parameter()][string]$Source,
            [Parameter()][string]$W32TimeType,
            [Parameter()][object[]]$ManualPeers,
            [Parameter()][object]$VmicEnabled
        )

        $sourceText = ([string]$Source).Trim()
        if (-not $sourceText -or $sourceText -eq "Local CMOS Clock") {
            if ($sourceText) {
                return "LocalClock"
            }
        }

        if ($sourceText -match 'Local CMOS|Free-running|LOCL|Local Clock') {
            return "LocalClock"
        }

        if ($sourceText -match 'VM IC|VMICTime|Hyper-V|Hypervisor') {
            return "Hypervisor"
        }

        if ($W32TimeType -eq "NT5DS") {
            return "DomainHierarchy"
        }

        if ($W32TimeType -eq "NTP" -or @($ManualPeers).Count -gt 0) {
            return "ManualNtp"
        }

        if ($W32TimeType -eq "NoSync") {
            return "None"
        }

        if (Test-EnabledValue -Value $VmicEnabled) {
            return "HypervisorCandidate"
        }

        return "Unknown"
    }

    $computerSystem = Invoke-Step -Name "Get-CimInstance Win32_ComputerSystem" -ScriptBlock {
        Get-CimInstance -ClassName Win32_ComputerSystem
    }
    $operatingSystem = Invoke-Step -Name "Get-CimInstance Win32_OperatingSystem" -ScriptBlock {
        Get-CimInstance -ClassName Win32_OperatingSystem
    }
    $service = Invoke-Step -Name "Get-Service W32Time" -ScriptBlock {
        Get-Service -Name W32Time
    }

    $status = Invoke-W32TmCommand -ArgumentList @("/query", "/status", "/verbose")
    $source = Invoke-W32TmCommand -ArgumentList @("/query", "/source")
    $configuration = Invoke-W32TmCommand -ArgumentList @("/query", "/configuration")
    $peers = Invoke-W32TmCommand -ArgumentList @("/query", "/peers")

    $statusValues = ConvertFrom-W32TmKeyValue -Lines $status.Lines
    $configValues = ConvertFrom-W32TmKeyValue -Lines $configuration.Lines
    $peerValues = @(ConvertFrom-W32TmPeers -Lines $peers.Lines)

    $parameters = Get-RegistryPathValues -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -Names @(
        "Type",
        "NtpServer",
        "ServiceDll",
        "ServiceDllUnloadOnStop"
    )
    $config = Get-RegistryPathValues -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -Names @(
        "AnnounceFlags",
        "LocalClockDispersion",
        "MaxNegPhaseCorrection",
        "MaxPosPhaseCorrection",
        "MinPollInterval",
        "MaxPollInterval",
        "UpdateInterval",
        "FrequencyCorrectRate",
        "HoldPeriod",
        "LargePhaseOffset"
    )
    $ntpClient = Get-RegistryPathValues -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" -Names @(
        "Enabled",
        "SpecialPollInterval",
        "EventLogFlags",
        "ResolvePeerBackoffMinutes",
        "ResolvePeerBackoffMaxTimes",
        "CrossSiteSyncFlags"
    )
    $ntpServer = Get-RegistryPathValues -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer" -Names @(
        "Enabled",
        "InputProvider",
        "AllowNonstandardModeCombinations"
    )
    $vmic = Get-RegistryPathValues -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider" -Names @(
        "Enabled",
        "InputProvider"
    )

    $udpEndpoints = Invoke-Step -Name "Get-NetUDPEndpoint UDP/123" -ScriptBlock {
        if (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue) {
            @(Get-NetUDPEndpoint -LocalPort 123 -ErrorAction Stop)
        }
        else {
            @()
        }
    }
    if ($null -eq $udpEndpoints) {
        $udpEndpoints = @()
    }

    $sourceValue = (($source.Lines | Where-Object { $_.Trim() } | Select-Object -First 1) -as [string])
    if (-not $sourceValue) {
        $sourceValue = Get-W32TmValue -Values $statusValues -Names @("Source")
    }

    $w32TimeType = $parameters.Type
    if (-not $w32TimeType) {
        $w32TimeType = Get-W32TmValue -Values $configValues -Names @("Type")
    }

    $manualPeers = @(Split-TimePeerList -PeerText $parameters.NtpServer)
    if ($manualPeers.Count -eq 0) {
        $manualPeers = @(Split-TimePeerList -PeerText (Get-W32TmValue -Values $configValues -Names @("NtpServer")))
    }

    $ntpServerEnabled = Test-EnabledValue -Value $ntpServer.Enabled
    $ntpClientEnabled = Test-EnabledValue -Value $ntpClient.Enabled
    $udp123Listening = @($udpEndpoints).Count -gt 0
    $serviceStatus = if ($service) { [string]$service.Status } else { $null }
    $serviceRunning = $serviceStatus -eq "Running"
    $domainRole = if ($computerSystem) { ConvertTo-PlainValue -Value $computerSystem.DomainRole } else { $null }
    $isDomainController = $domainRole -in @(4, 5)

    $evidence = @()
    if ($serviceRunning) {
        $evidence += "W32Time service is running"
    }
    if ($ntpServerEnabled) {
        $evidence += "NtpServer provider is enabled"
    }
    if ($udp123Listening) {
        $evidence += "UDP/123 is listening"
    }
    if ($isDomainController) {
        $evidence += "Domain role indicates domain controller"
    }
    if ($evidence.Count -eq 0) {
        $evidence += "No time-server evidence found"
    }

    $isTimeServer = $serviceRunning -and ($ntpServerEnabled -or $udp123Listening -or $isDomainController)
    $sourceType = Get-SourceType -Source $sourceValue -W32TimeType $w32TimeType -ManualPeers $manualPeers -VmicEnabled $vmic.Enabled

    $hostEntry = Invoke-Step -Name "Resolve local host entry" -ScriptBlock {
        [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
    }

    [pscustomobject]@{
        ServerIdentity = [pscustomobject]@{
            QueriedServer = $QueriedServer
            ComputerName = $env:COMPUTERNAME
            Fqdn = if ($hostEntry) { $hostEntry.HostName } else { $null }
            IPAddresses = Resolve-LocalAddresses -Name $env:COMPUTERNAME
            Domain = if ($computerSystem) { ConvertTo-PlainValue -Value $computerSystem.Domain } else { $null }
            DomainRole = $domainRole
            Manufacturer = if ($computerSystem) { ConvertTo-PlainValue -Value $computerSystem.Manufacturer } else { $null }
            Model = if ($computerSystem) { ConvertTo-PlainValue -Value $computerSystem.Model } else { $null }
            OperatingSystem = if ($operatingSystem) { ConvertTo-PlainValue -Value $operatingSystem.Caption } else { $null }
            OperatingSystemVersion = if ($operatingSystem) { ConvertTo-PlainValue -Value $operatingSystem.Version } else { $null }
        }
        TimeService = if ($service) {
            [pscustomobject]@{
                Name = $service.Name
                DisplayName = $service.DisplayName
                Status = [string]$service.Status
                StartType = ConvertTo-PlainValue -Value $service.StartType
                ServiceType = ConvertTo-PlainValue -Value $service.ServiceType
            }
        }
        else {
            $null
        }
        Registry = [pscustomobject]@{
            Parameters = $parameters
            Config = $config
            TimeProviders = [pscustomobject]@{
                NtpClient = $ntpClient
                NtpServer = $ntpServer
                VMICTimeProvider = $vmic
            }
        }
        Network = [pscustomobject]@{
            Udp123Listening = $udp123Listening
            Udp123LocalAddresses = @($udpEndpoints | ForEach-Object { ConvertTo-PlainValue -Value $_.LocalAddress })
        }
        W32Tm = [pscustomobject]@{
            Status = [pscustomobject]@{
                Command = $status.Command
                ExitCode = $status.ExitCode
                Values = $statusValues
                Raw = $status.Raw
            }
            Source = [pscustomobject]@{
                Command = $source.Command
                ExitCode = $source.ExitCode
                Value = $sourceValue
                Raw = $source.Raw
            }
            Configuration = [pscustomobject]@{
                Command = $configuration.Command
                ExitCode = $configuration.ExitCode
                Values = $configValues
                Raw = $configuration.Raw
            }
            Peers = [pscustomobject]@{
                Command = $peers.Command
                ExitCode = $peers.ExitCode
                Values = $peerValues
                Raw = $peers.Raw
            }
        }
        ManualPeers = $manualPeers
        Classification = [pscustomobject]@{
            IsTimeServer = $isTimeServer
            Source = $sourceValue
            SourceType = $sourceType
            W32TimeType = $w32TimeType
            NtpServerEnabled = $ntpServerEnabled
            NtpClientEnabled = $ntpClientEnabled
            Udp123Listening = $udp123Listening
            Stratum = Get-NumericPrefix -Value (Get-W32TmValue -Values $statusValues -Names @("Stratum"))
            LastSuccessfulSyncTime = Get-W32TmValue -Values $statusValues -Names @("LastSuccessfulSyncTime")
            Offset = Get-W32TmValue -Values $statusValues -Names @("PhaseOffset", "ClockOffset")
            Evidence = $evidence
        }
        CollectionWarnings = $warnings
    }
}

$targets = @()
foreach ($item in @($Server)) {
    if ($item -and $item.Trim()) {
        $targets += $item.Trim()
    }
}

if ($ServerListPath) {
    $resolvedServerList = Resolve-Path -LiteralPath $ServerListPath
    $targets += @(Get-Content -LiteralPath $resolvedServerList.Path | Where-Object {
        $_ -and $_.Trim() -and -not $_.Trim().StartsWith("#")
    } | ForEach-Object { $_.Trim() })
}

$targets = @($targets | Select-Object -Unique)
if ($targets.Count -eq 0) {
    throw "No servers were provided."
}

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$results = @()

foreach ($target in $targets) {
    $collectionStartedUtc = [DateTime]::UtcNow
    $timestamp = $collectionStartedUtc.ToString("yyyyMMddTHHmmssZ")
    $collectionWarnings = @()
    $collectionErrors = @()

    $collection = [ordered]@{
        Metadata = [ordered]@{
            CollectionType = "WindowsTimeServer"
            CollectorComputer = $env:COMPUTERNAME
            CollectorUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            QueriedServer = $target
            TimestampUtc = $collectionStartedUtc.ToString("o")
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            CollectionStatus = "Started"
            CollectionStartedUtc = $collectionStartedUtc.ToString("o")
            CollectionCompletedUtc = $null
            CollectionMode = if ((Test-IsLocalComputer -ComputerName $target) -or -not $NoWinRM) { "WinRMOrLocal" } else { "ReducedW32TmRemote" }
        }
        ServerIdentity = $null
        TimeService = $null
        Registry = $null
        Network = $null
        W32Tm = $null
        ManualPeers = @()
        Classification = $null
        CollectionWarnings = @()
        CollectionErrors = @()
    }

    try {
        if (Test-IsLocalComputer -ComputerName $target) {
            $probe = & $timeProbeScript -QueriedServer $target
        }
        elseif ($NoWinRM) {
            $probe = Get-LimitedTimeProbe -ComputerName $target
        }
        else {
            $invokeParams = @{
                ComputerName = $target
                ScriptBlock = $timeProbeScript
                ArgumentList = @($target)
                ErrorAction = "Stop"
            }
            if ($Credential) {
                $invokeParams["Credential"] = $Credential
            }
            $probe = Invoke-Command @invokeParams
        }

        $collection.ServerIdentity = $probe.ServerIdentity
        $collection.TimeService = $probe.TimeService
        $collection.Registry = $probe.Registry
        $collection.Network = $probe.Network
        $collection.W32Tm = $probe.W32Tm
        $collection.ManualPeers = @($probe.ManualPeers)
        $collection.Classification = $probe.Classification
        $collectionWarnings += @($probe.CollectionWarnings)
    }
    catch {
        $collectionErrors += [pscustomobject]@{
            Step = "Collect $target"
            Message = $_.Exception.Message
        }
    }

    $collectionCompletedUtc = [DateTime]::UtcNow
    $collection.Metadata.CollectionCompletedUtc = $collectionCompletedUtc.ToString("o")
    if ($collectionErrors.Count -gt 0) {
        $collection.Metadata.CollectionStatus = "Failed"
    }
    elseif ($collectionWarnings.Count -gt 0) {
        $collection.Metadata.CollectionStatus = "Partial"
    }
    else {
        $collection.Metadata.CollectionStatus = "Success"
    }

    $collection.CollectionWarnings = $collectionWarnings
    $collection.CollectionErrors = $collectionErrors

    $safeServer = ConvertTo-SafeFileName -Value $target
    $outputFile = Join-Path $outputDirectory.FullName "$safeServer.$timestamp.collection.json"
    if ($NoClobber -and (Test-Path -LiteralPath $outputFile)) {
        throw "Collection file already exists: $outputFile"
    }

    $collectionJson = ([pscustomobject]$collection) | ConvertTo-Json -Depth 60
    Set-Content -LiteralPath $outputFile -Value $collectionJson -Encoding UTF8

    $results += [pscustomobject]@{
        CollectionFile = $outputFile
        QueriedServer = $target
        Status = $collection.Metadata.CollectionStatus
        IsTimeServer = if ($collection.Classification) { $collection.Classification.IsTimeServer } else { $null }
        Source = if ($collection.Classification) { $collection.Classification.Source } else { $null }
        SourceType = if ($collection.Classification) { $collection.Classification.SourceType } else { $null }
        WarningCount = @($collection.CollectionWarnings).Count
        ErrorCount = @($collection.CollectionErrors).Count
    }
}

$results

