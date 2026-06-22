#requires -Version 5.1
<#
.SYNOPSIS
Collects read-only Active Directory domain controller health and role evidence.

.DESCRIPTION
Writes one self-contained *.collection.json file for the queried forest/domain
scope. The collector reads AD metadata, selected service state, SYSVOL and
NETLOGON share presence, DC locator SRV records, FSMO role ownership, and
collector-perspective LDAP/LDAPS/GC TCP availability.

No configuration changes are made.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\input\discovery-collections",

    [Parameter()]
    [string]$Server,

    [Parameter()]
    [string]$ForestName,

    [Parameter()]
    [string[]]$DomainName,

    [Parameter()]
    [string[]]$DomainController,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [switch]$SkipServiceChecks,

    [Parameter()]
    [switch]$SkipShareChecks,

    [Parameter()]
    [switch]$SkipPortChecks,

    [Parameter()]
    [switch]$SkipSrvRecordSummary,

    [Parameter()]
    [int]$PortTimeoutMilliseconds = 1500,

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
        return "ad-dc-health"
    }
    return $safe
}

function Get-CollectorComputerName {
    if ($env:COMPUTERNAME) {
        return $env:COMPUTERNAME
    }
    return [Environment]::MachineName
}

function Get-CollectorUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return [Environment]::UserName
    }
}

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
            $plain = ConvertTo-PlainValue -Value $item
            if ($null -ne $plain -and ([string]$plain).Trim()) {
                $items += ([string]$plain).Trim()
            }
        }
    }
    else {
        $plain = ConvertTo-PlainValue -Value $Value
        if ($null -ne $plain -and ([string]$plain).Trim()) {
            $items += ([string]$plain).Trim()
        }
    }

    return $items
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

function Invoke-CollectionStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        return & $ScriptBlock
    }
    catch {
        $script:collectionWarnings += [pscustomobject]@{
            Step = $Name
            Message = $_.Exception.Message
        }
        return $null
    }
}

function Resolve-HostAddresses {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $ipv4 = @()
    $ipv6 = @()

    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses($HostName)) {
            if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $ipv4 += $address.IPAddressToString
            }
            elseif ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $ipv6 += $address.IPAddressToString
            }
        }
    }
    catch {
        $script:collectionWarnings += [pscustomobject]@{
            Step = "Resolve host addresses for $HostName"
            Message = $_.Exception.Message
        }
    }

    [pscustomobject]@{
        IPv4Addresses = @($ipv4 | Select-Object -Unique)
        IPv6Addresses = @($ipv6 | Select-Object -Unique)
    }
}

function Get-BuildNumber {
    param([Parameter()][string]$OperatingSystemVersion)

    if (-not $OperatingSystemVersion) {
        return $null
    }

    if ($OperatingSystemVersion -match '\((\d+)\)') {
        return $matches[1]
    }

    if ($OperatingSystemVersion -match '^\d+\.\d+\.(\d+)') {
        return $matches[1]
    }

    return $null
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PortName,
        [Parameter()][int]$TimeoutMilliseconds = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $started = [DateTime]::UtcNow
    $status = "Unknown"
    $open = $null
    $errorText = ""

    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)
        if (-not $connected) {
            $open = $false
            $status = "Timeout"
            $errorText = "Connection timed out after $TimeoutMilliseconds ms."
            $client.Close()
        }
        else {
            $client.EndConnect($async)
            $open = $true
            $status = "Open"
        }
    }
    catch {
        $open = $false
        $status = "Closed"
        $errorText = $_.Exception.Message
    }
    finally {
        if ($client) {
            $client.Close()
        }
    }

    $elapsed = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
    [pscustomobject]@{
        DcHostName = $ComputerName
        PortName = $PortName
        Protocol = "TCP"
        Port = $Port
        Open = $open
        Status = $status
        LatencyMilliseconds = $elapsed
        Error = $errorText
    }
}

function Test-SharePresence {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$ShareName
    )

    $uncPath = "\\$ComputerName\$ShareName"
    $present = $null
    $status = "Unknown"
    $errorText = ""

    try {
        if (Test-Path -LiteralPath $uncPath) {
            $present = $true
            $status = "Present"
        }
        else {
            $present = $false
            $status = "Missing"
        }
    }
    catch {
        $present = $null
        $status = "Unknown"
        $errorText = $_.Exception.Message
    }

    [pscustomobject]@{
        DcHostName = $ComputerName
        ShareName = $ShareName
        UncPath = $uncPath
        Present = $present
        Status = $status
        Error = $errorText
    }
}

function Get-ServiceStatesSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter()][System.Management.Automation.PSCredential]$Credential
    )

    $serviceNames = @("NTDS", "Netlogon", "DFSR", "DNS", "KDC", "W32Time")
    $rows = @()
    $session = $null
    try {
        if ($Credential) {
            $session = New-CimSession -ComputerName $ComputerName -Credential $Credential
            $services = @(Get-CimInstance -CimSession $session -ClassName Win32_Service)
        }
        else {
            $services = @(Get-CimInstance -ComputerName $ComputerName -ClassName Win32_Service)
        }

        foreach ($serviceName in $serviceNames) {
            $service = @($services | Where-Object { $_.Name -ieq $serviceName } | Select-Object -First 1)
            if ($service.Count -gt 0) {
                $item = $service[0]
                $rows += [pscustomobject]@{
                    DcHostName = $ComputerName
                    ServiceName = $serviceName
                    DisplayName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $item -Names @("DisplayName"))
                    Status = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $item -Names @("State", "Status"))
                    State = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $item -Names @("State"))
                    StartMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $item -Names @("StartMode"))
                    CheckStatus = "Collected"
                    Error = ""
                }
            }
            else {
                $rows += [pscustomobject]@{
                    DcHostName = $ComputerName
                    ServiceName = $serviceName
                    DisplayName = ""
                    Status = "NotFound"
                    State = "NotFound"
                    StartMode = ""
                    CheckStatus = "NotFound"
                    Error = ""
                }
            }
        }
    }
    catch {
        $script:collectionWarnings += [pscustomobject]@{
            Step = "Get service state for $ComputerName"
            Message = $_.Exception.Message
        }
        foreach ($serviceName in $serviceNames) {
            $rows += [pscustomobject]@{
                DcHostName = $ComputerName
                ServiceName = $serviceName
                DisplayName = ""
                Status = "Unknown"
                State = "Unknown"
                StartMode = ""
                CheckStatus = "Unknown"
                Error = $_.Exception.Message
            }
        }
    }
    finally {
        if ($session) {
            Remove-CimSession -CimSession $session
        }
    }

    return $rows
}

function Resolve-SrvRecordSummary {
    param(
        [Parameter(Mandatory = $true)][object[]]$QueryDefinitions
    )

    $rows = @()
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        $script:collectionWarnings += [pscustomobject]@{
            Step = "Resolve-DnsName"
            Message = "Resolve-DnsName is not available; DC locator SRV record summary was skipped."
        }
        return $rows
    }

    foreach ($query in @($QueryDefinitions)) {
        $queryName = [string]$query.QueryName
        if (-not $queryName) {
            continue
        }

        try {
            $records = @(Resolve-DnsName -Name $queryName -Type SRV -ErrorAction Stop)
            if ($records.Count -eq 0) {
                $rows += [pscustomobject]@{
                    QueryName = $queryName
                    Service = $query.Service
                    Scope = $query.Scope
                    DomainName = $query.DomainName
                    SiteName = $query.SiteName
                    NameTarget = ""
                    Port = ""
                    Priority = ""
                    Weight = ""
                    QueryStatus = "NoRecords"
                    Error = ""
                }
                continue
            }

            foreach ($record in @($records)) {
                $rows += [pscustomobject]@{
                    QueryName = $queryName
                    Service = $query.Service
                    Scope = $query.Scope
                    DomainName = $query.DomainName
                    SiteName = $query.SiteName
                    NameTarget = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("NameTarget"))
                    Port = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Port"))
                    Priority = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Priority"))
                    Weight = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Weight"))
                    QueryStatus = "Resolved"
                    Error = ""
                }
            }
        }
        catch {
            $rows += [pscustomobject]@{
                QueryName = $queryName
                Service = $query.Service
                Scope = $query.Scope
                DomainName = $query.DomainName
                SiteName = $query.SiteName
                NameTarget = ""
                Port = ""
                Priority = ""
                Weight = ""
                QueryStatus = "Error"
                Error = $_.Exception.Message
            }
            $script:collectionWarnings += [pscustomobject]@{
                Step = "Resolve-DnsName $queryName SRV"
                Message = $_.Exception.Message
            }
        }
    }

    return $rows
}

function Test-RequestedDomainController {
    param(
        [Parameter(Mandatory = $true)][object]$DomainControllerObject,
        [Parameter(Mandatory = $true)][string[]]$RequestedNames
    )

    if ($RequestedNames.Count -eq 0) {
        return $true
    }

    $candidateKeys = @()
    foreach ($value in @(
            (Get-ObjectPropertyValue -InputObject $DomainControllerObject -Names @("HostName")),
            (Get-ObjectPropertyValue -InputObject $DomainControllerObject -Names @("Name"))
        )) {
        foreach ($key in (Get-NameKeys -Name ([string]$value))) {
            $candidateKeys += $key
        }
    }

    foreach ($requestedName in $RequestedNames) {
        foreach ($key in (Get-NameKeys -Name $requestedName)) {
            if ($candidateKeys -contains $key) {
                return $true
            }
        }
    }

    return $false
}

$collectionStartedUtc = [DateTime]::UtcNow
$timestamp = $collectionStartedUtc.ToString("yyyyMMddTHHmmssZ")
$collectionWarnings = @()
$collectionErrors = @()

if ($PortTimeoutMilliseconds -lt 250) {
    throw "PortTimeoutMilliseconds must be at least 250."
}

$collection = [ordered]@{
    Metadata = [ordered]@{
        CollectionType = "ADDomainControllerHealth"
        CollectorComputer = Get-CollectorComputerName
        CollectorUser = Get-CollectorUserName
        Server = $Server
        ForestName = $ForestName
        DomainName = $DomainName
        DomainController = $DomainController
        CredentialUsed = [bool]$Credential
        TimestampUtc = $collectionStartedUtc.ToString("o")
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ActiveDirectoryModuleVersion = $null
        CollectionStatus = "Started"
        CollectionStartedUtc = $collectionStartedUtc.ToString("o")
        CollectionCompletedUtc = $null
        ResolvedForestName = $null
        ResolvedDomainNames = @()
    }
    Forest = $null
    Domains = @()
    DomainControllers = @()
    FSMORoles = @()
    Services = @()
    Shares = @()
    PortChecks = @()
    SrvRecords = @()
    CollectionWarnings = @()
    CollectionErrors = @()
}

try {
    $adModule = Import-Module ActiveDirectory -PassThru -ErrorAction Stop
    if ($adModule) {
        $collection.Metadata.ActiveDirectoryModuleVersion = @($adModule)[0].Version.ToString()
    }

    $adParams = @{}
    if ($Server) {
        $adParams["Server"] = $Server
    }
    if ($Credential) {
        $adParams["Credential"] = $Credential
    }

    $forestParams = @{} + $adParams
    if ($ForestName) {
        $forestParams["Identity"] = $ForestName
    }
    $forest = Invoke-CollectionStep -Name "Get-ADForest" -ScriptBlock {
        Get-ADForest @forestParams
    }

    if ($forest) {
        $collection.Metadata.ResolvedForestName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Name"))
        $collection.Forest = [pscustomobject]@{
            Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Name"))
            RootDomain = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("RootDomain"))
            ForestMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("ForestMode"))
            Domains = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Domains"))
            GlobalCatalogs = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("GlobalCatalogs"))
            SchemaMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("SchemaMaster"))
            DomainNamingMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("DomainNamingMaster"))
        }
    }

    $domainNamesToQuery = @()
    if ($DomainName -and $DomainName.Count -gt 0) {
        $domainNamesToQuery = @($DomainName)
    }
    elseif ($forest) {
        $domainNamesToQuery = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Domains")))
    }
    else {
        $domain = Invoke-CollectionStep -Name "Get-ADDomain" -ScriptBlock {
            Get-ADDomain @adParams
        }
        $domainRoot = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DNSRoot", "Name"))
        if ($domainRoot) {
            $domainNamesToQuery += $domainRoot
        }
    }

    foreach ($domainNameToQuery in @($domainNamesToQuery | Where-Object { $_ } | Select-Object -Unique)) {
        $domainParams = @{}
        if ($Credential) {
            $domainParams["Credential"] = $Credential
        }
        if ($Server) {
            $domainParams["Server"] = $Server
        }
        else {
            $domainParams["Server"] = $domainNameToQuery
        }

        $domainObject = Invoke-CollectionStep -Name "Get-ADDomain $domainNameToQuery" -ScriptBlock {
            Get-ADDomain -Identity $domainNameToQuery @domainParams
        }
        if (-not $domainObject) {
            continue
        }

        $domainDnsRoot = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("DNSRoot", "Name"))
        $collection.Metadata.ResolvedDomainNames += $domainDnsRoot
        $collection.Domains += [pscustomobject]@{
            DomainName = $domainDnsRoot
            NetBIOSName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("NetBIOSName"))
            DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("DistinguishedName"))
            DomainMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("DomainMode"))
            PDCEmulator = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("PDCEmulator"))
            RIDMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("RIDMaster"))
            InfrastructureMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domainObject -Names @("InfrastructureMaster"))
        }

        $dcParams = @{}
        if ($Credential) {
            $dcParams["Credential"] = $Credential
        }
        if ($Server) {
            $dcParams["Server"] = $Server
        }
        else {
            $dcParams["Server"] = $domainNameToQuery
        }

        $dcObjects = Invoke-CollectionStep -Name "Get-ADDomainController $domainNameToQuery" -ScriptBlock {
            @(Get-ADDomainController -Filter * @dcParams)
        }

        foreach ($dc in @($dcObjects)) {
            $hostName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
            if (-not $hostName) {
                continue
            }

            $computerIdentity = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("ComputerObjectDN", "DistinguishedName", "Name"))
            $computerObject = $null
            if ($computerIdentity) {
                $computerParams = @{}
                if ($Credential) {
                    $computerParams["Credential"] = $Credential
                }
                if ($Server) {
                    $computerParams["Server"] = $Server
                }
                else {
                    $computerParams["Server"] = $domainNameToQuery
                }
                $computerObject = Invoke-CollectionStep -Name "Get-ADComputer $hostName" -ScriptBlock {
                    Get-ADComputer -Identity $computerIdentity -Properties Enabled,OperatingSystem,OperatingSystemVersion,DNSHostName,IPv4Address,UserAccountControl,ServicePrincipalName @computerParams
                }
            }

            $resolved = Resolve-HostAddresses -HostName $hostName
            $ipv4 = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IPv4Address"))
            if ($ipv4.Count -eq 0) {
                $ipv4 = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("IPv4Address"))
            }
            if ($ipv4.Count -eq 0 -and $resolved.IPv4Addresses.Count -gt 0) {
                $ipv4 = $resolved.IPv4Addresses
            }

            $osVersion = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("OperatingSystemVersion"))
            if (-not $osVersion) {
                $osVersion = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("OperatingSystemVersion"))
            }

            $collection.DomainControllers += [pscustomobject]@{
                Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Name"))
                HostName = $hostName
                DomainName = $domainDnsRoot
                ForestName = $collection.Metadata.ResolvedForestName
                SiteName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Site"))
                IPv4Addresses = @($ipv4 | Select-Object -Unique)
                IPv6Addresses = @($resolved.IPv6Addresses | Select-Object -Unique)
                IsGlobalCatalog = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IsGlobalCatalog"))
                IsReadOnly = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IsReadOnly"))
                Enabled = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("Enabled"))
                OperatingSystem = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("OperatingSystem"))
                OperatingSystemVersion = $osVersion
                BuildNumber = Get-BuildNumber -OperatingSystemVersion $osVersion
                OperationMasterRoles = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("OperationMasterRoles"))
                LdapPort = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("LdapPort"))
                SslPort = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("SslPort"))
                ComputerObjectDN = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("ComputerObjectDN"))
                DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("DistinguishedName"))
                UserAccountControl = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $computerObject -Names @("UserAccountControl"))
            }
        }
    }

    $requestedDcNames = @()
    if ($DomainController) {
        $requestedDcNames = @($DomainController | Where-Object { $_ })
    }
    if ($requestedDcNames.Count -gt 0) {
        $collection.DomainControllers = @($collection.DomainControllers | Where-Object {
            Test-RequestedDomainController -DomainControllerObject $_ -RequestedNames $requestedDcNames
        })
    }

    $portDefinitions = @(
        @{ PortName = "LDAP"; Port = 389 },
        @{ PortName = "LDAPS"; Port = 636 },
        @{ PortName = "GC"; Port = 3268 },
        @{ PortName = "GC-LDAPS"; Port = 3269 }
    )

    foreach ($dc in @($collection.DomainControllers)) {
        $hostName = [string]$dc.HostName
        if (-not $hostName) {
            continue
        }

        if (-not $SkipServiceChecks) {
            $collection.Services += @(Get-ServiceStatesSafe -ComputerName $hostName -Credential $Credential)
        }

        if (-not $SkipShareChecks) {
            foreach ($shareName in @("SYSVOL", "NETLOGON")) {
                $collection.Shares += Test-SharePresence -ComputerName $hostName -ShareName $shareName
            }
        }

        if (-not $SkipPortChecks) {
            foreach ($definition in $portDefinitions) {
                $collection.PortChecks += Test-TcpPort -ComputerName $hostName -Port $definition.Port -PortName $definition.PortName -TimeoutMilliseconds $PortTimeoutMilliseconds
            }
        }
    }

    $roleCandidates = @()
    if ($collection.Forest) {
        $roleCandidates += [pscustomobject]@{
            RoleName = "SchemaMaster"
            ScopeType = "Forest"
            ScopeName = $collection.Forest.Name
            RoleHolder = $collection.Forest.SchemaMaster
        }
        $roleCandidates += [pscustomobject]@{
            RoleName = "DomainNamingMaster"
            ScopeType = "Forest"
            ScopeName = $collection.Forest.Name
            RoleHolder = $collection.Forest.DomainNamingMaster
        }
    }

    foreach ($domainRow in @($collection.Domains)) {
        $roleCandidates += [pscustomobject]@{
            RoleName = "PDCEmulator"
            ScopeType = "Domain"
            ScopeName = $domainRow.DomainName
            RoleHolder = $domainRow.PDCEmulator
        }
        $roleCandidates += [pscustomobject]@{
            RoleName = "RIDMaster"
            ScopeType = "Domain"
            ScopeName = $domainRow.DomainName
            RoleHolder = $domainRow.RIDMaster
        }
        $roleCandidates += [pscustomobject]@{
            RoleName = "InfrastructureMaster"
            ScopeType = "Domain"
            ScopeName = $domainRow.DomainName
            RoleHolder = $domainRow.InfrastructureMaster
        }
    }

    foreach ($role in @($roleCandidates)) {
        $reachabilityStatus = "Unknown"
        $ldapOpen = $null
        $latency = $null
        $evidence = ""
        if ($SkipPortChecks) {
            $reachabilityStatus = "NotCollected"
            $evidence = "Port checks were skipped."
        }
        elseif ($role.RoleHolder) {
            $roleProbe = Test-TcpPort -ComputerName $role.RoleHolder -Port 389 -PortName "LDAP" -TimeoutMilliseconds $PortTimeoutMilliseconds
            $ldapOpen = $roleProbe.Open
            $latency = $roleProbe.LatencyMilliseconds
            if ($roleProbe.Open -eq $true) {
                $reachabilityStatus = "Reachable"
            }
            elseif ($roleProbe.Status -in @("Closed", "Timeout")) {
                $reachabilityStatus = "Unreachable"
            }
            else {
                $reachabilityStatus = "Unknown"
            }
            $evidence = "$($roleProbe.Status) $($roleProbe.Error)".Trim()
        }
        else {
            $reachabilityStatus = "MissingHolder"
            $evidence = "Role holder was blank in AD metadata."
        }

        $collection.FSMORoles += [pscustomobject]@{
            RoleName = $role.RoleName
            ScopeType = $role.ScopeType
            ScopeName = $role.ScopeName
            RoleHolder = $role.RoleHolder
            RoleHolderLdap389Open = $ldapOpen
            RoleHolderReachabilityStatus = $reachabilityStatus
            RoleHolderReachabilityLatencyMilliseconds = $latency
            RoleHolderReachabilityEvidence = $evidence
        }
    }

    if (-not $SkipSrvRecordSummary) {
        $queryDefinitions = @()
        $forestDnsName = $collection.Metadata.ResolvedForestName
        $siteNames = @($collection.DomainControllers | ForEach-Object { $_.SiteName } | Where-Object { $_ } | Select-Object -Unique)
        if ($forestDnsName) {
            $queryDefinitions += [pscustomobject]@{
                QueryName = "_ldap._tcp.dc._msdcs.$forestDnsName"
                Service = "LDAP"
                Scope = "ForestDcLocator"
                DomainName = $forestDnsName
                SiteName = ""
            }
            $queryDefinitions += [pscustomobject]@{
                QueryName = "_gc._tcp.$forestDnsName"
                Service = "GC"
                Scope = "ForestGcLocator"
                DomainName = $forestDnsName
                SiteName = ""
            }
            foreach ($siteName in $siteNames) {
                $queryDefinitions += [pscustomobject]@{
                    QueryName = "_ldap._tcp.$siteName._sites.dc._msdcs.$forestDnsName"
                    Service = "LDAP"
                    Scope = "SiteForestDcLocator"
                    DomainName = $forestDnsName
                    SiteName = $siteName
                }
                $queryDefinitions += [pscustomobject]@{
                    QueryName = "_gc._tcp.$siteName._sites.$forestDnsName"
                    Service = "GC"
                    Scope = "SiteForestGcLocator"
                    DomainName = $forestDnsName
                    SiteName = $siteName
                }
            }
        }

        foreach ($domainRow in @($collection.Domains)) {
            $domainDnsName = [string]$domainRow.DomainName
            if (-not $domainDnsName) {
                continue
            }
            $queryDefinitions += [pscustomobject]@{
                QueryName = "_ldap._tcp.$domainDnsName"
                Service = "LDAP"
                Scope = "Domain"
                DomainName = $domainDnsName
                SiteName = ""
            }
            $queryDefinitions += [pscustomobject]@{
                QueryName = "_kerberos._tcp.$domainDnsName"
                Service = "Kerberos"
                Scope = "Domain"
                DomainName = $domainDnsName
                SiteName = ""
            }
            foreach ($siteName in $siteNames) {
                $queryDefinitions += [pscustomobject]@{
                    QueryName = "_ldap._tcp.$siteName._sites.$domainDnsName"
                    Service = "LDAP"
                    Scope = "SiteDomain"
                    DomainName = $domainDnsName
                    SiteName = $siteName
                }
                $queryDefinitions += [pscustomobject]@{
                    QueryName = "_kerberos._tcp.$siteName._sites.$domainDnsName"
                    Service = "Kerberos"
                    Scope = "SiteDomain"
                    DomainName = $domainDnsName
                    SiteName = $siteName
                }
            }
        }

        $dedupedQueries = @()
        $queryKeys = @{}
        foreach ($query in @($queryDefinitions)) {
            $key = Get-NormalizedName -Value $query.QueryName
            if ($key -and -not $queryKeys.ContainsKey($key)) {
                $queryKeys[$key] = $true
                $dedupedQueries += $query
            }
        }

        $collection.SrvRecords = @(Resolve-SrvRecordSummary -QueryDefinitions $dedupedQueries)
    }
}
catch {
    $collectionErrors += [pscustomobject]@{
        Step = "Fatal"
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

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$scopeName = $collection.Metadata.ResolvedForestName
if (-not $scopeName) {
    $scopeName = @($collection.Metadata.ResolvedDomainNames | Where-Object { $_ } | Select-Object -First 1)
}
if (-not $scopeName) {
    $scopeName = $ForestName
}
if (-not $scopeName) {
    $scopeName = "ad-dc-health"
}
$safeScope = ConvertTo-SafeFileName -Value $scopeName
$outputFile = Join-Path $outputDirectory.FullName "$safeScope.$timestamp.dc-health.collection.json"
if ($NoClobber -and (Test-Path -LiteralPath $outputFile)) {
    throw "Collection file already exists: $outputFile"
}

$collectionJson = ([pscustomobject]$collection) | ConvertTo-Json -Depth 50
Set-Content -LiteralPath $outputFile -Value $collectionJson -Encoding UTF8

[pscustomobject]@{
    CollectionFile = $outputFile
    ForestName = $collection.Metadata.ResolvedForestName
    DomainNames = @($collection.Metadata.ResolvedDomainNames | Select-Object -Unique)
    Status = $collection.Metadata.CollectionStatus
    DomainControllerCount = @($collection.DomainControllers).Count
    FsmoRoleCount = @($collection.FSMORoles).Count
    ServiceCheckCount = @($collection.Services).Count
    ShareCheckCount = @($collection.Shares).Count
    PortCheckCount = @($collection.PortChecks).Count
    SrvRecordCount = @($collection.SrvRecords).Count
    WarningCount = @($collection.CollectionWarnings).Count
    ErrorCount = @($collection.CollectionErrors).Count
}
