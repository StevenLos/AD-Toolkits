#requires -Version 5.1
<#
.SYNOPSIS
Collects read-only AD Sites and Services inventory.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\05-projects\ad-sites-collection\raw",

    [Parameter()]
    [string]$Server,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ForestName,

    [Parameter()]
    [switch]$IncludeReplicationConnections,

    [Parameter()]
    [switch]$IncludeReplicationMetadata,

    [Parameter()]
    [switch]$CollectIpTransport,

    [Parameter()]
    [Alias("ResolveDnsAddresses")]
    [switch]$ResolveDns,

    [Parameter()]
    [switch]$IncludeSrvRecordSummary,

    [Parameter()]
    [switch]$Anonymize,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$NoClobber,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    if (-not $safe) {
        return "ad-sites"
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

function ConvertFrom-DistinguishedNameName {
    param([Parameter()][string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return $null
    }

    if ($DistinguishedName -match '^CN=([^,]+)') {
        return ($Matches[1] -replace '\\,', ',')
    }

    return $DistinguishedName
}

function ConvertTo-DelimitedText {
    param([Parameter()][object]$Value)

    $items = @(ConvertTo-StringArray -Value $Value)
    if ($items.Count -eq 0) {
        return $null
    }
    return ($items -join "; ")
}

function ConvertFrom-ServerNameInDistinguishedName {
    param([Parameter()][string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return $null
    }

    if ($DistinguishedName -match 'CN=NTDS Settings,CN=([^,]+),CN=Servers,') {
        return ($Matches[1] -replace '\\,', ',')
    }
    if ($DistinguishedName -match 'CN=([^,]+),CN=Servers,') {
        return ($Matches[1] -replace '\\,', ',')
    }
    if ($DistinguishedName -match '^CN=([^,]+)') {
        return ($Matches[1] -replace '\\,', ',')
    }

    return $DistinguishedName
}

function ConvertFrom-SiteNameInDistinguishedName {
    param([Parameter()][string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return $null
    }

    if ($DistinguishedName -match 'CN=Servers,CN=([^,]+),CN=Sites,') {
        return ($Matches[1] -replace '\\,', ',')
    }

    return $null
}

function ConvertTo-NormalizedDcKey {
    param([Parameter()][string]$Value)

    if (-not $Value) {
        return $null
    }

    $text = $Value.Trim()
    if ($text -match '^CN=') {
        $text = ConvertFrom-ServerNameInDistinguishedName -DistinguishedName $text
    }
    if ($text -match '^[0-9a-fA-F-]{36}$') {
        return $text.ToLowerInvariant()
    }
    if ($text -match '^([^./\\]+)') {
        $short = $Matches[1]
        if ($short) {
            return $short.ToLowerInvariant()
        }
    }
    return $text.ToLowerInvariant()
}

function ConvertTo-StableReplicationKey {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    $joined = (($Parts | ForEach-Object {
                if ($null -eq $_) { "" } else { ([string]$_).Trim().ToUpperInvariant() }
            }) -join "|")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $hashBytes = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12).ToUpperInvariant()
}

function Get-ReplicationStatus {
    param(
        [Parameter()][object]$ResultCode,
        [Parameter()][object]$FailureCount
    )

    $codeText = ConvertTo-PlainValue -Value $ResultCode
    $failureText = ConvertTo-PlainValue -Value $FailureCount
    $failureNumber = 0
    if ($failureText -and [int]::TryParse([string]$failureText, [ref]$failureNumber) -and $failureNumber -gt 0) {
        return "Failing"
    }
    if ($codeText -and [string]$codeText -ne "0" -and [string]$codeText -ne "Success") {
        return "Failing"
    }
    return "Healthy"
}

function Write-CsvRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Force
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "Output file already exists. Pass -Force to overwrite: $Path"
    }

    if ($Rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value ($Columns -join ",") -Encoding UTF8
        return
    }

    $Rows |
        Select-Object -Property $Columns |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
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
            Step = "Resolve DNS addresses for $HostName"
            Message = $_.Exception.Message
        }
    }

    [pscustomobject]@{
        IPv4Addresses = $ipv4
        IPv6Addresses = $ipv6
    }
}

function Resolve-SrvRecordSummary {
    param(
        [Parameter(Mandatory = $true)][string[]]$NamesToQuery
    )

    $rows = @()
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        $script:collectionWarnings += [pscustomobject]@{
            Step = "Resolve-DnsName"
            Message = "Resolve-DnsName is not available; SRV record summary was skipped."
        }
        return $rows
    }

    foreach ($queryName in $NamesToQuery) {
        $records = Invoke-CollectionStep -Name "Resolve-DnsName $queryName SRV" -ScriptBlock {
            @(Resolve-DnsName -Name $queryName -Type SRV)
        }
        foreach ($record in @($records)) {
            $rows += [pscustomobject]@{
                QueryName = $queryName
                Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Name"))
                Type = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Type"))
                NameTarget = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("NameTarget"))
                Port = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Port"))
                Priority = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Priority"))
                Weight = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $record -Names @("Weight"))
            }
        }
    }

    return $rows
}

$collectionStartedUtc = [DateTime]::UtcNow
$timestamp = $collectionStartedUtc.ToString("yyyyMMddTHHmmssZ")
$collectionWarnings = @()
$collectionErrors = @()
$moduleVersion = $null

if ($Anonymize) {
    throw "The -Anonymize workflow is not implemented yet. Run without -Anonymize or anonymize the generated collection before sharing it."
}

if ($CollectIpTransport) {
    $collectionWarnings += [pscustomobject]@{
        Step = "CollectIpTransport"
        Message = "Detailed IP transport bridge-all-site-links collection is not implemented yet; site link transport fields are still collected when exposed by AD cmdlets."
    }
}

$adParams = @{}
if ($Server) {
    $adParams["Server"] = $Server
}
if ($Credential) {
    $adParams["Credential"] = $Credential
}

$collection = [ordered]@{
    Metadata = [ordered]@{
        CollectionType = "ADSitesAndServices"
        CollectorComputer = Get-CollectorComputerName
        CollectorUser = Get-CollectorUserName
        Server = $Server
        RequestedForestName = $ForestName
        CredentialUsed = [bool]$Credential
        TimestampUtc = $collectionStartedUtc.ToString("o")
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ActiveDirectoryModuleVersion = $null
        CollectionStatus = "Started"
        CollectionStartedUtc = $collectionStartedUtc.ToString("o")
        CollectionCompletedUtc = $null
        ForestName = $null
        DomainName = $null
    }
    Forest = $null
    Domain = $null
    ADSites = @()
    ADSubnets = @()
    ADSiteLinks = @()
    DomainControllers = @()
    ReplicationConnections = @()
    ReplicationPartnerMetadata = @()
    ReplicationFailures = @()
    ReplicationQueue = @()
    ReplicationTopologyEdges = @()
    ReplicationHealthSummary = @()
    SrvRecordSummary = @()
    CollectionWarnings = @()
    CollectionErrors = @()
}

try {
    $adModule = Import-Module ActiveDirectory -PassThru -ErrorAction Stop
    if ($adModule) {
        $moduleVersion = @($adModule)[0].Version.ToString()
        $collection.Metadata.ActiveDirectoryModuleVersion = $moduleVersion
    }

    $forest = Invoke-CollectionStep -Name "Get-ADForest" -ScriptBlock {
        Get-ADForest @adParams
    }
    $domain = Invoke-CollectionStep -Name "Get-ADDomain" -ScriptBlock {
        Get-ADDomain @adParams
    }

    if ($forest) {
        $collection.Metadata.ForestName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Name"))
        $collection.Forest = [pscustomobject]@{
            Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Name"))
            RootDomain = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("RootDomain"))
            Domains = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Domains"))
            Sites = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Sites"))
            GlobalCatalogs = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("GlobalCatalogs"))
        }
    }

    if ($domain) {
        $collection.Metadata.DomainName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DNSRoot", "Name"))
        $collection.Domain = [pscustomobject]@{
            DNSRoot = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DNSRoot"))
            NetBIOSName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("NetBIOSName"))
            DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DistinguishedName"))
            DomainMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DomainMode"))
        }
    }

    $siteObjects = Invoke-CollectionStep -Name "Get-ADReplicationSite" -ScriptBlock {
        @(Get-ADReplicationSite -Filter * -Properties * @adParams)
    }
    foreach ($site in @($siteObjects)) {
        $collection.ADSites += [pscustomobject]@{
            SiteName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Name"))
            DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("DistinguishedName"))
            Description = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Description"))
            Location = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Location"))
            Options = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Options"))
            WhenCreated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("WhenCreated"))
            WhenChanged = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("WhenChanged"))
        }
    }

    $subnetObjects = Invoke-CollectionStep -Name "Get-ADReplicationSubnet" -ScriptBlock {
        @(Get-ADReplicationSubnet -Filter * -Properties * @adParams)
    }
    foreach ($subnet in @($subnetObjects)) {
        $siteDn = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Site"))
        $collection.ADSubnets += [pscustomobject]@{
            SubnetName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Name"))
            SiteName = ConvertFrom-DistinguishedNameName -DistinguishedName $siteDn
            SiteDistinguishedName = $siteDn
            DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("DistinguishedName"))
            Description = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Description"))
            Location = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $subnet -Names @("Location"))
        }
    }

    $siteLinkObjects = Invoke-CollectionStep -Name "Get-ADReplicationSiteLink" -ScriptBlock {
        @(Get-ADReplicationSiteLink -Filter * -Properties * @adParams)
    }
    foreach ($siteLink in @($siteLinkObjects)) {
        $sitesIncluded = @()
        foreach ($siteDn in (ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("SitesIncluded")))) {
            $sitesIncluded += ConvertFrom-DistinguishedNameName -DistinguishedName $siteDn
        }

        $collection.ADSiteLinks += [pscustomobject]@{
            SiteLinkName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("Name"))
            DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("DistinguishedName"))
            SitesIncluded = $sitesIncluded
            Cost = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("Cost"))
            ReplicationFrequencyInMinutes = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("ReplicationFrequencyInMinutes"))
            Options = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("Options"))
            InterSiteTransportProtocol = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $siteLink -Names @("InterSiteTransportProtocol"))
        }
    }

    $domainNames = @()
    if ($forest) {
        $domainNames = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Domains")))
    }
    if ($domainNames.Count -eq 0 -and $domain) {
        $domainNames = @(ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $domain -Names @("DNSRoot", "Name")))
    }

    foreach ($domainName in $domainNames) {
        if (-not $domainName) {
            continue
        }

        $dcParams = @{}
        if ($Credential) {
            $dcParams["Credential"] = $Credential
        }
        if ($Server) {
            $dcParams["Server"] = $Server
        }
        else {
            $dcParams["Server"] = $domainName
        }

        $dcObjects = Invoke-CollectionStep -Name "Get-ADDomainController $domainName" -ScriptBlock {
            @(Get-ADDomainController -Filter * @dcParams)
        }

        foreach ($dc in @($dcObjects)) {
            $hostName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("HostName", "DNSHostName", "Name"))
            $ipv4 = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IPv4Address"))
            $ipv6 = @()
            if ($ResolveDns -and $hostName) {
                $resolved = Resolve-HostAddresses -HostName $hostName
                if ($resolved.IPv4Addresses.Count -gt 0) {
                    $ipv4 = $resolved.IPv4Addresses
                }
                $ipv6 = $resolved.IPv6Addresses
            }

            $collection.DomainControllers += [pscustomobject]@{
                Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Name"))
                HostName = $hostName
                Domain = $domainName
                Forest = $collection.Metadata.ForestName
                SiteName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Site"))
                IPv4Addresses = $ipv4
                IPv6Addresses = $ipv6
                IsGlobalCatalog = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IsGlobalCatalog"))
                IsReadOnly = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("IsReadOnly"))
                Enabled = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("Enabled"))
                OperatingSystem = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("OperatingSystem"))
                OperationMasterRoles = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("OperationMasterRoles"))
                LdapPort = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("LdapPort"))
                SslPort = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("SslPort"))
                ComputerObjectDN = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $dc -Names @("ComputerObjectDN"))
            }
        }
    }

    $dcLookup = @{}
    foreach ($dc in @($collection.DomainControllers)) {
        foreach ($keyCandidate in @(
                $dc.Name,
                $dc.HostName,
                ($dc.HostName -replace '\..*$', ''),
                $dc.ComputerObjectDN
            )) {
            $key = ConvertTo-NormalizedDcKey -Value (ConvertTo-PlainValue -Value $keyCandidate)
            if ($key -and -not $dcLookup.ContainsKey($key)) {
                $dcLookup[$key] = $dc
            }
        }
    }

    function Resolve-DomainControllerContext {
        param([Parameter()][string]$Identity)

        $key = ConvertTo-NormalizedDcKey -Value $Identity
        if ($key -and $dcLookup.ContainsKey($key)) {
            $dc = $dcLookup[$key]
            return [pscustomobject]@{
                Name = $dc.Name
                HostName = $dc.HostName
                SiteName = $dc.SiteName
                Domain = $dc.Domain
            }
        }

        $serverName = ConvertFrom-ServerNameInDistinguishedName -DistinguishedName $Identity
        $siteName = ConvertFrom-SiteNameInDistinguishedName -DistinguishedName $Identity
        return [pscustomobject]@{
            Name = $serverName
            HostName = $serverName
            SiteName = $siteName
            Domain = $null
        }
    }

    if ($IncludeReplicationConnections) {
        $connectionObjects = Invoke-CollectionStep -Name "Get-ADReplicationConnection" -ScriptBlock {
            @(Get-ADReplicationConnection -Filter * -Properties * @adParams)
        }

        foreach ($connection in @($connectionObjects)) {
            $connectionDn = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("DistinguishedName"))
            $sourceRaw = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("ReplicateFromDirectoryServer", "FromServer", "SourceServer", "SourceServerDN"))
            $destinationRaw = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("ReplicateToDirectoryServer", "ToServer", "DestinationServer", "DestinationServerDN"))
            if (-not $destinationRaw) {
                $destinationRaw = $connectionDn
            }

            $source = Resolve-DomainControllerContext -Identity $sourceRaw
            $destination = Resolve-DomainControllerContext -Identity $destinationRaw
            $transport = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("TransportType", "Transport", "InterSiteTransportProtocol"))
            if (-not $transport) {
                $transport = "RPC/IP"
            }

            $collection.ReplicationConnections += [pscustomobject]@{
                ConnectionId = "RPCONN-" + (ConvertTo-StableReplicationKey -Parts @($connectionDn, $source.HostName, $destination.HostName))
                ConnectionName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("Name"))
                SourceServer = $source.HostName
                SourceSite = $source.SiteName
                DestinationServer = $destination.HostName
                DestinationSite = $destination.SiteName
                Transport = $transport
                Enabled = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("EnabledConnection", "Enabled"))
                AutoGenerated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("AutoGenerated"))
                Options = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("Options"))
                Schedule = if (Get-ObjectPropertyValue -InputObject $connection -Names @("Schedule")) { "Custom - see raw inventory JSON" } else { "" }
                DistinguishedName = $connectionDn
                WhenCreated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("WhenCreated"))
                WhenChanged = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $connection -Names @("WhenChanged"))
                Notes = "Configured replication connection object. This is configuration, not observed replication health."
            }
        }
    }

    if ($IncludeReplicationMetadata) {
        $replicationParams = @{}
        if ($Credential) {
            $replicationParams["Credential"] = $Credential
        }
        if ($Server) {
            $replicationParams["EnumerationServer"] = $Server
        }

        foreach ($dc in @($collection.DomainControllers)) {
            $target = $dc.HostName
            if (-not $target) {
                $target = $dc.Name
            }
            if (-not $target) {
                continue
            }

            $partnerRows = Invoke-CollectionStep -Name "Get-ADReplicationPartnerMetadata $target" -ScriptBlock {
                @(Get-ADReplicationPartnerMetadata -Target $target -Scope Server -PartnerType Both @replicationParams)
            }
            foreach ($partner in @($partnerRows)) {
                $destination = Resolve-DomainControllerContext -Identity (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("Server", "DestinationServer", "Destination")))
                if (-not $destination.HostName) {
                    $destination = Resolve-DomainControllerContext -Identity $target
                }
                $source = Resolve-DomainControllerContext -Identity (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("Partner", "SourceServer", "Source")))
                $namingContext = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("Partition", "NamingContext", "PartitionName"))
                $resultCode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("LastReplicationResult", "ResultCode"))
                $failureCount = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("ConsecutiveReplicationFailures", "ConsecutiveFailureCount"))

                $collection.ReplicationPartnerMetadata += [pscustomobject]@{
                    MetadataId = "RPMETA-" + (ConvertTo-StableReplicationKey -Parts @($source.HostName, $destination.HostName, $namingContext, "partner"))
                    Direction = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("PartnerType", "Direction"))
                    SourceServer = $source.HostName
                    SourceSite = $source.SiteName
                    DestinationServer = $destination.HostName
                    DestinationSite = $destination.SiteName
                    NamingContext = $namingContext
                    LastSuccess = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("LastReplicationSuccess", "LastSuccess"))
                    LastFailure = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("LastReplicationAttempt", "LastFailure", "LastReplicationFailure"))
                    ConsecutiveFailureCount = $failureCount
                    ResultCode = $resultCode
                    ResultMessage = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("LastReplicationResultMessage", "ResultMessage", "LastErrorMessage"))
                    Transport = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("TransportType", "Transport"))
                    PartnerAddress = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $partner -Names @("PartnerAddress"))
                    Status = Get-ReplicationStatus -ResultCode $resultCode -FailureCount $failureCount
                    Notes = "Observed replication partner metadata. This is evidence from replication state, not a configured connection object."
                }
            }

            $failureRows = Invoke-CollectionStep -Name "Get-ADReplicationFailure $target" -ScriptBlock {
                @(Get-ADReplicationFailure -Target $target -Scope Server @replicationParams)
            }
            foreach ($failure in @($failureRows)) {
                $destination = Resolve-DomainControllerContext -Identity (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("Server", "DestinationServer", "Destination")))
                if (-not $destination.HostName) {
                    $destination = Resolve-DomainControllerContext -Identity $target
                }
                $source = Resolve-DomainControllerContext -Identity (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("Partner", "SourceServer", "Source")))
                $namingContext = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("Partition", "NamingContext", "PartitionName"))
                $resultCode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("LastError", "ResultCode", "FailureType"))
                $failureCount = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("FailureCount", "ConsecutiveReplicationFailures"))

                $collection.ReplicationFailures += [pscustomobject]@{
                    FailureId = "RPFAIL-" + (ConvertTo-StableReplicationKey -Parts @($source.HostName, $destination.HostName, $namingContext, $resultCode))
                    SourceServer = $source.HostName
                    SourceSite = $source.SiteName
                    DestinationServer = $destination.HostName
                    DestinationSite = $destination.SiteName
                    NamingContext = $namingContext
                    FirstFailure = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("FirstFailureTime", "FirstFailure"))
                    LastFailure = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("LastFailureTime", "LastFailure"))
                    ConsecutiveFailureCount = $failureCount
                    ResultCode = $resultCode
                    ResultMessage = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("LastErrorMessage", "ResultMessage", "FailureMessage"))
                    FailureType = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $failure -Names @("FailureType"))
                    Status = "Failing"
                    Notes = "Observed replication failure. This is read-only health evidence, not remediation."
                }
            }

            $queueRows = Invoke-CollectionStep -Name "Get-ADReplicationQueueOperation $target" -ScriptBlock {
                @(Get-ADReplicationQueueOperation -Server $target)
            }
            foreach ($queueRow in @($queueRows)) {
                $destination = Resolve-DomainControllerContext -Identity $target
                $source = Resolve-DomainControllerContext -Identity (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("SourceServer", "Partner", "Source")))
                $collection.ReplicationQueue += [pscustomobject]@{
                    QueueId = "RPQUEUE-" + (ConvertTo-StableReplicationKey -Parts @($source.HostName, $destination.HostName, (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("NamingContext", "Partition"))), (ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("EnqueuedTime", "TimeEnqueued")))))
                    SourceServer = $source.HostName
                    SourceSite = $source.SiteName
                    DestinationServer = $destination.HostName
                    DestinationSite = $destination.SiteName
                    NamingContext = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("NamingContext", "Partition"))
                    Operation = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("Operation", "OperationType"))
                    EnqueuedTime = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("EnqueuedTime", "TimeEnqueued"))
                    Priority = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $queueRow -Names @("Priority"))
                    Status = "Queued"
                    Notes = "Replication queue/backlog indicator where exposed by AD replication cmdlets."
                }
            }
        }
    }

    $topologyEdgeCandidates = @()
    foreach ($row in @($collection.ReplicationConnections)) {
        $topologyEdgeCandidates += [pscustomobject]@{
            EvidenceType = "ConfiguredConnection"
            SourceServer = $row.SourceServer
            SourceSite = $row.SourceSite
            DestinationServer = $row.DestinationServer
            DestinationSite = $row.DestinationSite
            NamingContext = ""
            Transport = $row.Transport
            LastSuccess = ""
            LastFailure = ""
            ConsecutiveFailureCount = ""
            ResultCode = ""
            ResultMessage = ""
            Status = "Configured"
            EvidenceId = $row.ConnectionId
            Notes = "Configured connection object; not observed health."
        }
    }
    foreach ($row in @($collection.ReplicationPartnerMetadata)) {
        $topologyEdgeCandidates += [pscustomobject]@{
            EvidenceType = "ObservedPartnerMetadata"
            SourceServer = $row.SourceServer
            SourceSite = $row.SourceSite
            DestinationServer = $row.DestinationServer
            DestinationSite = $row.DestinationSite
            NamingContext = $row.NamingContext
            Transport = $row.Transport
            LastSuccess = $row.LastSuccess
            LastFailure = $row.LastFailure
            ConsecutiveFailureCount = $row.ConsecutiveFailureCount
            ResultCode = $row.ResultCode
            ResultMessage = $row.ResultMessage
            Status = $row.Status
            EvidenceId = $row.MetadataId
            Notes = "Observed partner metadata; not a configured connection object."
        }
    }
    foreach ($row in @($collection.ReplicationFailures)) {
        $topologyEdgeCandidates += [pscustomobject]@{
            EvidenceType = "ReplicationFailure"
            SourceServer = $row.SourceServer
            SourceSite = $row.SourceSite
            DestinationServer = $row.DestinationServer
            DestinationSite = $row.DestinationSite
            NamingContext = $row.NamingContext
            Transport = ""
            LastSuccess = ""
            LastFailure = $row.LastFailure
            ConsecutiveFailureCount = $row.ConsecutiveFailureCount
            ResultCode = $row.ResultCode
            ResultMessage = $row.ResultMessage
            Status = "Failing"
            EvidenceId = $row.FailureId
            Notes = "Observed replication failure; not remediation."
        }
    }
    foreach ($row in @($collection.ReplicationQueue)) {
        $topologyEdgeCandidates += [pscustomobject]@{
            EvidenceType = "ReplicationQueue"
            SourceServer = $row.SourceServer
            SourceSite = $row.SourceSite
            DestinationServer = $row.DestinationServer
            DestinationSite = $row.DestinationSite
            NamingContext = $row.NamingContext
            Transport = ""
            LastSuccess = ""
            LastFailure = ""
            ConsecutiveFailureCount = ""
            ResultCode = ""
            ResultMessage = ""
            Status = "Queued"
            EvidenceId = $row.QueueId
            Notes = "Observed queue/backlog indicator."
        }
    }

    $edgeIndex = 1
    foreach ($edge in ($topologyEdgeCandidates | Sort-Object EvidenceType, SourceServer, DestinationServer, NamingContext, EvidenceId)) {
        $collection.ReplicationTopologyEdges += [pscustomobject]@{
            ReplicationEdgeId = "RPL" + $edgeIndex.ToString("000")
            EvidenceType = $edge.EvidenceType
            SourceServer = $edge.SourceServer
            SourceSite = $edge.SourceSite
            DestinationServer = $edge.DestinationServer
            DestinationSite = $edge.DestinationSite
            NamingContext = $edge.NamingContext
            Transport = $edge.Transport
            LastSuccess = $edge.LastSuccess
            LastFailure = $edge.LastFailure
            ConsecutiveFailureCount = $edge.ConsecutiveFailureCount
            ResultCode = $edge.ResultCode
            ResultMessage = $edge.ResultMessage
            Status = $edge.Status
            EvidenceId = $edge.EvidenceId
            Notes = $edge.Notes
        }
        $edgeIndex++
    }

    foreach ($dc in @($collection.DomainControllers)) {
        $hostName = $dc.HostName
        $serverRows = @($collection.ReplicationTopologyEdges | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName })
        $failureRowsForDc = @($collection.ReplicationFailures | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName })
        $queueRowsForDc = @($collection.ReplicationQueue | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName })
        $lastSuccessValues = @($collection.ReplicationPartnerMetadata | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName } | ForEach-Object { $_.LastSuccess } | Where-Object { $_ } | Sort-Object -Descending)
        $lastFailureValues = @($collection.ReplicationTopologyEdges | Where-Object { ($_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName) -and $_.LastFailure } | ForEach-Object { $_.LastFailure } | Sort-Object -Descending)
        $status = if ($failureRowsForDc.Count -gt 0) { "Failing" } elseif ($queueRowsForDc.Count -gt 0) { "Queued" } elseif ($serverRows.Count -gt 0) { "Healthy" } else { "NoData" }

        $collection.ReplicationHealthSummary += [pscustomobject]@{
            DomainController = $hostName
            SiteName = $dc.SiteName
            PartnerMetadataCount = @($collection.ReplicationPartnerMetadata | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName }).Count
            ConfiguredConnectionCount = @($collection.ReplicationConnections | Where-Object { $_.SourceServer -eq $hostName -or $_.DestinationServer -eq $hostName }).Count
            FailureCount = $failureRowsForDc.Count
            QueueOperationCount = $queueRowsForDc.Count
            LastSuccess = @($lastSuccessValues | Select-Object -First 1)
            LastFailure = @($lastFailureValues | Select-Object -First 1)
            Status = $status
            Notes = "Read-only summary from configured connection objects and observed replication metadata where available."
        }
    }

    if ($IncludeSrvRecordSummary) {
        $queries = @()
        if ($collection.Metadata.ForestName) {
            $queries += "_ldap._tcp.dc._msdcs.$($collection.Metadata.ForestName)"
            foreach ($site in @($collection.ADSites)) {
                if ($site.SiteName) {
                    $queries += "_ldap._tcp.$($site.SiteName)._sites.dc._msdcs.$($collection.Metadata.ForestName)"
                }
            }
        }
        foreach ($domainName in $domainNames) {
            if ($domainName) {
                $queries += "_kerberos._tcp.$domainName"
                $queries += "_ldap._tcp.$domainName"
            }
        }

        $collection.SrvRecordSummary = @(Resolve-SrvRecordSummary -NamesToQuery ($queries | Select-Object -Unique))
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
$scopeName = $collection.Metadata.ForestName
if (-not $scopeName) {
    $scopeName = $collection.Metadata.DomainName
}
if (-not $scopeName) {
    $scopeName = $ForestName
}
if (-not $scopeName) {
    $scopeName = "ad-sites"
}
$safeScope = ConvertTo-SafeFileName -Value $scopeName
$outputFile = Join-Path $outputDirectory.FullName "$safeScope.$timestamp.sites.collection.json"
if ((-not $Force -or $NoClobber) -and (Test-Path -LiteralPath $outputFile)) {
    throw "Collection file already exists: $outputFile"
}

Write-CsvRows -Rows @($collection.ReplicationConnections) -Columns @(
    "ConnectionId",
    "ConnectionName",
    "SourceServer",
    "SourceSite",
    "DestinationServer",
    "DestinationSite",
    "Transport",
    "Enabled",
    "AutoGenerated",
    "Options",
    "Schedule",
    "DistinguishedName",
    "WhenCreated",
    "WhenChanged",
    "Notes"
) -Path (Join-Path $outputDirectory.FullName "replication-connections.csv") -Force:$Force

Write-CsvRows -Rows @($collection.ReplicationPartnerMetadata) -Columns @(
    "MetadataId",
    "Direction",
    "SourceServer",
    "SourceSite",
    "DestinationServer",
    "DestinationSite",
    "NamingContext",
    "LastSuccess",
    "LastFailure",
    "ConsecutiveFailureCount",
    "ResultCode",
    "ResultMessage",
    "Transport",
    "PartnerAddress",
    "Status",
    "Notes"
) -Path (Join-Path $outputDirectory.FullName "replication-partner-metadata.csv") -Force:$Force

Write-CsvRows -Rows @($collection.ReplicationFailures) -Columns @(
    "FailureId",
    "SourceServer",
    "SourceSite",
    "DestinationServer",
    "DestinationSite",
    "NamingContext",
    "FirstFailure",
    "LastFailure",
    "ConsecutiveFailureCount",
    "ResultCode",
    "ResultMessage",
    "FailureType",
    "Status",
    "Notes"
) -Path (Join-Path $outputDirectory.FullName "replication-failures.csv") -Force:$Force

Write-CsvRows -Rows @($collection.ReplicationTopologyEdges) -Columns @(
    "ReplicationEdgeId",
    "EvidenceType",
    "SourceServer",
    "SourceSite",
    "DestinationServer",
    "DestinationSite",
    "NamingContext",
    "Transport",
    "LastSuccess",
    "LastFailure",
    "ConsecutiveFailureCount",
    "ResultCode",
    "ResultMessage",
    "Status",
    "EvidenceId",
    "Notes"
) -Path (Join-Path $outputDirectory.FullName "replication-topology-edges.csv") -Force:$Force

Write-CsvRows -Rows @($collection.ReplicationHealthSummary) -Columns @(
    "DomainController",
    "SiteName",
    "PartnerMetadataCount",
    "ConfiguredConnectionCount",
    "FailureCount",
    "QueueOperationCount",
    "LastSuccess",
    "LastFailure",
    "Status",
    "Notes"
) -Path (Join-Path $outputDirectory.FullName "replication-health-summary.csv") -Force:$Force

$collectionJson = ([pscustomobject]$collection) | ConvertTo-Json -Depth 40
Set-Content -LiteralPath $outputFile -Value $collectionJson -Encoding UTF8

$summary = [pscustomobject]@{
    CollectionFile = $outputFile
    ForestName = $collection.Metadata.ForestName
    DomainName = $collection.Metadata.DomainName
    Status = $collection.Metadata.CollectionStatus
    SiteCount = @($collection.ADSites).Count
    SubnetCount = @($collection.ADSubnets).Count
    SiteLinkCount = @($collection.ADSiteLinks).Count
    DomainControllerCount = @($collection.DomainControllers).Count
    ReplicationConnectionCount = @($collection.ReplicationConnections).Count
    ReplicationPartnerMetadataCount = @($collection.ReplicationPartnerMetadata).Count
    ReplicationFailureCount = @($collection.ReplicationFailures).Count
    ReplicationTopologyEdgeCount = @($collection.ReplicationTopologyEdges).Count
    WarningCount = @($collection.CollectionWarnings).Count
    ErrorCount = @($collection.CollectionErrors).Count
}

if ($PassThru) {
    [pscustomobject]$collection
}
else {
    $summary
}
