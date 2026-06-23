#requires -Version 5.1
<#
.SYNOPSIS
Collects DNS mapping source data from one Windows DNS server.

.DESCRIPTION
Read-only collector. It writes one self-contained *.collection.json file per
queried DNS server.

Expected filename pattern:
<dns-server>.<yyyyMMddTHHmmssZ>.collection.json
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\input\discovery-collections",

    [Parameter()]
    [string]$DnsServer = $env:COMPUTERNAME,

    [Parameter()]
    [string[]]$RecordTypes = @("SOA", "NS", "A", "AAAA", "CNAME", "MX", "SRV", "PTR"),

    [Parameter()]
    [switch]$IncludeRecordSamples,

    [Parameter()]
    [int]$RecordSampleSize = 10,

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
        return "dns-server"
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

function ConvertTo-PropertyMap {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$PropertyNames
    )

    $map = [ordered]@{}
    foreach ($propertyName in $PropertyNames) {
        $map[$propertyName] = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $InputObject -Names @($propertyName))
    }
    return [pscustomobject]$map
}

function ConvertTo-DnsRecordObject {
    param([Parameter(Mandatory = $true)][object]$Record)

    $recordData = Get-ObjectPropertyValue -InputObject $Record -Names @("RecordData")
    $data = [ordered]@{}
    if ($recordData) {
        foreach ($property in $recordData.PSObject.Properties) {
            $data[$property.Name] = ConvertTo-PlainValue -Value $property.Value
        }
    }

    [pscustomobject]@{
        HostName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Record -Names @("HostName"))
        RecordType = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Record -Names @("RecordType", "Type"))
        Timestamp = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Record -Names @("Timestamp"))
        TimeToLive = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Record -Names @("TimeToLive", "TTL"))
        RecordData = [pscustomobject]$data
    }
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

function Get-DnsResourceRecordsSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$RecordType
    )

    $records = Invoke-CollectionStep -Name "Get-DnsServerResourceRecord $ZoneName $RecordType" -ScriptBlock {
        @(Get-DnsServerResourceRecord -ComputerName $ServerName -ZoneName $ZoneName -RRType $RecordType -ErrorAction Stop -WarningAction SilentlyContinue)
    }

    if ($null -eq $records) {
        return @()
    }

    return @($records)
}

function Resolve-LocalDnsName {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString })
    }
    catch {
        return @()
    }
}

$collectionStartedUtc = [DateTime]::UtcNow
$timestamp = $collectionStartedUtc.ToString("yyyyMMddTHHmmssZ")
$collectionWarnings = @()
$collectionErrors = @()
$moduleVersion = $null

$collection = [ordered]@{
    Metadata = [ordered]@{
        CollectionType = "DnsServer"
        CollectorComputer = Get-CollectorComputerName
        CollectorUser = Get-CollectorUserName
        QueriedServer = $DnsServer
        TimestampUtc = $collectionStartedUtc.ToString("o")
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        DnsServerModuleVersion = $null
        CollectionStatus = "Started"
        CollectionStartedUtc = $collectionStartedUtc.ToString("o")
        CollectionCompletedUtc = $null
    }
    DnsServerIdentity = $null
    ServerSettings = $null
    Forwarders = @()
    ConditionalForwarders = @()
    RootHints = @()
    Zones = @()
    RecordSummary = @()
    CollectionWarnings = @()
    CollectionErrors = @()
}

try {
    $dnsModule = Import-Module DnsServer -PassThru -ErrorAction Stop
    if ($dnsModule) {
        $moduleVersion = @($dnsModule)[0].Version.ToString()
        $collection.Metadata.DnsServerModuleVersion = $moduleVersion
    }

    $serverObject = Invoke-CollectionStep -Name "Get-DnsServer" -ScriptBlock {
        Get-DnsServer -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue
    }

    $serverSettings = Invoke-CollectionStep -Name "Get-DnsServerSetting" -ScriptBlock {
        try {
            Get-DnsServerSetting -ComputerName $DnsServer -All -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch {
            Get-DnsServerSetting -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue
        }
    }

    $resolvedAddresses = Resolve-LocalDnsName -Name $DnsServer
    $collection.DnsServerIdentity = [pscustomobject]@{
        QueriedServer = $DnsServer
        ServerName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $serverObject -Names @("ServerName", "Name", "ComputerName"))
        Fqdn = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $serverObject -Names @("Fqdn", "FullyQualifiedDomainName"))
        IPAddresses = $resolvedAddresses
        Version = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $serverObject -Names @("Version"))
        ForestName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $serverObject -Names @("ForestName"))
        DomainName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $serverObject -Names @("DomainName"))
    }

    $collection.ServerSettings = ConvertTo-PropertyMap -InputObject $serverSettings -PropertyNames @(
        "ComputerName",
        "ListeningIPAddress",
        "AllIPAddress",
        "RecursionEnabled",
        "EnableDirectoryPartitions",
        "EnableDnsSec",
        "EnableEDnsProbes",
        "EnableIPv6",
        "NoRecursion",
        "RoundRobin",
        "ScavengingInterval",
        "DefaultAgingState",
        "DefaultNoRefreshInterval",
        "DefaultRefreshInterval"
    )

    $forwarderObject = Invoke-CollectionStep -Name "Get-DnsServerForwarder" -ScriptBlock {
        Get-DnsServerForwarder -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue
    }
    $forwarderAddresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forwarderObject -Names @("IPAddress", "IPAddresses"))
    $forwarderOrder = 0
    foreach ($address in $forwarderAddresses) {
        $forwarderOrder++
        $collection.Forwarders += [pscustomobject]@{
            DnsServer = $DnsServer
            IPAddress = $address
            Order = $forwarderOrder
            UseRootHint = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forwarderObject -Names @("UseRootHint"))
            Timeout = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forwarderObject -Names @("Timeout"))
            EnableReordering = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forwarderObject -Names @("EnableReordering"))
        }
    }

    $rootHintObjects = Invoke-CollectionStep -Name "Get-DnsServerRootHint" -ScriptBlock {
        @(Get-DnsServerRootHint -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue)
    }
    foreach ($rootHint in @($rootHintObjects)) {
        $recordData = Get-ObjectPropertyValue -InputObject $rootHint -Names @("RecordData")
        $nameServer = Get-ObjectPropertyValue -InputObject $rootHint -Names @("NameServer", "HostName", "Name")
        if (-not $nameServer -and $recordData) {
            $nameServer = Get-ObjectPropertyValue -InputObject $recordData -Names @("NameServer", "NameServerName", "DomainName")
        }
        $ipAddresses = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $rootHint -Names @("IPAddress", "IPAddresses")))
        if ($ipAddresses.Count -eq 0 -and $recordData) {
            $ipAddresses = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $recordData -Names @("IPAddress", "IPv4Address", "IPv6Address")))
        }

        $collection.RootHints += [pscustomobject]@{
            DnsServer = $DnsServer
            NameServer = ConvertTo-PlainValue -Value $nameServer
            IPAddresses = $ipAddresses
        }
    }

    $zoneObjects = Invoke-CollectionStep -Name "Get-DnsServerZone" -ScriptBlock {
        @(Get-DnsServerZone -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue)
    }

    $conditionalForwarderZones = @()
    if (Get-Command Get-DnsServerConditionalForwarderZone -ErrorAction SilentlyContinue) {
        $conditionalForwarderZones = Invoke-CollectionStep -Name "Get-DnsServerConditionalForwarderZone" -ScriptBlock {
            @(Get-DnsServerConditionalForwarderZone -ComputerName $DnsServer -ErrorAction Stop -WarningAction SilentlyContinue)
        }
        if ($null -eq $conditionalForwarderZones) {
            $conditionalForwarderZones = @()
        }
    }

    foreach ($conditionalForwarder in @($conditionalForwarderZones)) {
        $collection.ConditionalForwarders += [pscustomobject]@{
            DnsServer = $DnsServer
            ZoneName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("ZoneName", "Name"))
            MasterServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("MasterServers", "MasterServersIPv4", "IPAddress"))
            ReplicationScope = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("ReplicationScope"))
            DirectoryPartitionName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $conditionalForwarder -Names @("DirectoryPartitionName", "DirectoryPartition"))
        }
    }

    foreach ($zone in @($zoneObjects)) {
        $zoneName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ZoneName", "Name"))
        if (-not $zoneName) {
            continue
        }

        $zoneAging = Invoke-CollectionStep -Name "Get-DnsServerZoneAging $zoneName" -ScriptBlock {
            Get-DnsServerZoneAging -ComputerName $DnsServer -Name $zoneName -ErrorAction Stop -WarningAction SilentlyContinue
        }

        $soaRecords = @(Get-DnsResourceRecordsSafe -ServerName $DnsServer -ZoneName $zoneName -RecordType "SOA" | ForEach-Object {
            ConvertTo-DnsRecordObject -Record $_
        })
        $nsRecords = @(Get-DnsResourceRecordsSafe -ServerName $DnsServer -ZoneName $zoneName -RecordType "NS" | ForEach-Object {
            ConvertTo-DnsRecordObject -Record $_
        })

        $delegations = @()
        if (Get-Command Get-DnsServerZoneDelegation -ErrorAction SilentlyContinue) {
            $delegationObjects = Invoke-CollectionStep -Name "Get-DnsServerZoneDelegation $zoneName" -ScriptBlock {
                @(Get-DnsServerZoneDelegation -ComputerName $DnsServer -ZoneName $zoneName -ErrorAction Stop -WarningAction SilentlyContinue)
            }
            foreach ($delegation in @($delegationObjects)) {
                $delegations += [pscustomobject]@{
                    DnsServer = $DnsServer
                    ParentZoneName = $zoneName
                    ChildZoneName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("ChildZoneName", "Name", "ZoneName"))
                    NameServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("NameServer", "NameServers", "NameServerRecord"))
                    IPAddresses = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $delegation -Names @("IPAddress", "IPAddresses"))
                }
            }
        }

        foreach ($recordType in $RecordTypes) {
            $records = @(Get-DnsResourceRecordsSafe -ServerName $DnsServer -ZoneName $zoneName -RecordType $recordType)
            $samples = @()
            if ($IncludeRecordSamples -and $records.Count -gt 0) {
                $samples = @($records | Select-Object -First $RecordSampleSize | ForEach-Object {
                    ConvertTo-DnsRecordObject -Record $_
                })
            }

            $collection.RecordSummary += [pscustomobject]@{
                DnsServer = $DnsServer
                ZoneName = $zoneName
                RecordType = $recordType
                Count = $records.Count
                SampleCount = $samples.Count
                Samples = $samples
            }
        }

        $collection.Zones += [pscustomobject]@{
            DnsServer = $DnsServer
            ZoneName = $zoneName
            ZoneType = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ZoneType"))
            IsReverseLookupZone = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("IsReverseLookupZone"))
            IsDsIntegrated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("IsDsIntegrated", "IsDsIntegratedZone"))
            ReplicationScope = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ReplicationScope"))
            DirectoryPartitionName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("DirectoryPartitionName", "DirectoryPartition"))
            DynamicUpdate = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("DynamicUpdate"))
            ZoneFile = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("ZoneFile"))
            MasterServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("MasterServers"))
            SecureSecondaries = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("SecureSecondaries"))
            SecondaryServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("SecondaryServers"))
            Notify = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("Notify"))
            NotifyServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zone -Names @("NotifyServers"))
            AgingEnabled = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zoneAging -Names @("AgingEnabled", "Enabled"))
            NoRefreshInterval = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zoneAging -Names @("NoRefreshInterval"))
            RefreshInterval = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $zoneAging -Names @("RefreshInterval"))
            ScavengeServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $zoneAging -Names @("ScavengeServers"))
            SoaRecords = $soaRecords
            NameServerRecords = $nsRecords
            Delegations = $delegations
        }
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
$safeServer = ConvertTo-SafeFileName -Value $DnsServer
$outputFile = Join-Path $outputDirectory.FullName "$safeServer.$timestamp.collection.json"
if ($NoClobber -and (Test-Path -LiteralPath $outputFile)) {
    throw "Collection file already exists: $outputFile"
}

$collectionJson = ([pscustomobject]$collection) | ConvertTo-Json -Depth 40
Set-Content -LiteralPath $outputFile -Value $collectionJson -Encoding UTF8

[pscustomobject]@{
    CollectionFile = $outputFile
    QueriedServer = $DnsServer
    Status = $collection.Metadata.CollectionStatus
    ZoneCount = @($collection.Zones).Count
    ForwarderCount = @($collection.Forwarders).Count
    ConditionalForwarderCount = @($collection.ConditionalForwarders).Count
    WarningCount = @($collection.CollectionWarnings).Count
    ErrorCount = @($collection.CollectionErrors).Count
}
