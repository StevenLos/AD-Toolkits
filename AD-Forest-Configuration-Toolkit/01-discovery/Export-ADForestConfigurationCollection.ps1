#requires -Version 5.1
<#
.SYNOPSIS
Collects read-only Active Directory forest configuration inventory.

.DESCRIPTION
Writes one self-contained *.forest-config.collection.json file with forest,
domain, schema, naming context, partition, optional feature, tombstone/deleted
object lifetime, UPN suffix, and light site/global-catalog context.

This collector does not query trusts and does not modify AD configuration.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\input\discovery-collections",

    [Parameter()]
    [string]$Server,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ForestName,

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
        return "ad-forest-config"
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

function ConvertFrom-DistinguishedNameName {
    param([Parameter()][string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return $null
    }

    if ($DistinguishedName -match '^[A-Za-z]+=([^,]+)') {
        return ($Matches[1] -replace '\\,', ',')
    }

    return $DistinguishedName
}

function Invoke-CollectionStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter()][switch]$Critical
    )

    try {
        return & $ScriptBlock
    }
    catch {
        $item = [pscustomobject]@{
            Step = $Name
            Message = $_.Exception.Message
        }
        if ($Critical) {
            $script:collectionErrors += $item
        }
        else {
            $script:collectionWarnings += $item
        }
        return $null
    }
}

function Get-AdCommandParameters {
    $parameters = @{}
    if ($Server) {
        $parameters["Server"] = $Server
    }
    if ($Credential) {
        $parameters["Credential"] = $Credential
    }
    return $parameters
}

function Get-SchemaProductHint {
    param([Parameter()][object]$ObjectVersion)

    if ($null -eq $ObjectVersion) {
        return $null
    }

    $version = [string]$ObjectVersion
    switch ($version) {
        "13" { return "Windows 2000 Server" }
        "30" { return "Windows Server 2003" }
        "31" { return "Windows Server 2003 R2" }
        "44" { return "Windows Server 2008" }
        "47" { return "Windows Server 2008 R2" }
        "56" { return "Windows Server 2012" }
        "69" { return "Windows Server 2012 R2" }
        "87" { return "Windows Server 2016" }
        "88" { return "Windows Server 2019 or Windows Server 2022" }
        default { return "Unknown schema version" }
    }
}

function ConvertFrom-NtdsSettingsDn {
    param([Parameter()][string]$DistinguishedName)

    if (-not $DistinguishedName) {
        return [pscustomobject]@{
            ServerName = $null
            SiteName = $null
            DistinguishedName = $null
        }
    }

    $server = $null
    $site = $null
    if ($DistinguishedName -match '^CN=NTDS Settings,CN=([^,]+),CN=Servers,CN=([^,]+),CN=Sites,') {
        $server = $Matches[1]
        $site = $Matches[2]
    }

    [pscustomobject]@{
        ServerName = $server
        SiteName = $site
        DistinguishedName = $DistinguishedName
    }
}

function Get-NamingContextType {
    param(
        [Parameter(Mandatory = $true)][string]$NamingContext,
        [Parameter()][string]$ConfigurationNamingContext,
        [Parameter()][string]$SchemaNamingContext,
        [Parameter()][string[]]$DomainNamingContexts = @()
    )

    $normalized = $NamingContext.ToLowerInvariant()
    if ($SchemaNamingContext -and $normalized -eq $SchemaNamingContext.ToLowerInvariant()) {
        return "Schema"
    }
    if ($ConfigurationNamingContext -and $normalized -eq $ConfigurationNamingContext.ToLowerInvariant()) {
        return "Configuration"
    }
    foreach ($domainNc in @($DomainNamingContexts)) {
        if ($domainNc -and $normalized -eq $domainNc.ToLowerInvariant()) {
            return "Domain"
        }
    }
    if ($normalized -like "dc=domaindnszones,*" -or $normalized -like "dc=forestdnszones,*") {
        return "DNSApplication"
    }
    return "Application"
}

function ConvertTo-NamingContextObject {
    param(
        [Parameter(Mandatory = $true)][string]$NamingContext,
        [Parameter()][string]$Source = "Unknown",
        [Parameter()][object]$RootDse,
        [Parameter()][string[]]$DomainNamingContexts = @()
    )

    $defaultNc = [string](Get-ObjectPropertyValue -InputObject $RootDse -Names @("defaultNamingContext"))
    $configNc = [string](Get-ObjectPropertyValue -InputObject $RootDse -Names @("configurationNamingContext"))
    $schemaNc = [string](Get-ObjectPropertyValue -InputObject $RootDse -Names @("schemaNamingContext"))
    $type = Get-NamingContextType -NamingContext $NamingContext -ConfigurationNamingContext $configNc -SchemaNamingContext $schemaNc -DomainNamingContexts $DomainNamingContexts

    [pscustomobject]@{
        NamingContext = $NamingContext
        Type = $type
        Source = $Source
        IsDefault = ($defaultNc -and $NamingContext -ieq $defaultNc)
        IsConfiguration = ($configNc -and $NamingContext -ieq $configNc)
        IsSchema = ($schemaNc -and $NamingContext -ieq $schemaNc)
        IsDomain = ($type -eq "Domain")
        IsApplication = ($type -in @("Application", "DNSApplication"))
        IsDnsApplication = ($type -eq "DNSApplication")
    }
}

function ConvertTo-PartitionObject {
    param(
        [Parameter(Mandatory = $true)][object]$Partition,
        [Parameter()][object]$RootDse,
        [Parameter()][string[]]$DomainNamingContexts = @()
    )

    $nCName = [string](Get-ObjectPropertyValue -InputObject $Partition -Names @("nCName"))
    $configNc = [string](Get-ObjectPropertyValue -InputObject $RootDse -Names @("configurationNamingContext"))
    $schemaNc = [string](Get-ObjectPropertyValue -InputObject $RootDse -Names @("schemaNamingContext"))
    $type = if ($nCName) {
        Get-NamingContextType -NamingContext $nCName -ConfigurationNamingContext $configNc -SchemaNamingContext $schemaNc -DomainNamingContexts $DomainNamingContexts
    }
    else {
        "Unknown"
    }

    $replicaDns = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("msDS-NC-Replica-Locations"))
    $readOnlyReplicaDns = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("msDS-NC-RO-Replica-Locations"))
    $replicas = @()
    foreach ($replicaDn in $replicaDns) {
        $replicas += ConvertFrom-NtdsSettingsDn -DistinguishedName $replicaDn
    }
    $readOnlyReplicas = @()
    foreach ($replicaDn in $readOnlyReplicaDns) {
        $readOnlyReplicas += ConvertFrom-NtdsSettingsDn -DistinguishedName $replicaDn
    }

    [pscustomobject]@{
        Name = ConvertFrom-DistinguishedNameName -DistinguishedName ([string](Get-ObjectPropertyValue -InputObject $Partition -Names @("DistinguishedName")))
        DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("DistinguishedName"))
        NamingContext = $nCName
        PartitionType = $type
        IsDnsApplicationPartition = ($type -eq "DNSApplication")
        DnsRoot = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("dnsRoot"))
        NetBIOSName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("netBIOSName", "nETBIOSName"))
        Enabled = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("Enabled", "enabled"))
        SystemFlags = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("systemFlags"))
        BehaviorVersion = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("msDS-Behavior-Version"))
        ReplicaLocations = @($replicas)
        ReadOnlyReplicaLocations = @($readOnlyReplicas)
        RawReplicaLocationDns = $replicaDns
        RawReadOnlyReplicaLocationDns = $readOnlyReplicaDns
        WhenCreated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("whenCreated"))
        WhenChanged = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Partition -Names @("whenChanged"))
    }
}

function ConvertTo-DomainObject {
    param(
        [Parameter(Mandatory = $true)][object]$Domain,
        [Parameter()][object]$DomainRoot
    )

    [pscustomobject]@{
        Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("Name"))
        DNSRoot = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DNSRoot"))
        NetBIOSName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("NetBIOSName"))
        Forest = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("Forest"))
        DomainMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DomainMode"))
        DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DistinguishedName"))
        DomainSID = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DomainSID"))
        ParentDomain = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("ParentDomain"))
        ChildDomains = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("ChildDomains"))
        PDCEmulator = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("PDCEmulator"))
        RIDMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("RIDMaster"))
        InfrastructureMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("InfrastructureMaster"))
        ReplicaDirectoryServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("ReplicaDirectoryServers"))
        ReadOnlyReplicaDirectoryServers = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("ReadOnlyReplicaDirectoryServers"))
        UsersContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("UsersContainer"))
        ComputersContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("ComputersContainer"))
        DomainControllersContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DomainControllersContainer"))
        DeletedObjectsContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("DeletedObjectsContainer"))
        QuotasContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Domain -Names @("QuotasContainer"))
        DomainSettings = ConvertTo-PropertyMap -InputObject $DomainRoot -PropertyNames @(
            "msDS-Behavior-Version",
            "nTMixedDomain",
            "ms-DS-MachineAccountQuota",
            "pwdProperties",
            "pwdHistoryLength",
            "minPwdLength",
            "minPwdAge",
            "maxPwdAge",
            "lockoutThreshold",
            "lockoutDuration"
        )
    }
}

function ConvertTo-OptionalFeatureObject {
    param([Parameter(Mandatory = $true)][object]$Feature)

    $name = [string](Get-ObjectPropertyValue -InputObject $Feature -Names @("Name"))
    $enabledScopes = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $Feature -Names @("EnabledScopes"))

    [pscustomobject]@{
        Name = $name
        DistinguishedName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Feature -Names @("DistinguishedName"))
        FeatureGUID = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Feature -Names @("FeatureGUID"))
        FeatureScope = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Feature -Names @("FeatureScope"))
        RequiredForestMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $Feature -Names @("RequiredForestMode"))
        EnabledScopes = $enabledScopes
        IsEnabled = ($enabledScopes.Count -gt 0)
        IsRecycleBinFeature = ($name -match 'Recycle Bin')
    }
}

function ConvertTo-DomainControllerContext {
    param(
        [Parameter(Mandatory = $true)][object]$DomainController,
        [Parameter(Mandatory = $true)][string]$DomainName
    )

    [pscustomobject]@{
        DomainName = $DomainName
        HostName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("HostName"))
        Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("Name"))
        Site = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("Site"))
        IsGlobalCatalog = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("IsGlobalCatalog"))
        IPv4Address = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("IPv4Address"))
        OperatingSystem = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("OperatingSystem"))
        OperatingSystemVersion = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("OperatingSystemVersion"))
        OperationMasterRoles = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $DomainController -Names @("OperationMasterRoles"))
    }
}

$collectionStartedUtc = [DateTime]::UtcNow
$timestamp = $collectionStartedUtc.ToString("yyyyMMddTHHmmssZ")
$script:collectionWarnings = @()
$script:collectionErrors = @()

$collection = [ordered]@{
    Metadata = [ordered]@{
        CollectionType = "ADForestConfiguration"
        CollectorComputer = Get-CollectorComputerName
        CollectorUser = Get-CollectorUserName
        QueriedServer = $Server
        RequestedForestName = $ForestName
        TimestampUtc = $collectionStartedUtc.ToString("o")
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ActiveDirectoryModuleVersion = $null
        CollectionStatus = "Started"
        CollectionStartedUtc = $collectionStartedUtc.ToString("o")
        CollectionCompletedUtc = $null
    }
    RootDSE = $null
    Forest = $null
    Domains = @()
    Schema = $null
    DirectoryServiceSettings = $null
    NamingContexts = @()
    Partitions = @()
    OptionalFeatures = @()
    UpnSuffixes = @()
    SpnSuffixes = @()
    SitesGcContext = $null
    CollectionWarnings = @()
    CollectionErrors = @()
}

try {
    $module = Invoke-CollectionStep -Name "Import-Module ActiveDirectory" -Critical -ScriptBlock {
        Import-Module ActiveDirectory -ErrorAction Stop
        Get-Module ActiveDirectory
    }
    if (-not $module) {
        throw "ActiveDirectory PowerShell module is required."
    }
    $collection["Metadata"]["ActiveDirectoryModuleVersion"] = $module.Version.ToString()

    $adParams = Get-AdCommandParameters

    $rootDse = Invoke-CollectionStep -Name "Get-ADRootDSE" -Critical -ScriptBlock {
        Get-ADRootDSE @adParams
    }
    if (-not $rootDse) {
        throw "Unable to read RootDSE."
    }

    $forest = Invoke-CollectionStep -Name "Get-ADForest" -Critical -ScriptBlock {
        if ($ForestName) {
            Get-ADForest -Identity $ForestName @adParams
        }
        else {
            Get-ADForest @adParams
        }
    }
    if (-not $forest) {
        throw "Unable to read AD forest."
    }

    $collection["RootDSE"] = ConvertTo-PropertyMap -InputObject $rootDse -PropertyNames @(
        "defaultNamingContext",
        "configurationNamingContext",
        "schemaNamingContext",
        "rootDomainNamingContext",
        "namingContexts",
        "dnsHostName",
        "domainControllerFunctionality",
        "domainFunctionality",
        "forestFunctionality",
        "isGlobalCatalogReady",
        "supportedLDAPVersion",
        "supportedCapabilities",
        "supportedControl",
        "dsServiceName"
    )

    $collection["Forest"] = [pscustomobject]@{
        Name = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Name"))
        RootDomain = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("RootDomain"))
        ForestMode = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("ForestMode"))
        SchemaMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("SchemaMaster"))
        DomainNamingMaster = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("DomainNamingMaster"))
        Domains = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Domains"))
        GlobalCatalogs = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("GlobalCatalogs"))
        Sites = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("Sites"))
        ApplicationPartitions = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("ApplicationPartitions"))
        PartitionsContainer = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("PartitionsContainer"))
        UPNSuffixes = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("UPNSuffixes"))
        SPNSuffixes = ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $forest -Names @("SPNSuffixes"))
    }
    $collection["UpnSuffixes"] = @($collection["Forest"].UPNSuffixes)
    $collection["SpnSuffixes"] = @($collection["Forest"].SPNSuffixes)

    $domainObjects = @()
    $domainNamingContexts = @()
    foreach ($domainName in @($collection["Forest"].Domains)) {
        $domain = Invoke-CollectionStep -Name "Get-ADDomain $domainName" -ScriptBlock {
            Get-ADDomain -Identity $domainName @adParams
        }
        if (-not $domain) {
            continue
        }

        $domainDn = [string](Get-ObjectPropertyValue -InputObject $domain -Names @("DistinguishedName"))
        if ($domainDn) {
            $domainNamingContexts += $domainDn
        }

        $domainRoot = $null
        if ($domainDn) {
            $domainRoot = Invoke-CollectionStep -Name "Read domain root settings $domainName" -ScriptBlock {
                Get-ADObject -Identity $domainDn -Properties @(
                    "msDS-Behavior-Version",
                    "nTMixedDomain",
                    "ms-DS-MachineAccountQuota",
                    "pwdProperties",
                    "pwdHistoryLength",
                    "minPwdLength",
                    "minPwdAge",
                    "maxPwdAge",
                    "lockoutThreshold",
                    "lockoutDuration"
                ) @adParams
            }
        }
        $domainObjects += ConvertTo-DomainObject -Domain $domain -DomainRoot $domainRoot
    }
    $collection["Domains"] = @($domainObjects)

    $schemaNc = [string](Get-ObjectPropertyValue -InputObject $rootDse -Names @("schemaNamingContext"))
    $schemaObject = $null
    if ($schemaNc) {
        $schemaObject = Invoke-CollectionStep -Name "Read schema objectVersion" -ScriptBlock {
            Get-ADObject -Identity $schemaNc -Properties @("objectVersion", "whenCreated", "whenChanged") @adParams
        }
    }
    $schemaVersion = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $schemaObject -Names @("objectVersion"))
    $collection["Schema"] = [pscustomobject]@{
        NamingContext = $schemaNc
        ObjectVersion = $schemaVersion
        ProductHint = Get-SchemaProductHint -ObjectVersion $schemaVersion
        SchemaMaster = $collection["Forest"].SchemaMaster
        WhenCreated = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $schemaObject -Names @("whenCreated"))
        WhenChanged = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $schemaObject -Names @("whenChanged"))
    }

    $configNc = [string](Get-ObjectPropertyValue -InputObject $rootDse -Names @("configurationNamingContext"))
    $directoryServiceSettings = $null
    if ($configNc) {
        $directoryServiceSettings = Invoke-CollectionStep -Name "Read Directory Service settings" -ScriptBlock {
            Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$configNc" -Properties @(
                "tombstoneLifetime",
                "msDS-DeletedObjectLifetime",
                "garbageCollPeriod",
                "dSHeuristics",
                "whenCreated",
                "whenChanged"
            ) @adParams
        }
    }
    $collection["DirectoryServiceSettings"] = ConvertTo-PropertyMap -InputObject $directoryServiceSettings -PropertyNames @(
        "DistinguishedName",
        "tombstoneLifetime",
        "msDS-DeletedObjectLifetime",
        "garbageCollPeriod",
        "dSHeuristics",
        "whenCreated",
        "whenChanged"
    )

    $namingContexts = @()
    foreach ($namingContext in ConvertTo-StringArray -Value (Get-ObjectPropertyValue -InputObject $rootDse -Names @("namingContexts"))) {
        $namingContexts += ConvertTo-NamingContextObject -NamingContext $namingContext -Source "RootDSE" -RootDse $rootDse -DomainNamingContexts $domainNamingContexts
    }
    $collection["NamingContexts"] = @($namingContexts)

    $partitions = @()
    $partitionsContainer = [string]$collection["Forest"].PartitionsContainer
    if ($partitionsContainer) {
        $crossRefs = Invoke-CollectionStep -Name "Read partition crossRefs" -ScriptBlock {
            @(Get-ADObject -SearchBase $partitionsContainer -SearchScope OneLevel -LDAPFilter "(objectClass=crossRef)" -Properties @(
                "nCName",
                "dnsRoot",
                "netBIOSName",
                "nETBIOSName",
                "systemFlags",
                "enabled",
                "msDS-Behavior-Version",
                "msDS-NC-Replica-Locations",
                "msDS-NC-RO-Replica-Locations",
                "whenCreated",
                "whenChanged"
            ) @adParams)
        }
        foreach ($crossRef in @($crossRefs)) {
            if ($null -ne $crossRef) {
                $partitions += ConvertTo-PartitionObject -Partition $crossRef -RootDse $rootDse -DomainNamingContexts $domainNamingContexts
            }
        }
    }
    $collection["Partitions"] = @($partitions)

    $features = Invoke-CollectionStep -Name "Read optional AD features" -ScriptBlock {
        @(Get-ADOptionalFeature -Filter * -Properties @("EnabledScopes", "FeatureScope", "RequiredForestMode", "FeatureGUID") @adParams)
    }
    $featureObjects = @()
    foreach ($feature in @($features)) {
        if ($null -ne $feature) {
            $featureObjects += ConvertTo-OptionalFeatureObject -Feature $feature
        }
    }
    $collection["OptionalFeatures"] = @($featureObjects)

    $siteNames = @()
    $sites = Invoke-CollectionStep -Name "Read AD replication site names" -ScriptBlock {
        @(Get-ADReplicationSite -Filter * @adParams)
    }
    foreach ($site in @($sites)) {
        $siteName = ConvertTo-PlainValue -Value (Get-ObjectPropertyValue -InputObject $site -Names @("Name"))
        if ($siteName) {
            $siteNames += $siteName
        }
    }

    $domainControllerContext = @()
    foreach ($domainName in @($collection["Forest"].Domains)) {
        $dcParams = @{
            Filter = "*"
            Server = $domainName
        }
        if ($Credential) {
            $dcParams["Credential"] = $Credential
        }

        $domainControllers = Invoke-CollectionStep -Name "Read domain controller summary $domainName" -ScriptBlock {
            @(Get-ADDomainController @dcParams)
        }
        foreach ($domainController in @($domainControllers)) {
            if ($null -ne $domainController) {
                $domainControllerContext += ConvertTo-DomainControllerContext -DomainController $domainController -DomainName $domainName
            }
        }
    }

    $collection["SitesGcContext"] = [pscustomobject]@{
        SiteCount = (@($siteNames | Select-Object -Unique)).Count
        Sites = @($siteNames | Sort-Object -Unique)
        GlobalCatalogs = @($domainControllerContext | Where-Object { $_.IsGlobalCatalog -eq $true -or [string]$_.IsGlobalCatalog -eq "True" } | Select-Object -ExpandProperty HostName -Unique)
        DomainControllers = @($domainControllerContext)
    }

    if ($script:collectionWarnings.Count -gt 0) {
        $collection["Metadata"]["CollectionStatus"] = "CompletedWithWarnings"
    }
    else {
        $collection["Metadata"]["CollectionStatus"] = "Completed"
    }
}
catch {
    $script:collectionErrors += [pscustomobject]@{
        Step = "Collection"
        Message = $_.Exception.Message
    }
    $collection["Metadata"]["CollectionStatus"] = "Failed"
}
finally {
    $collectionCompletedUtc = [DateTime]::UtcNow
    $collection["Metadata"]["CollectionCompletedUtc"] = $collectionCompletedUtc.ToString("o")
    $collection["CollectionWarnings"] = @($script:collectionWarnings)
    $collection["CollectionErrors"] = @($script:collectionErrors)

    $forestForFile = $null
    if ($collection["Forest"] -and $collection["Forest"].Name) {
        $forestForFile = [string]$collection["Forest"].Name
    }
    elseif ($ForestName) {
        $forestForFile = $ForestName
    }
    elseif ($Server) {
        $forestForFile = $Server
    }
    else {
        $forestForFile = "ad-forest-config"
    }

    $outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
    $fileName = "$(ConvertTo-SafeFileName -Value $forestForFile).$timestamp.forest-config.collection.json"
    $outputFile = Join-Path $outputDirectory.FullName $fileName

    if ($NoClobber -and (Test-Path -LiteralPath $outputFile)) {
        throw "Output file already exists: $outputFile"
    }

    $collection | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $outputFile -Encoding UTF8

    $result = [pscustomobject]@{
        CollectionFile = $outputFile
        Status = $collection["Metadata"]["CollectionStatus"]
        WarningCount = @($script:collectionWarnings).Count
        ErrorCount = @($script:collectionErrors).Count
    }

    if ($PassThru) {
        $collection
    }
    else {
        $result
    }
}
