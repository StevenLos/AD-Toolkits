#requires -Version 5.1
<#
.SYNOPSIS
Collects local hybrid identity and federation discovery evidence.

.DESCRIPTION
Creates one self-contained *.collection.json file. The collector is read-only,
does not collect secrets, and redacts credentials, private key material, tokens,
thumbprints, immutable IDs, tenant IDs, and other tenant-sensitive identifiers by
default.

Run it locally on a Microsoft Entra Connect / Azure AD Connect server, AD FS
server, WAP server, or PTA agent server. Use -OfflineExportPath to package
offline exports first. Cloud/API discovery is optional and separate; it only runs
when -IncludeCloud is specified and a supported module/session already exists.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\input\discovery-collections",

    [Parameter()]
    [string]$CollectionName,

    [Parameter()]
    [string]$OfflineExportPath,

    [Parameter()]
    [switch]$NoLiveDiscovery,

    [Parameter()]
    [switch]$IncludeCloud,

    [Parameter()]
    [switch]$NoRedaction,

    [Parameter()]
    [switch]$NoClobber
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:CollectionWarnings = @()
$script:CollectionErrors = @()

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    $safe = $safe.Trim("._-")
    if (-not $safe) {
        return "hybrid-identity"
    }
    return $safe
}

function Add-CollectionWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:CollectionWarnings += [pscustomobject][ordered]@{
        Step = $Step
        Message = $Message
    }
}

function Add-CollectionError {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:CollectionErrors += [pscustomobject][ordered]@{
        Step = $Step
        Message = $Message
    }
}

function Protect-Text {
    param(
        [Parameter()][object]$Value,
        [Parameter()][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ($NoRedaction) {
        return $text
    }

    $nonSecretPasswordConfig = $Name -match '(?i)(PasswordHashSync|PasswordWriteback)'
    if (-not $nonSecretPasswordConfig -and $Name -match '(?i)(password|secret|private|credential|token|client.?secret|keymaterial|pfx|rawdata|securestring|key$)') {
        return "[REDACTED]"
    }

    if ($Name -match '(?i)^(Tenant|TenantId|TenantName|AzureAdTenant|EntraTenant)$') {
        return "[REDACTED:Tenant]"
    }

    $attributeNameField = $Name -match '(?i)(ImmutableIdAttribute|SourceAnchor)$'
    if (-not $attributeNameField -and $Name -match '(?i)(tenant|immutable|thumbprint|client.?id|object.?id|identifier|issuer|realm)') {
        $text = $text -replace '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '[REDACTED:GUID]'
        $text = $text -replace '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '[REDACTED:UPN]'
        if ($Name -match '(?i)(thumbprint|immutable)' -and $text.Length -gt 12 -and $text -notmatch '^\[REDACTED') {
            return "[REDACTED:$Name]"
        }
    }

    $text = $text -replace '(?i)(client_secret=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '(?i)(access_token=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '(?i)(refresh_token=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[REDACTED:JWT]'
    return $text
}

function ConvertTo-SafeValue {
    param(
        [Parameter()][object]$Value,
        [Parameter()][string]$Name = ""
    )

    if ($null -eq $Value) {
        return $null
    }

    $nonSecretPasswordConfig = $Name -match '(?i)(PasswordHashSync|PasswordWriteback)'
    if (-not $nonSecretPasswordConfig -and $Name -match '(?i)(password|secret|private|credential|token|client.?secret|keymaterial|pfx|rawdata|securestring|key$)') {
        return "[REDACTED]"
    }

    if ($Value -is [string]) {
        return Protect-Text -Value $Value -Name $Name
    }

    if ($Value -is [bool] -or $Value.GetType().IsPrimitive -or $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    if ($Value -is [TimeSpan]) {
        return $Value.ToString()
    }

    if ($Value -is [System.Security.SecureString]) {
        return "[REDACTED]"
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $keyText = [string]$key
            $map[$keyText] = ConvertTo-SafeValue -Value $Value[$key] -Name $keyText
        }
        return [pscustomobject]$map
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-SafeValue -Value $item -Name $Name
        }
        return @($items)
    }

    $object = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties)) {
        if (-not $property.Name) {
            continue
        }
        $propertyIsNonSecretPasswordConfig = $property.Name -match '(?i)(PasswordHashSync|PasswordWriteback)'
        if (-not $propertyIsNonSecretPasswordConfig -and $property.Name -match '(?i)(password|secret|private|credential|token|client.?secret|keymaterial|pfx|rawdata|securestring|key$)') {
            $object[$property.Name] = "[REDACTED]"
            continue
        }
        try {
            $object[$property.Name] = ConvertTo-SafeValue -Value $property.Value -Name $property.Name
        }
        catch {
            $object[$property.Name] = "[UNREADABLE]"
        }
    }

    if ($object.Count -eq 0) {
        return Protect-Text -Value ([string]$Value) -Name $Name
    }

    return [pscustomobject]$object
}

function Invoke-CollectionStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter()][switch]$WarningOnly
    )

    try {
        return & $ScriptBlock
    }
    catch {
        $message = $_.Exception.Message
        if ($WarningOnly) {
            Add-CollectionWarning -Step $Name -Message $message
            return $null
        }

        Add-CollectionError -Step $Name -Message $message
        return $null
    }
}

function Get-CommandOutput {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter()][scriptblock]$Projection
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }

    $result = Invoke-CollectionStep -Name $CommandName -WarningOnly -ScriptBlock {
        if ($Projection) {
            & $Projection
        }
        else {
            & $CommandName
        }
    }
    return ConvertTo-SafeValue -Value $result -Name $CommandName
}

function Get-ModuleAvailability {
    $moduleNames = @(
        "ADSync",
        "ADFS",
        "WebApplicationProxy",
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Identity.DirectoryManagement",
        "MSOnline",
        "AzureAD"
    )

    $rows = @()
    foreach ($name in $moduleNames) {
        $module = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
        $rows += [pscustomobject][ordered]@{
            Name = $name
            Available = [bool]$module
            Version = if ($module) { [string]$module.Version } else { "" }
            Path = if ($module) { Protect-Text -Value $module.Path -Name "Path" } else { "" }
        }
    }
    return @($rows)
}

function Get-HostSummary {
    $os = Invoke-CollectionStep -Name "ComputerInfo" -WarningOnly -ScriptBlock {
        if (Get-Command Get-ComputerInfo -ErrorAction SilentlyContinue) {
            Get-ComputerInfo | Select-Object CsName, CsDNSHostName, CsDomain, OsName, OsVersion, OsBuildNumber
        }
    }

    if ($os) {
        return ConvertTo-SafeValue -Value $os -Name "Host"
    }

    return [pscustomobject][ordered]@{
        ComputerName = $env:COMPUTERNAME
        UserDnsDomain = Protect-Text -Value $env:USERDNSDOMAIN -Name "Domain"
        OperatingSystem = ""
    }
}

function Get-ServiceSummaries {
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        return @()
    }

    $namePatterns = @(
        "ADSync",
        "adfssrv",
        "AppProxy",
        "WebApplicationProxy",
        "AzureADConnectAuthenticationAgent",
        "Azure AD Connect Authentication Agent",
        "AzureADConnectHealth*",
        "Microsoft Entra Connect*",
        "Azure AD*"
    )

    $services = @()
    foreach ($pattern in $namePatterns) {
        $services += @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
        $services += @(Get-Service -DisplayName $pattern -ErrorAction SilentlyContinue)
    }

    $services = @($services | Where-Object { $_ } | Sort-Object Name -Unique)
    $rows = @()
    foreach ($service in $services) {
        $rows += [pscustomobject][ordered]@{
            Name = $service.Name
            DisplayName = $service.DisplayName
            Status = [string]$service.Status
            StartType = if ($service.PSObject.Properties["StartType"]) { [string]$service.StartType } else { "" }
            ServiceType = [string]$service.ServiceType
        }
    }
    return @($rows)
}

function Get-RegistrySnapshot {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Azure AD Connect",
        "HKLM:\SOFTWARE\Microsoft\AD Sync",
        "HKLM:\SYSTEM\CurrentControlSet\Services\ADSync\Parameters",
        "HKLM:\SOFTWARE\Microsoft\ADFS",
        "HKLM:\SOFTWARE\Microsoft\ADFS\ProxyConfigurationStatus",
        "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Authentication Agent"
    )

    $items = @()
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $values = Invoke-CollectionStep -Name "Registry:$path" -WarningOnly -ScriptBlock {
            Get-ItemProperty -LiteralPath $path
        }
        $items += [pscustomobject][ordered]@{
            Path = $path
            Values = ConvertTo-SafeValue -Value $values -Name $path
        }
    }
    return @($items)
}

function Get-EntraConnectState {
    $state = [ordered]@{
        ModuleAvailable = [bool](Get-Module -ListAvailable -Name ADSync)
        Scheduler = $null
        Connectors = @()
        SyncRules = @()
        CompanyFeatures = $null
        GlobalSettings = $null
        ServerConfiguration = $null
        Notes = @()
    }

    if (-not $state.ModuleAvailable) {
        $state.Notes += "ADSync module was not found on this host."
        return [pscustomobject]$state
    }

    Invoke-CollectionStep -Name "Import ADSync" -WarningOnly -ScriptBlock {
        Import-Module ADSync -ErrorAction Stop
    } | Out-Null

    $state.Scheduler = Get-CommandOutput -CommandName "Get-ADSyncScheduler"
    $state.Connectors = @(Get-CommandOutput -CommandName "Get-ADSyncConnector")
    $state.SyncRules = @(Get-CommandOutput -CommandName "Get-ADSyncRule")
    $state.CompanyFeatures = Get-CommandOutput -CommandName "Get-ADSyncAADCompanyFeature"
    $state.GlobalSettings = Get-CommandOutput -CommandName "Get-ADSyncGlobalSettings"
    $state.ServerConfiguration = Get-CommandOutput -CommandName "Get-ADSyncServerConfiguration"

    return [pscustomobject]$state
}

function Get-RuleSummaryObject {
    param([Parameter()][object]$RuleText)

    $text = [string]$RuleText
    if (-not $text) {
        return [pscustomobject][ordered]@{
            RuleCount = 0
            ClaimTypes = @()
            RawRulesCollected = $false
        }
    }

    $claimTypes = @()
    foreach ($match in [regex]::Matches($text, '(?i)type\s*==\s*"([^"]+)"|Type\s*=\s*"([^"]+)"')) {
        $claimType = $match.Groups[1].Value
        if (-not $claimType) {
            $claimType = $match.Groups[2].Value
        }
        if ($claimType) {
            $claimTypes += ($claimType -replace '^https?://schemas\.[^/]+/', '')
        }
    }

    [pscustomobject][ordered]@{
        RuleCount = ([regex]::Matches($text, '=>')).Count
        ClaimTypes = @($claimTypes | Select-Object -Unique)
        RawRulesCollected = $false
    }
}

function Get-AdfsState {
    $module = Get-Module -ListAvailable -Name ADFS | Sort-Object Version -Descending | Select-Object -First 1
    $service = Get-Service -Name adfssrv -ErrorAction SilentlyContinue

    $state = [ordered]@{
        ModuleAvailable = [bool]$module
        ServicePresent = [bool]$service
        ServiceStatus = if ($service) { [string]$service.Status } else { "" }
        FarmInformation = $null
        Properties = $null
        SyncProperties = $null
        RelyingPartyTrusts = @()
        Certificates = @()
        Notes = @()
    }

    if (-not $module) {
        $state.Notes += "ADFS module was not found on this host."
        return [pscustomobject]$state
    }

    Invoke-CollectionStep -Name "Import ADFS" -WarningOnly -ScriptBlock {
        Import-Module ADFS -ErrorAction Stop
    } | Out-Null

    $state.FarmInformation = Get-CommandOutput -CommandName "Get-AdfsFarmInformation"
    $state.Properties = Get-CommandOutput -CommandName "Get-AdfsProperties"
    $state.SyncProperties = Get-CommandOutput -CommandName "Get-AdfsSyncProperties"

    $certs = Invoke-CollectionStep -Name "Get-AdfsCertificate" -WarningOnly -ScriptBlock {
        Get-AdfsCertificate | ForEach-Object {
            [pscustomobject][ordered]@{
                CertificateType = $_.CertificateType
                IsPrimary = $_.IsPrimary
                Thumbprint = $_.Thumbprint
                Subject = if ($_.Certificate) { $_.Certificate.Subject } else { "" }
                NotBefore = if ($_.Certificate) { $_.Certificate.NotBefore } else { $null }
                NotAfter = if ($_.Certificate) { $_.Certificate.NotAfter } else { $null }
            }
        }
    }
    $state.Certificates = @(ConvertTo-SafeValue -Value $certs -Name "Certificates")

    $rps = Invoke-CollectionStep -Name "Get-AdfsRelyingPartyTrust" -WarningOnly -ScriptBlock {
        Get-AdfsRelyingPartyTrust | ForEach-Object {
            [pscustomobject][ordered]@{
                Name = $_.Name
                Enabled = $_.Enabled
                Identifier = $_.Identifier
                ProtocolProfile = $_.ProtocolProfile
                AccessControlPolicyName = $_.AccessControlPolicyName
                TokenLifetime = $_.TokenLifetime
                SignatureAlgorithm = $_.SignatureAlgorithm
                IssuanceAuthorizationRulesSummary = Get-RuleSummaryObject -RuleText $_.IssuanceAuthorizationRules
                IssuanceTransformRulesSummary = Get-RuleSummaryObject -RuleText $_.IssuanceTransformRules
                ClaimRulesSummary = Get-RuleSummaryObject -RuleText $_.IssuanceTransformRules
                EncryptionCertificate = if ($_.EncryptionCertificate) {
                    [pscustomobject][ordered]@{
                        Subject = $_.EncryptionCertificate.Subject
                        Thumbprint = $_.EncryptionCertificate.Thumbprint
                        NotBefore = $_.EncryptionCertificate.NotBefore
                        NotAfter = $_.EncryptionCertificate.NotAfter
                    }
                } else { $null }
            }
        }
    }
    $state.RelyingPartyTrusts = @(ConvertTo-SafeValue -Value $rps -Name "RelyingPartyTrusts")

    return [pscustomobject]$state
}

function Get-WapState {
    $module = Get-Module -ListAvailable -Name WebApplicationProxy | Sort-Object Version -Descending | Select-Object -First 1
    $state = [ordered]@{
        ModuleAvailable = [bool]$module
        Configuration = $null
        Applications = @()
        Notes = @()
    }

    if (-not $module) {
        $state.Notes += "WebApplicationProxy module was not found on this host."
        return [pscustomobject]$state
    }

    Invoke-CollectionStep -Name "Import WebApplicationProxy" -WarningOnly -ScriptBlock {
        Import-Module WebApplicationProxy -ErrorAction Stop
    } | Out-Null

    $state.Configuration = Get-CommandOutput -CommandName "Get-WebApplicationProxyConfiguration"
    $apps = Invoke-CollectionStep -Name "Get-WebApplicationProxyApplication" -WarningOnly -ScriptBlock {
        Get-WebApplicationProxyApplication | Select-Object Name, ExternalUrl, BackendServerUrl, ExternalCertificateThumbprint, ADFSRelyingPartyName, Enabled
    }
    $state.Applications = @(ConvertTo-SafeValue -Value $apps -Name "WebApplicationProxyApplications")
    return [pscustomobject]$state
}

function Get-PtaState {
    $services = @(Get-Service -Name "AzureADConnectAuthenticationAgent" -ErrorAction SilentlyContinue)
    $services += @(Get-Service -DisplayName "*Authentication Agent*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)(Azure AD|Microsoft Entra|Pass-through)' })
    $services = @($services | Sort-Object Name -Unique)

    $agentPath = "C:\Program Files\Microsoft Azure AD Connect Authentication Agent"
    $modules = @()
    if (Test-Path -LiteralPath $agentPath) {
        $modules = @(Get-ChildItem -LiteralPath $agentPath -Recurse -Filter "*.psd1" -ErrorAction SilentlyContinue | Select-Object -First 20 FullName)
    }

    [pscustomobject][ordered]@{
        AgentServices = @(ConvertTo-SafeValue -Value $services -Name "AgentServices")
        AgentPathPresent = Test-Path -LiteralPath $agentPath
        AgentModules = @(ConvertTo-SafeValue -Value $modules -Name "AgentModules")
        HealthIndicators = @(
            [pscustomobject][ordered]@{
                Name = "LocalServiceEvidence"
                Value = if ($services.Count -gt 0) { "Detected" } else { "NotDetected" }
                Notes = "Cloud-side agent registration and health requires optional cloud/API export."
            }
        )
    }
}

function Get-CloudState {
    $state = [ordered]@{
        CollectionBoundary = "OptionalCloudApi"
        Requested = [bool]$IncludeCloud
        ModulesTried = @()
        GraphContext = $null
        Organization = $null
        Domains = @()
        DirectoryOnPremisesSynchronization = @()
        Notes = @()
    }

    if (-not $IncludeCloud) {
        $state.Notes += "Cloud/API collection was not requested."
        return [pscustomobject]$state
    }

    $graphAuth = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Select-Object -First 1
    if ($graphAuth) {
        $state.ModulesTried += "Microsoft.Graph"
        Invoke-CollectionStep -Name "Import Microsoft.Graph.Authentication" -WarningOnly -ScriptBlock {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        } | Out-Null

        $context = Get-CommandOutput -CommandName "Get-MgContext"
        $state.GraphContext = $context
        if ($context) {
            Invoke-CollectionStep -Name "Import Microsoft.Graph.Identity.DirectoryManagement" -WarningOnly -ScriptBlock {
                Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
            } | Out-Null
            $state.Organization = Get-CommandOutput -CommandName "Get-MgOrganization"
            $state.Domains = @(Get-CommandOutput -CommandName "Get-MgDomain")
            $state.DirectoryOnPremisesSynchronization = @(Get-CommandOutput -CommandName "Get-MgDirectoryOnPremiseSynchronization")
        }
        else {
            $state.Notes += "Microsoft Graph module is available, but no existing Graph context was readable. The collector does not initiate sign-in."
        }
    }
    else {
        $state.Notes += "Microsoft Graph PowerShell modules were not found."
    }

    return [pscustomobject]$state
}

function Get-OfflineExports {
    param([Parameter()][string]$Path)

    if (-not $Path) {
        return @()
    }

    $resolved = Resolve-Path -LiteralPath $Path
    $files = @()
    if ((Get-Item -LiteralPath $resolved.Path).PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $resolved.Path -File -Recurse | Sort-Object FullName)
    }
    else {
        $files = @(Get-Item -LiteralPath $resolved.Path)
    }

    $exports = @()
    foreach ($file in $files) {
        $entry = [ordered]@{
            Name = $file.Name
            FullName = Protect-Text -Value $file.FullName -Name "Path"
            Extension = $file.Extension
            Length = $file.Length
            LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
            ParsedType = "NotParsed"
            ParsedObject = $null
            TextPreview = @()
            Notes = ""
        }

        try {
            switch -Regex ($file.Extension) {
                '\.json$' {
                    $entry.ParsedType = "Json"
                    $entry.ParsedObject = ConvertTo-SafeValue -Value (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json) -Name $file.Name
                    break
                }
                '\.csv$' {
                    $entry.ParsedType = "Csv"
                    $entry.ParsedObject = @(ConvertTo-SafeValue -Value (Import-Csv -LiteralPath $file.FullName) -Name $file.Name)
                    break
                }
                '\.xml$' {
                    $entry.ParsedType = "XmlTextPreview"
                    $entry.TextPreview = @(Get-Content -LiteralPath $file.FullName -TotalCount 300 | ForEach-Object { Protect-Text -Value $_ -Name $file.Name })
                    break
                }
                '\.(txt|log|out)$' {
                    $entry.ParsedType = "TextPreview"
                    $entry.TextPreview = @(Get-Content -LiteralPath $file.FullName -TotalCount 300 | ForEach-Object { Protect-Text -Value $_ -Name $file.Name })
                    break
                }
                default {
                    $entry.Notes = "File type was cataloged but not parsed."
                }
            }
        }
        catch {
            $entry.ParsedType = "ParseFailed"
            $entry.Notes = $_.Exception.Message
        }

        $exports += [pscustomobject]$entry
    }

    return @($exports)
}

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$nameSeed = if ($CollectionName) { $CollectionName } elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "hybrid-identity" }
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$fileName = "{0}.{1}.hybrid.collection.json" -f (ConvertTo-SafeFileName -Value $nameSeed), $timestamp
$outputFile = Join-Path $outputDirectory.FullName $fileName
if ((Test-Path -LiteralPath $outputFile) -and $NoClobber) {
    throw "Output file already exists: $outputFile"
}

$moduleAvailability = Invoke-CollectionStep -Name "ModuleAvailability" -WarningOnly -ScriptBlock { Get-ModuleAvailability }
$hostSummary = Invoke-CollectionStep -Name "HostSummary" -WarningOnly -ScriptBlock { Get-HostSummary }
$services = Invoke-CollectionStep -Name "ServiceSummaries" -WarningOnly -ScriptBlock { Get-ServiceSummaries }
$registry = Invoke-CollectionStep -Name "RegistrySnapshot" -WarningOnly -ScriptBlock { Get-RegistrySnapshot }
$offlineExports = Invoke-CollectionStep -Name "OfflineExports" -WarningOnly -ScriptBlock { Get-OfflineExports -Path $OfflineExportPath }

$entraConnect = $null
$adfs = $null
$wap = $null
$pta = $null
if (-not $NoLiveDiscovery) {
    $entraConnect = Invoke-CollectionStep -Name "EntraConnect" -WarningOnly -ScriptBlock { Get-EntraConnectState }
    $adfs = Invoke-CollectionStep -Name "ADFS" -WarningOnly -ScriptBlock { Get-AdfsState }
    $wap = Invoke-CollectionStep -Name "WebApplicationProxy" -WarningOnly -ScriptBlock { Get-WapState }
    $pta = Invoke-CollectionStep -Name "PTA" -WarningOnly -ScriptBlock { Get-PtaState }
}
else {
    Add-CollectionWarning -Step "LiveDiscovery" -Message "Live local discovery was skipped by -NoLiveDiscovery."
}

$cloud = Invoke-CollectionStep -Name "Cloud" -WarningOnly -ScriptBlock { Get-CloudState }

$collection = [ordered]@{
    Metadata = [ordered]@{
        Source = "HybridIdentityFederationToolkit"
        ToolkitVersion = "0.1.0"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString("o")
        ComputerName = $env:COMPUTERNAME
        CollectionName = $CollectionName
        OfflineExportPath = if ($OfflineExportPath) { Protect-Text -Value (Resolve-Path -LiteralPath $OfflineExportPath).Path -Name "Path" } else { "" }
        LiveDiscoveryEnabled = (-not $NoLiveDiscovery)
        CloudCollectionRequested = [bool]$IncludeCloud
        RedactionEnabled = (-not $NoRedaction)
        CollectionStatus = if ($script:CollectionErrors.Count -gt 0) { "CompletedWithErrors" } elseif ($script:CollectionWarnings.Count -gt 0) { "CompletedWithWarnings" } else { "Completed" }
    }
    Host = $hostSummary
    ModuleAvailability = @($moduleAvailability)
    Services = @($services)
    Registry = @($registry)
    EntraConnect = $entraConnect
    Adfs = $adfs
    Wap = $wap
    PassThroughAuthentication = $pta
    Cloud = $cloud
    OfflineExports = @($offlineExports)
    CollectionWarnings = @($script:CollectionWarnings)
    CollectionErrors = @($script:CollectionErrors)
}

([pscustomobject]$collection) | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $outputFile -Encoding UTF8

[pscustomobject]@{
    OutputFile = $outputFile
    RedactionEnabled = (-not $NoRedaction)
    LiveDiscoveryEnabled = (-not $NoLiveDiscovery)
    CloudCollectionRequested = [bool]$IncludeCloud
    WarningCount = $script:CollectionWarnings.Count
    ErrorCount = $script:CollectionErrors.Count
}
