#requires -Version 5.1
<#
.SYNOPSIS
Merges hybrid identity and federation discovery exports into inventory and review CSVs.

.DESCRIPTION
Offline-first aggregation. The script reads *.collection.json files produced by
Export-HybridIdentityCollection.ps1 and optional manually prepared CSV exports
placed in the input folder. It writes inventory.json plus review CSVs for
Microsoft Entra Connect / Azure AD Connect, AD FS, WAP, PTA, writeback, and
required endpoint/port review data.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath = ".\output\01-merged-inventory",

    [Parameter()]
    [switch]$Recurse,

    [Parameter()]
    [switch]$NoRedaction
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$SummaryFields = @(
    "ComponentId",
    "ComponentType",
    "Name",
    "ServerName",
    "Role",
    "SyncMode",
    "PasswordHashSync",
    "PassThroughAuthentication",
    "Federation",
    "StagingMode",
    "SourceAnchor",
    "ImmutableIdAttribute",
    "WritebackFeatures",
    "Tenant",
    "CollectionStatus",
    "Evidence",
    "SourceCollection",
    "Notes"
)

$ConnectorFields = @(
    "ConnectorId",
    "ConnectorName",
    "ConnectorType",
    "ServerName",
    "ForestOrTenant",
    "IsEnabled",
    "Partitions",
    "IncludedOUs",
    "ExcludedOUs",
    "ConnectorSpaceObjectCount",
    "LastImport",
    "LastExport",
    "LastSync",
    "SourceCollection",
    "Notes"
)

$ScopeFields = @(
    "ScopeId",
    "ScopeType",
    "Forest",
    "Domain",
    "Partition",
    "IncludedOUs",
    "ExcludedOUs",
    "FilteringMode",
    "ObjectTypes",
    "GroupsScoped",
    "ConnectorName",
    "SourceCollection",
    "Notes"
)

$RuleFields = @(
    "RuleId",
    "RuleName",
    "Direction",
    "Precedence",
    "ConnectorName",
    "ConnectedSystem",
    "LinkType",
    "SourceObjectType",
    "TargetObjectType",
    "Enabled",
    "ImmutableTag",
    "TransformSummary",
    "JoinSummary",
    "SourceCollection",
    "Notes"
)

$FarmFields = @(
    "FarmId",
    "FarmName",
    "ServiceName",
    "FederationServiceIdentifier",
    "BehaviorLevel",
    "Servers",
    "Proxies",
    "FarmNodes",
    "WapServers",
    "SslCertificateThumbprint",
    "TokenSigningCertExpires",
    "TokenDecryptingCertExpires",
    "CertificateRisk",
    "SourceCollection",
    "Notes"
)

$RelyingPartyFields = @(
    "RpId",
    "Name",
    "Identifier",
    "Enabled",
    "ProtocolProfile",
    "AccessControlPolicyName",
    "IssuanceAuthorizationRulesSummary",
    "IssuanceTransformRulesSummary",
    "ClaimRulesSummary",
    "TokenLifetime",
    "EncryptionCertificateExpires",
    "SignatureAlgorithm",
    "SourceCollection",
    "Notes"
)

$CertificateFields = @(
    "CertificateId",
    "ServiceName",
    "CertificateType",
    "IsPrimary",
    "Subject",
    "Thumbprint",
    "NotBefore",
    "NotAfter",
    "DaysUntilExpiration",
    "Risk",
    "SourceCollection",
    "Notes"
)

$FindingFields = @(
    "FindingId",
    "Severity",
    "Area",
    "ObjectName",
    "Finding",
    "Evidence",
    "Recommendation",
    "SourceCollection"
)

$EndpointFields = @(
    "EndpointId",
    "Area",
    "Source",
    "Destination",
    "Protocol",
    "Port",
    "Direction",
    "Purpose",
    "EvidenceType",
    "ReferenceSource",
    "Notes"
)

$TopologyFields = @(
    "HybridEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "Label",
    "Status",
    "SourceCollection",
    "Notes"
)

function ConvertTo-ObjectArray {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ($Value.Trim()) {
            return @($Value)
        }
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $items += $item
            }
        }
        return @($items)
    }

    return @($Value)
}

function Get-PropertyValue {
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

function Get-PathValue {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $null
        }
        $property = $current.PSObject.Properties[$name]
        if (-not $property) {
            return $null
        }
        $current = $property.Value
    }

    return $current
}

function ConvertTo-Text {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return $Value.Trim()
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $text = ConvertTo-Text -Value $item
            if ($text) {
                $items += $text
            }
        }
        return ($items -join "; ")
    }

    return ([string]$Value).Trim()
}

function ConvertTo-BoolText {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    $text = ConvertTo-Text -Value $Value
    if (-not $text) {
        return ""
    }

    if ($text -in @("1", "true", "True", "TRUE", "yes", "Yes", "enabled", "Enabled")) {
        return "true"
    }

    if ($text -in @("0", "false", "False", "FALSE", "no", "No", "disabled", "Disabled")) {
        return "false"
    }

    return $text
}

function Get-FirstText {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    return ConvertTo-Text -Value (Get-PropertyValue -InputObject $InputObject -Names $Names)
}

function ConvertTo-JsonText {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    try {
        return ($Value | ConvertTo-Json -Depth 30 -Compress)
    }
    catch {
        return ConvertTo-Text -Value $Value
    }
}

function Protect-Value {
    param(
        [Parameter()][object]$Value,
        [Parameter()][string]$FieldName
    )

    $text = ConvertTo-Text -Value $Value
    if (-not $text -or $NoRedaction) {
        return $text
    }

    $nonSecretPasswordConfig = $FieldName -match '(?i)password(hashsync|hash|writeback|sync|feature|enabled|mode)?$'
    if (-not $nonSecretPasswordConfig -and $FieldName -match '(?i)(password|secret|private|credential|token|client.?secret|keymaterial|pfx|rawdata)') {
        return "[REDACTED]"
    }

    if ($FieldName -match '(?i)^(Tenant|TenantId|TenantName|AzureAdTenant|EntraTenant)$') {
        return "[REDACTED:Tenant]"
    }

    if ($FieldName -match '(?i)^ForestOrTenant$' -and $text -match '(?i)(onmicrosoft\.com|\.mail\.onmicrosoft\.com|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b)') {
        return "[REDACTED:Tenant]"
    }

    $attributeNameField = $FieldName -match '(?i)(ImmutableIdAttribute|SourceAnchor)$'
    if (-not $attributeNameField -and $FieldName -match '(?i)(tenant|immutable|thumbprint|identifier|client.?id|object.?id|issuer|realm)') {
        $text = $text -replace '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '[REDACTED:GUID]'
        $text = $text -replace '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '[REDACTED:UPN]'
        if ($FieldName -match '(?i)(thumbprint|immutable)') {
            if ($text.Length -gt 12 -and $text -notmatch '^\[REDACTED') {
                return "[REDACTED:$FieldName]"
            }
        }
    }

    $text = $text -replace '(?i)(client_secret=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '(?i)(access_token=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '(?i)(refresh_token=)[^;&\s]+', '$1[REDACTED]'
    $text = $text -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[REDACTED:JWT]'
    return $text
}

function ConvertTo-FieldRow {
    param(
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )

    $ordered = [ordered]@{}
    foreach ($field in $Fields) {
        $ordered[$field] = Protect-Value -Value (Get-PropertyValue -InputObject $Row -Names @($field)) -FieldName $field
    }
    return [pscustomobject]$ordered
}

function Import-ManualCsvRows {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )

    $path = Join-Path $Directory $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $rows = @()
    foreach ($row in @(Import-Csv -LiteralPath $path)) {
        $rows += ConvertTo-FieldRow -Row $row -Fields $Fields
    }
    return @($rows)
}

function Import-PackagedCsvRows {
    param(
        [Parameter()][object[]]$CollectionItems = @(),
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )

    if ($null -eq $CollectionItems -or $CollectionItems.Count -eq 0) {
        return @()
    }

    $rows = @()
    foreach ($collectionItem in @($CollectionItems)) {
        $exports = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collectionItem.Data -Names @("OfflineExports")))
        foreach ($export in $exports) {
            $name = Get-FirstText -InputObject $export -Names @("Name")
            if ($name -ine $FileName) {
                continue
            }

            $parsed = Get-PropertyValue -InputObject $export -Names @("ParsedObject")
            foreach ($row in @(ConvertTo-ObjectArray -Value $parsed)) {
                $rows += ConvertTo-FieldRow -Row $row -Fields $Fields
            }
        }
    }

    return @($rows)
}

function Get-DateValue {
    param([Parameter()][object]$Value)

    $text = ConvertTo-Text -Value $Value
    if (-not $text) {
        return $null
    }

    try {
        return ([DateTime]$text).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-DaysUntil {
    param([Parameter()][object]$Value)

    $date = Get-DateValue -Value $Value
    if ($null -eq $date) {
        return ""
    }

    return [math]::Floor(($date - [DateTime]::UtcNow).TotalDays)
}

function Get-ExpirationRisk {
    param([Parameter()][object]$Value)

    $days = Get-DaysUntil -Value $Value
    if ($days -eq "") {
        return ""
    }
    if ([int]$days -lt 0) {
        return "Expired"
    }
    if ([int]$days -le 30) {
        return "Critical"
    }
    if ([int]$days -le 90) {
        return "Warning"
    }
    return "OK"
}

function Get-RuleBlockSummary {
    param(
        [Parameter()][object]$Rule,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $value = Get-PropertyValue -InputObject $Rule -Names $Names
    $items = @(ConvertTo-ObjectArray -Value $value)
    if ($items.Count -eq 0) {
        $text = ConvertTo-Text -Value $value
        if ($text) {
            return $text
        }
        return ""
    }

    $labels = @()
    foreach ($item in $items) {
        $label = Get-FirstText -InputObject $item -Names @("TargetAttributeName", "TargetAttribute", "Attribute", "Name", "FlowType", "MappingType")
        if ($label) {
            $labels += $label
        }
    }
    $labels = @($labels | Select-Object -Unique | Select-Object -First 8)
    if ($labels.Count -gt 0) {
        return "$($items.Count) item(s): $($labels -join ', ')"
    }

    return "$($items.Count) item(s)"
}

function Get-ClaimRuleSummary {
    param([Parameter()][object]$Value)

    $text = ConvertTo-Text -Value $Value
    if (-not $text) {
        return ""
    }

    $ruleCount = ([regex]::Matches($text, '=>')).Count
    if ($ruleCount -eq 0) {
        $ruleCount = ([regex]::Matches($text, '\bc:\[')).Count
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
    $claimTypes = @($claimTypes | Select-Object -Unique | Select-Object -First 8)

    if ($claimTypes.Count -gt 0) {
        return "$ruleCount rule(s); claim types: $($claimTypes -join ', ')"
    }
    return "$ruleCount rule(s)"
}

function Test-ObjectTextMatch {
    param(
        [Parameter()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $text = ConvertTo-JsonText -Value $Value
    return ($text -match $Pattern)
}

function New-Finding {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Area,
        [Parameter()][string]$ObjectName,
        [Parameter(Mandatory = $true)][string]$Finding,
        [Parameter()][string]$Evidence,
        [Parameter()][string]$Recommendation,
        [Parameter()][string]$SourceCollection
    )

    [pscustomobject][ordered]@{
        FindingId = "HIF{0:000}" -f $Index
        Severity = $Severity
        Area = $Area
        ObjectName = Protect-Value -Value $ObjectName -FieldName "ObjectName"
        Finding = $Finding
        Evidence = Protect-Value -Value $Evidence -FieldName "Evidence"
        Recommendation = $Recommendation
        SourceCollection = $SourceCollection
    }
}

function New-TopologyEdge {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceType,
        [Parameter(Mandatory = $true)][string]$Relationship,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$TargetType,
        [Parameter()][string]$Label,
        [Parameter()][string]$Status,
        [Parameter()][string]$SourceCollection,
        [Parameter()][string]$Notes
    )

    [pscustomobject][ordered]@{
        HybridEdgeId = "HI{0:00}" -f $Index
        Source = Protect-Value -Value $Source -FieldName "Source"
        SourceType = $SourceType
        Relationship = $Relationship
        Target = Protect-Value -Value $Target -FieldName "Target"
        TargetType = $TargetType
        Label = Protect-Value -Value $Label -FieldName "Label"
        Status = $Status
        SourceCollection = $SourceCollection
        Notes = Protect-Value -Value $Notes -FieldName "Notes"
    }
}

function Get-CollectionServerName {
    param(
        [Parameter(Mandatory = $true)][object]$Collection,
        [Parameter()][string]$DefaultName
    )

    $paths = @()
    $paths += ,@("Metadata", "ComputerName")
    $paths += ,@("Metadata", "QueriedServer")
    $paths += ,@("Host", "ComputerName")
    $paths += ,@("Host", "DnsHostName")

    foreach ($path in $paths) {
        $value = ConvertTo-Text -Value (Get-PathValue -InputObject $Collection -Path $path)
        if ($value) {
            return $value
        }
    }
    return $DefaultName
}

function Get-SyncModeSummary {
    param(
        [Parameter()][object]$EntraConnect,
        [Parameter()][object]$Adfs,
        [Parameter()][object]$Pta
    )

    $phs = ""
    $pta = ""
    $fed = ""
    $staging = ""

    $scheduler = Get-PropertyValue -InputObject $EntraConnect -Names @("Scheduler", "ADSyncScheduler")
    $features = Get-PropertyValue -InputObject $EntraConnect -Names @("CompanyFeatures", "FeatureConfig", "Features")
    $featureText = ConvertTo-JsonText -Value $features
    $entraText = ConvertTo-JsonText -Value $EntraConnect
    $ptaText = ConvertTo-JsonText -Value $Pta
    $adfsText = ConvertTo-JsonText -Value $Adfs

    $staging = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $scheduler -Names @("StagingModeEnabled", "StagingMode", "IsStagingModeEnabled"))
    if ($featureText -match '(?i)password.?hash|passwordhashsync') {
        if ($featureText -match '(?i)(passwordhashsyncenabled|password.?hash.?sync).{0,80}(true|enabled)') {
            $phs = "true"
        }
        else {
            $phs = "detected"
        }
    }
    elseif ($entraText -match '(?i)password.?hash') {
        $phs = "detected"
    }

    if ($ptaText -match '(?i)(authentication.?agent|pass.?through|passthrough|AzureADConnectAuthenticationAgent)') {
        $pta = "detected"
    }
    if ($featureText -match '(?i)(pass.?through|passthrough).{0,80}(true|enabled)') {
        $pta = "true"
    }

    if ($adfsText -match '(?i)(federationservice|relyingparty|adfs)') {
        $fed = "detected"
    }
    if ($entraText -match '(?i)federat') {
        $fed = "detected"
    }

    $modes = @()
    if ($phs) { $modes += "PasswordHashSync" }
    if ($pta) { $modes += "PassThroughAuthentication" }
    if ($fed) { $modes += "Federation" }
    if ($modes.Count -eq 0) { $modes += "Unknown" }

    [pscustomobject]@{
        SyncMode = ($modes -join "; ")
        PasswordHashSync = $phs
        PassThroughAuthentication = $pta
        Federation = $fed
        StagingMode = $staging
    }
}

function Get-SourceAnchorSummary {
    param([Parameter()][object]$EntraConnect)

    $text = ConvertTo-JsonText -Value $EntraConnect
    $anchor = ""
    $immutable = ""

    foreach ($pattern in @('mS-DS-ConsistencyGuid', 'msDS-ConsistencyGuid', 'objectGUID', 'sourceAnchor', 'sourceAnchorBinary', 'immutableId')) {
        if ($text -match [regex]::Escape($pattern)) {
            if (-not $anchor) {
                $anchor = $pattern
            }
            if ($pattern -eq 'sourceAnchorBinary') {
                $immutable = $pattern
            }
            elseif (-not $immutable -and $pattern -match '(?i)immutable|sourceAnchor') {
                $immutable = $pattern
            }
        }
    }

    [pscustomobject]@{
        SourceAnchor = $anchor
        ImmutableIdAttribute = $immutable
    }
}

function Get-WritebackSummary {
    param([Parameter()][object]$EntraConnect)

    $text = ConvertTo-JsonText -Value $EntraConnect
    $features = @()
    if ($text -match '(?i)password.?write.?back|passwordwriteback') { $features += "PasswordWriteback" }
    if ($text -match '(?i)group.?write.?back|groupwriteback') { $features += "GroupWriteback" }
    if ($text -match '(?i)device.?write.?back|devicewriteback') { $features += "DeviceWriteback" }
    if ($text -match '(?i)exchange.?hybrid|exchangehybrid|hybrid.?deployment') { $features += "ExchangeHybrid" }
    if ($features.Count -eq 0) {
        return ""
    }
    return (@($features | Select-Object -Unique) -join "; ")
}

function Get-ConnectorRows {
    param(
        [Parameter()][object]$EntraConnect,
        [Parameter()][string]$ServerName,
        [Parameter()][string]$CollectionPath
    )

    $connectors = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $EntraConnect -Names @("Connectors", "ConnectorSummaries", "ADSyncConnectors")))
    $rows = @()
    $index = 0
    foreach ($connector in $connectors) {
        $index++
        $name = Get-FirstText -InputObject $connector -Names @("Name", "ConnectorName", "DisplayName", "Identifier")
        $type = Get-FirstText -InputObject $connector -Names @("ConnectorTypeName", "ConnectorType", "Type", "ManagementAgentType", "SubType")
        $forest = Get-FirstText -InputObject $connector -Names @("ForestName", "ConnectedDirectory", "ConnectedSystem", "Domain", "Tenant", "DirectoryName")
        $includedOus = Get-FirstText -InputObject $connector -Names @("IncludedOUs", "IncludedContainers", "ObjectInclusionList", "SelectedContainers", "Containers")
        $excludedOus = Get-FirstText -InputObject $connector -Names @("ExcludedOUs", "ExcludedContainers", "ObjectExclusionList")
        $partitions = Get-FirstText -InputObject $connector -Names @("Partitions", "PartitionInfo", "SelectedPartitions", "NamingContexts")
        $enabled = Get-FirstText -InputObject $connector -Names @("Enabled", "IsEnabled")
        if (-not $enabled) {
            $disabled = Get-FirstText -InputObject $connector -Names @("Disabled", "IsDisabled")
            if ($disabled) {
                if ((ConvertTo-BoolText -Value $disabled) -eq "true") {
                    $enabled = "false"
                }
                else {
                    $enabled = "true"
                }
            }
        }

        $rows += [pscustomobject][ordered]@{
            ConnectorId = "CON{0:00}" -f $index
            ConnectorName = Protect-Value -Value $name -FieldName "ConnectorName"
            ConnectorType = $type
            ServerName = $ServerName
            ForestOrTenant = Protect-Value -Value $forest -FieldName "ForestOrTenant"
            IsEnabled = ConvertTo-BoolText -Value $enabled
            Partitions = Protect-Value -Value $partitions -FieldName "Partitions"
            IncludedOUs = Protect-Value -Value $includedOus -FieldName "IncludedOUs"
            ExcludedOUs = Protect-Value -Value $excludedOus -FieldName "ExcludedOUs"
            ConnectorSpaceObjectCount = Get-FirstText -InputObject $connector -Names @("ConnectorSpaceObjectCount", "ObjectCount", "CSObjectCount")
            LastImport = Get-FirstText -InputObject $connector -Names @("LastImport", "LastImportTime")
            LastExport = Get-FirstText -InputObject $connector -Names @("LastExport", "LastExportTime")
            LastSync = Get-FirstText -InputObject $connector -Names @("LastSync", "LastRun", "LastRunTime")
            SourceCollection = $CollectionPath
            Notes = Protect-Value -Value (Get-FirstText -InputObject $connector -Names @("Notes", "Description")) -FieldName "Notes"
        }
    }
    return @($rows)
}

function Get-ScopeRows {
    param(
        [Parameter()][object[]]$ConnectorRows,
        [Parameter()][string]$CollectionPath
    )

    $rows = @()
    $index = 0
    foreach ($connector in @($ConnectorRows)) {
        if ($null -eq $connector) {
            continue
        }
        $index++
        $scopeType = "ConnectorScope"
        $filteringMode = "Unknown"
        if ($connector.IncludedOUs) {
            $filteringMode = "IncludeOUs"
        }
        if ($connector.ExcludedOUs) {
            if ($filteringMode -eq "IncludeOUs") {
                $filteringMode = "IncludeAndExcludeOUs"
            }
            else {
                $filteringMode = "ExcludeOUs"
            }
        }
        if ($connector.Partitions -and -not $connector.IncludedOUs -and -not $connector.ExcludedOUs) {
            $filteringMode = "Partition"
        }

        $rows += [pscustomobject][ordered]@{
            ScopeId = "SCP{0:00}" -f $index
            ScopeType = $scopeType
            Forest = $connector.ForestOrTenant
            Domain = ""
            Partition = $connector.Partitions
            IncludedOUs = $connector.IncludedOUs
            ExcludedOUs = $connector.ExcludedOUs
            FilteringMode = $filteringMode
            ObjectTypes = ""
            GroupsScoped = ""
            ConnectorName = $connector.ConnectorName
            SourceCollection = $CollectionPath
            Notes = $connector.Notes
        }
    }
    return @($rows)
}

function Get-RuleRows {
    param(
        [Parameter()][object]$EntraConnect,
        [Parameter()][string]$CollectionPath
    )

    $rules = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $EntraConnect -Names @("SyncRules", "Rules", "ADSyncRules")))
    $rows = @()
    $index = 0
    foreach ($rule in $rules) {
        $index++
        $disabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $rule -Names @("Disabled", "IsDisabled"))
        $enabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $rule -Names @("Enabled", "IsEnabled"))
        if (-not $enabled -and $disabled) {
            if ($disabled -eq "true") { $enabled = "false" } else { $enabled = "true" }
        }

        $rows += [pscustomobject][ordered]@{
            RuleId = "SR{0:000}" -f $index
            RuleName = Protect-Value -Value (Get-FirstText -InputObject $rule -Names @("Name", "RuleName", "DisplayName")) -FieldName "RuleName"
            Direction = Get-FirstText -InputObject $rule -Names @("Direction", "FlowDirection")
            Precedence = Get-FirstText -InputObject $rule -Names @("Precedence")
            ConnectorName = Protect-Value -Value (Get-FirstText -InputObject $rule -Names @("Connector", "ConnectorName", "ConnectedSystem")) -FieldName "ConnectorName"
            ConnectedSystem = Protect-Value -Value (Get-FirstText -InputObject $rule -Names @("ConnectedSystem", "ConnectedDirectory")) -FieldName "ConnectedSystem"
            LinkType = Get-FirstText -InputObject $rule -Names @("LinkType", "Link")
            SourceObjectType = Get-FirstText -InputObject $rule -Names @("SourceObjectType", "SourceType")
            TargetObjectType = Get-FirstText -InputObject $rule -Names @("TargetObjectType", "TargetType")
            Enabled = $enabled
            ImmutableTag = Protect-Value -Value (Get-FirstText -InputObject $rule -Names @("ImmutableTag", "Tag")) -FieldName "ImmutableTag"
            TransformSummary = Protect-Value -Value (Get-RuleBlockSummary -Rule $rule -Names @("Transformations", "AttributeFlowMappings", "Transforms")) -FieldName "TransformSummary"
            JoinSummary = Protect-Value -Value (Get-RuleBlockSummary -Rule $rule -Names @("JoinRules", "Join", "RelationshipCriteria")) -FieldName "JoinSummary"
            SourceCollection = $CollectionPath
            Notes = Protect-Value -Value (Get-FirstText -InputObject $rule -Names @("Description", "Notes")) -FieldName "Notes"
        }
    }
    return @($rows)
}

function Get-AdfsFarmRows {
    param(
        [Parameter()][object]$Adfs,
        [Parameter()][object]$Wap,
        [Parameter()][string]$ServerName,
        [Parameter()][string]$CollectionPath
    )

    $rows = @()
    if ($null -eq $Adfs) {
        return @()
    }

    $farm = Get-PropertyValue -InputObject $Adfs -Names @("FarmInformation", "Farm", "AdfsFarm")
    $props = Get-PropertyValue -InputObject $Adfs -Names @("Properties", "AdfsProperties")
    $certs = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $Adfs -Names @("Certificates", "AdfsCertificates")))
    $serviceName = Get-FirstText -InputObject $props -Names @("HostName", "FederationServiceName", "FederationServiceIdentifier", "Identifier")
    if (-not $serviceName) {
        $serviceName = Get-FirstText -InputObject $farm -Names @("FarmName", "ServiceName", "FederationServiceName")
    }
    if (-not $serviceName -and (ConvertTo-JsonText -Value $Adfs)) {
        $serviceName = "AD FS"
    }

    $tokenSigning = $certs | Where-Object { (Get-FirstText -InputObject $_ -Names @("CertificateType", "Type")) -match '(?i)token.?signing' } | Select-Object -First 1
    $tokenDecrypting = $certs | Where-Object { (Get-FirstText -InputObject $_ -Names @("CertificateType", "Type")) -match '(?i)token.?decrypt' } | Select-Object -First 1
    $ssl = $certs | Where-Object { (Get-FirstText -InputObject $_ -Names @("CertificateType", "Type")) -match '(?i)service.?communication|ssl' } | Select-Object -First 1

    $signingExpiry = Get-FirstText -InputObject $tokenSigning -Names @("NotAfter", "CertificateNotAfter", "Expiration")
    if (-not $signingExpiry) { $signingExpiry = ConvertTo-Text -Value (Get-PathValue -InputObject $tokenSigning -Path @("Certificate", "NotAfter")) }
    $decryptExpiry = Get-FirstText -InputObject $tokenDecrypting -Names @("NotAfter", "CertificateNotAfter", "Expiration")
    if (-not $decryptExpiry) { $decryptExpiry = ConvertTo-Text -Value (Get-PathValue -InputObject $tokenDecrypting -Path @("Certificate", "NotAfter")) }

    $risks = @()
    foreach ($risk in @((Get-ExpirationRisk -Value $signingExpiry), (Get-ExpirationRisk -Value $decryptExpiry))) {
        if ($risk -and $risk -ne "OK") { $risks += $risk }
    }
    $riskText = (@($risks | Select-Object -Unique) -join "; ")
    if (-not $riskText -and ($signingExpiry -or $decryptExpiry)) {
        $riskText = "OK"
    }

    $wapServers = Get-FirstText -InputObject $Wap -Names @("Servers", "WapServers", "ProxyServers")
    $farmNodes = Get-FirstText -InputObject $farm -Names @("FarmNodes", "Servers", "Nodes")
    if (-not $farmNodes) {
        $farmNodes = $ServerName
    }

    $rows += [pscustomobject][ordered]@{
        FarmId = "ADF001"
        FarmName = Protect-Value -Value (Get-FirstText -InputObject $farm -Names @("FarmName", "Name")) -FieldName "FarmName"
        ServiceName = Protect-Value -Value $serviceName -FieldName "Identifier"
        FederationServiceIdentifier = Protect-Value -Value (Get-FirstText -InputObject $props -Names @("FederationServiceIdentifier", "Identifier")) -FieldName "Identifier"
        BehaviorLevel = Get-FirstText -InputObject $farm -Names @("FarmBehavior", "BehaviorLevel", "FarmBehaviorLevel")
        Servers = Protect-Value -Value $farmNodes -FieldName "Servers"
        Proxies = Protect-Value -Value $wapServers -FieldName "Proxies"
        FarmNodes = Protect-Value -Value $farmNodes -FieldName "FarmNodes"
        WapServers = Protect-Value -Value $wapServers -FieldName "WapServers"
        SslCertificateThumbprint = Protect-Value -Value (Get-FirstText -InputObject $ssl -Names @("Thumbprint", "CertificateThumbprint")) -FieldName "Thumbprint"
        TokenSigningCertExpires = $signingExpiry
        TokenDecryptingCertExpires = $decryptExpiry
        CertificateRisk = $riskText
        SourceCollection = $CollectionPath
        Notes = Protect-Value -Value (Get-FirstText -InputObject $props -Names @("Notes", "Description")) -FieldName "Notes"
    }

    return @($rows)
}

function Get-RelyingPartyRows {
    param(
        [Parameter()][object]$Adfs,
        [Parameter()][string]$CollectionPath
    )

    $rps = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $Adfs -Names @("RelyingPartyTrusts", "RelyingParties", "RelyingPartySummaries")))
    $rows = @()
    $index = 0
    foreach ($rp in $rps) {
        $index++
        $encryptionExpiry = ""
        $encryptionCert = Get-PropertyValue -InputObject $rp -Names @("EncryptionCertificate", "EncryptionCertificates")
        if ($encryptionCert) {
            $encryptionExpiry = Get-FirstText -InputObject $encryptionCert -Names @("NotAfter", "CertificateNotAfter", "Expiration")
            if (-not $encryptionExpiry) { $encryptionExpiry = ConvertTo-Text -Value (Get-PathValue -InputObject $encryptionCert -Path @("Certificate", "NotAfter")) }
        }

        $transformRules = Get-PropertyValue -InputObject $rp -Names @("IssuanceTransformRules", "TransformRules", "ClaimRules")
        $authRules = Get-PropertyValue -InputObject $rp -Names @("IssuanceAuthorizationRules", "AuthorizationRules")
        $claimSummary = Get-ClaimRuleSummary -Value $transformRules
        if (-not $claimSummary) {
            $claimSummary = Get-FirstText -InputObject $rp -Names @("ClaimRulesSummary")
        }

        $rows += [pscustomobject][ordered]@{
            RpId = "RP{0:000}" -f $index
            Name = Protect-Value -Value (Get-FirstText -InputObject $rp -Names @("Name", "DisplayName")) -FieldName "Name"
            Identifier = Protect-Value -Value (Get-FirstText -InputObject $rp -Names @("Identifier", "Identifiers", "RelyingPartyIdentifier")) -FieldName "Identifier"
            Enabled = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $rp -Names @("Enabled", "IsEnabled"))
            ProtocolProfile = Get-FirstText -InputObject $rp -Names @("ProtocolProfile", "Protocol")
            AccessControlPolicyName = Get-FirstText -InputObject $rp -Names @("AccessControlPolicyName", "AccessControlPolicy")
            IssuanceAuthorizationRulesSummary = Protect-Value -Value (Get-ClaimRuleSummary -Value $authRules) -FieldName "IssuanceAuthorizationRulesSummary"
            IssuanceTransformRulesSummary = Protect-Value -Value $claimSummary -FieldName "IssuanceTransformRulesSummary"
            ClaimRulesSummary = Protect-Value -Value $claimSummary -FieldName "ClaimRulesSummary"
            TokenLifetime = Get-FirstText -InputObject $rp -Names @("TokenLifetime", "TokenLifetimeInMinutes")
            EncryptionCertificateExpires = $encryptionExpiry
            SignatureAlgorithm = Get-FirstText -InputObject $rp -Names @("SignatureAlgorithm", "SamlResponseSignature")
            SourceCollection = $CollectionPath
            Notes = Protect-Value -Value (Get-FirstText -InputObject $rp -Names @("Notes", "Description")) -FieldName "Notes"
        }
    }
    return @($rows)
}

function Get-CertificateRows {
    param(
        [Parameter()][object]$Adfs,
        [Parameter()][string]$CollectionPath
    )

    $certs = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $Adfs -Names @("Certificates", "AdfsCertificates")))
    $props = Get-PropertyValue -InputObject $Adfs -Names @("Properties", "AdfsProperties")
    $serviceName = Get-FirstText -InputObject $props -Names @("HostName", "FederationServiceName", "FederationServiceIdentifier")
    $rows = @()
    $index = 0
    foreach ($cert in $certs) {
        $index++
        $notAfter = Get-FirstText -InputObject $cert -Names @("NotAfter", "CertificateNotAfter", "Expiration")
        if (-not $notAfter) { $notAfter = ConvertTo-Text -Value (Get-PathValue -InputObject $cert -Path @("Certificate", "NotAfter")) }
        $notBefore = Get-FirstText -InputObject $cert -Names @("NotBefore", "CertificateNotBefore")
        if (-not $notBefore) { $notBefore = ConvertTo-Text -Value (Get-PathValue -InputObject $cert -Path @("Certificate", "NotBefore")) }

        $rows += [pscustomobject][ordered]@{
            CertificateId = "CERT{0:00}" -f $index
            ServiceName = Protect-Value -Value $serviceName -FieldName "Identifier"
            CertificateType = Get-FirstText -InputObject $cert -Names @("CertificateType", "Type", "Usage")
            IsPrimary = ConvertTo-BoolText -Value (Get-PropertyValue -InputObject $cert -Names @("IsPrimary", "Primary"))
            Subject = Protect-Value -Value (Get-FirstText -InputObject $cert -Names @("Subject", "CertificateSubject")) -FieldName "Subject"
            Thumbprint = Protect-Value -Value (Get-FirstText -InputObject $cert -Names @("Thumbprint", "CertificateThumbprint")) -FieldName "Thumbprint"
            NotBefore = $notBefore
            NotAfter = $notAfter
            DaysUntilExpiration = Get-DaysUntil -Value $notAfter
            Risk = Get-ExpirationRisk -Value $notAfter
            SourceCollection = $CollectionPath
            Notes = Protect-Value -Value (Get-FirstText -InputObject $cert -Names @("Notes", "Description")) -FieldName "Notes"
        }
    }
    return @($rows)
}

function Get-EndpointRows {
    $referenceConnectPorts = "https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-ports"
    $referencePta = "https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-pta-quick-start"
    $referenceAdfs = "https://learn.microsoft.com/en-us/windows-server/identity/ad-fs/deployment/best-practices-securing-ad-fs"

    $rows = @(
        @("EP001","Entra Connect to AD DS","Entra Connect server","Destination AD forest DNS servers","TCP/UDP","53","Outbound","DNS lookups on the destination forest.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP002","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP/UDP","88","Outbound","Kerberos authentication to AD DS.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP003","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP","135","Outbound","RPC endpoint mapper for forest binding and password synchronization.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP004","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP/UDP","389","Outbound","LDAP data import from AD DS.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP005","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP","445","Outbound","SMB for Seamless SSO setup and password writeback workflows where used.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP006","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP/UDP","636","Outbound","LDAPS data import when TLS is used.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP007","Entra Connect to AD DS","Entra Connect server","Destination AD forest global catalog","TCP","3268","Outbound","Global catalog lookup for Seamless SSO workflows.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP008","Entra Connect to AD DS","Entra Connect server","AD DS Web Services","TCP","9389","Outbound","AD DS Web Services when AD FS with gMSA is installed by the wizard.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP009","Entra Connect to AD DS","Entra Connect server","Destination AD forest domain controllers","TCP","49152-65535","Outbound","Modern Windows dynamic RPC range unless customized.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP010","Entra Connect to Entra ID","Entra Connect server","Microsoft Entra ID and certificate revocation endpoints","TCP","80","Outbound","CRL downloads for TLS certificate validation.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP011","Entra Connect to Entra ID","Entra Connect server","Microsoft Entra ID","TCP","443","Outbound","Synchronization with Microsoft Entra ID.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP012","Entra Connect to AD FS/WAP","Entra Connect server","AD FS federation and WAP servers","TCP","5985","Outbound","WinRM listener used by the Entra Connect wizard for AD FS/WAP configuration workflows.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP013","WAP to AD FS","Web Application Proxy","AD FS federation servers","TCP","443","Outbound","Authentication traffic from WAP to federation servers.","ReferenceOnly",$referenceAdfs,"Review requirement only; not reachability proof."),
        @("EP014","Users to WAP","Users and clients","Web Application Proxy","TCP","443","Inbound","Device and browser authentication traffic.","ReferenceOnly",$referenceAdfs,"Review requirement only; not reachability proof."),
        @("EP015","Users to WAP","Users and clients","Web Application Proxy","TCP","49443","Inbound","Certificate authentication when enabled.","ReferenceOnly",$referenceAdfs,"Optional; review requirement only; not reachability proof."),
        @("EP016","AD FS farm sync","AD FS federation servers and WAP","Farm peers and proxies","TCP","80","Restricted internal","Configuration synchronization and some load balancer probes.","ReferenceOnly",$referenceAdfs,"Restrict to farm, proxy, and approved load balancer addresses."),
        @("EP017","PTA agent to Entra ID","Pass-through Authentication agent","Microsoft Entra ID and CRL endpoints","TCP","80","Outbound","CRL downloads and connector auto-update support.","ReferenceOnly",$referencePta,"Review requirement only; not reachability proof."),
        @("EP018","PTA agent to Entra ID","Pass-through Authentication agent","Microsoft Entra ID","TCP","443","Outbound","Agent registration, updates, status, and sign-in request handling.","ReferenceOnly",$referencePta,"Review requirement only; not reachability proof."),
        @("EP019","PTA agent status","Pass-through Authentication agent","Microsoft Entra ID","TCP","8080","Outbound","Optional status reporting fallback if 443 is unavailable.","ReferenceOnly",$referencePta,"Optional; not used for user sign-ins."),
        @("EP020","PTA agent endpoints","Pass-through Authentication agent","*.msappproxy.net; *.servicebus.windows.net; login.windows.net; login.microsoftonline.com","TCP","443","Outbound","PTA service connectivity and initial registration endpoints.","ReferenceOnly",$referencePta,"Review with current Microsoft URL/IP guidance."),
        @("EP021","Connect Health","Microsoft Entra Connect Health agent","Microsoft Entra ID","TCP","443","Outbound","Health telemetry fallback and current required port for recent agents.","ReferenceOnly",$referenceConnectPorts,"Review requirement only; not reachability proof."),
        @("EP022","Connect Health","Microsoft Entra Connect Health agent","Azure Service Bus","TCP","5671","Outbound","Health telemetry for older/recommended agent configurations.","ReferenceOnly",$referenceConnectPorts,"May not be required for latest agent versions; review current Microsoft guidance.")
    )

    $objects = @()
    foreach ($row in $rows) {
        $objects += [pscustomobject][ordered]@{
            EndpointId = $row[0]
            Area = $row[1]
            Source = $row[2]
            Destination = $row[3]
            Protocol = $row[4]
            Port = $row[5]
            Direction = $row[6]
            Purpose = $row[7]
            EvidenceType = $row[8]
            ReferenceSource = $row[9]
            Notes = $row[10]
        }
    }
    return @($objects)
}

$inputDirectory = Resolve-Path -LiteralPath $InputPath
$getJsonParams = @{
    LiteralPath = $inputDirectory.Path
    Filter = "*.collection.json"
    File = $true
}
if ($Recurse) {
    $getJsonParams["Recurse"] = $true
}

$collectionFiles = @(Get-ChildItem @getJsonParams | Sort-Object FullName)
if ($collectionFiles.Count -eq 0) {
    $fallbackParams = @{
        LiteralPath = $inputDirectory.Path
        Filter = "*.json"
        File = $true
    }
    if ($Recurse) {
        $fallbackParams["Recurse"] = $true
    }
    $collectionFiles = @(Get-ChildItem @fallbackParams | Sort-Object FullName)
}

$collections = @()
foreach ($file in $collectionFiles) {
    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $collections += [pscustomobject]@{
            File = $file.FullName
            Data = $json
        }
    }
    catch {
        Write-Warning "Skipping JSON file that could not be parsed: $($file.FullName) - $($_.Exception.Message)"
    }
}

$rawCollections = @($collections)
$expandedCollections = @($collections)
foreach ($collectionItem in @($rawCollections)) {
    $exports = @(ConvertTo-ObjectArray -Value (Get-PropertyValue -InputObject $collectionItem.Data -Names @("OfflineExports")))
    foreach ($export in $exports) {
        $parsed = Get-PropertyValue -InputObject $export -Names @("ParsedObject")
        if ($null -eq $parsed) {
            continue
        }

        $hasKnownPayload = $false
        foreach ($name in @("EntraConnect", "AzureADConnect", "ADSync", "Adfs", "ADFS", "Federation", "Wap", "WebApplicationProxy", "PassThroughAuthentication", "Pta", "PTA")) {
            if (Get-PropertyValue -InputObject $parsed -Names @($name)) {
                $hasKnownPayload = $true
                break
            }
        }
        if (-not $hasKnownPayload) {
            continue
        }

        $exportName = Get-FirstText -InputObject $export -Names @("Name")
        if (-not $exportName) {
            $exportName = "offline-export"
        }
        $expandedCollections += [pscustomobject]@{
            File = "$($collectionItem.File)::OfflineExport::$exportName"
            Data = $parsed
        }
    }
}
$collections = @($expandedCollections)

$summaryRows = @()
$connectorRows = @()
$scopeRows = @()
$ruleRows = @()
$farmRows = @()
$rpRows = @()
$certRows = @()
$findingRows = @()
$topologyRows = @()
$findingIndex = 0
$edgeIndex = 0

foreach ($collectionItem in $collections) {
    $collection = $collectionItem.Data
    $collectionPath = $collectionItem.File
    $serverName = Get-CollectionServerName -Collection $collection -DefaultName ([System.IO.Path]::GetFileNameWithoutExtension($collectionPath))
    $entra = Get-PropertyValue -InputObject $collection -Names @("EntraConnect", "AzureADConnect", "ADSync")
    $adfs = Get-PropertyValue -InputObject $collection -Names @("Adfs", "ADFS", "Federation")
    $wap = Get-PropertyValue -InputObject $collection -Names @("Wap", "WebApplicationProxy")
    $pta = Get-PropertyValue -InputObject $collection -Names @("PassThroughAuthentication", "Pta", "PTA")

    $mode = Get-SyncModeSummary -EntraConnect $entra -Adfs $adfs -Pta $pta
    $anchor = Get-SourceAnchorSummary -EntraConnect $entra
    $writeback = Get-WritebackSummary -EntraConnect $entra
    $tenant = Get-FirstText -InputObject $entra -Names @("Tenant", "TenantId", "TenantName", "AzureAdTenant", "EntraTenant")
    if (-not $tenant) {
        $cloud = Get-PropertyValue -InputObject $collection -Names @("Cloud", "CloudDiscovery")
        $tenant = Get-FirstText -InputObject $cloud -Names @("Tenant", "TenantId", "DisplayName")
    }

    if ($entra) {
        $summaryRows += [pscustomobject][ordered]@{
            ComponentId = "CMP{0:00}" -f ($summaryRows.Count + 1)
            ComponentType = "EntraConnect"
            Name = "Microsoft Entra Connect"
            ServerName = $serverName
            Role = "Synchronization"
            SyncMode = $mode.SyncMode
            PasswordHashSync = $mode.PasswordHashSync
            PassThroughAuthentication = $mode.PassThroughAuthentication
            Federation = $mode.Federation
            StagingMode = $mode.StagingMode
            SourceAnchor = Protect-Value -Value $anchor.SourceAnchor -FieldName "SourceAnchor"
            ImmutableIdAttribute = Protect-Value -Value $anchor.ImmutableIdAttribute -FieldName "ImmutableIdAttribute"
            WritebackFeatures = $writeback
            Tenant = Protect-Value -Value $tenant -FieldName "Tenant"
            CollectionStatus = Get-FirstText -InputObject $collection -Names @("CollectionStatus")
            Evidence = "ADSync module/registry/service/offline export evidence"
            SourceCollection = $collectionPath
            Notes = ""
        }
    }

    if ($adfs) {
        $summaryRows += [pscustomobject][ordered]@{
            ComponentId = "CMP{0:00}" -f ($summaryRows.Count + 1)
            ComponentType = "ADFS"
            Name = "AD FS"
            ServerName = $serverName
            Role = "Federation"
            SyncMode = $mode.SyncMode
            PasswordHashSync = $mode.PasswordHashSync
            PassThroughAuthentication = $mode.PassThroughAuthentication
            Federation = "detected"
            StagingMode = $mode.StagingMode
            SourceAnchor = ""
            ImmutableIdAttribute = ""
            WritebackFeatures = ""
            Tenant = Protect-Value -Value $tenant -FieldName "Tenant"
            CollectionStatus = Get-FirstText -InputObject $collection -Names @("CollectionStatus")
            Evidence = "AD FS module/service/offline export evidence"
            SourceCollection = $collectionPath
            Notes = ""
        }
    }

    if ($pta) {
        $summaryRows += [pscustomobject][ordered]@{
            ComponentId = "CMP{0:00}" -f ($summaryRows.Count + 1)
            ComponentType = "PTA"
            Name = "Pass-through Authentication"
            ServerName = $serverName
            Role = "AuthenticationAgent"
            SyncMode = $mode.SyncMode
            PasswordHashSync = $mode.PasswordHashSync
            PassThroughAuthentication = if ($mode.PassThroughAuthentication) { $mode.PassThroughAuthentication } else { "detected" }
            Federation = $mode.Federation
            StagingMode = $mode.StagingMode
            SourceAnchor = ""
            ImmutableIdAttribute = ""
            WritebackFeatures = ""
            Tenant = Protect-Value -Value $tenant -FieldName "Tenant"
            CollectionStatus = Get-FirstText -InputObject $collection -Names @("CollectionStatus")
            Evidence = "PTA service/module/offline export evidence"
            SourceCollection = $collectionPath
            Notes = ""
        }
    }

    $newConnectorRows = @(Get-ConnectorRows -EntraConnect $entra -ServerName $serverName -CollectionPath $collectionPath)
    $connectorRows += $newConnectorRows
    $scopeRows += Get-ScopeRows -ConnectorRows $newConnectorRows -CollectionPath $collectionPath
    $ruleRows += Get-RuleRows -EntraConnect $entra -CollectionPath $collectionPath
    $farmRows += Get-AdfsFarmRows -Adfs $adfs -Wap $wap -ServerName $serverName -CollectionPath $collectionPath
    $rpRows += Get-RelyingPartyRows -Adfs $adfs -CollectionPath $collectionPath
    $certRows += Get-CertificateRows -Adfs $adfs -CollectionPath $collectionPath

    foreach ($warning in @(Get-PropertyValue -InputObject $collection -Names @("CollectionWarnings", "Warnings"))) {
        $findingIndex++
        $findingRows += New-Finding -Index $findingIndex -Severity "Info" -Area "Collection" -ObjectName $serverName -Finding "Collection warning" -Evidence (ConvertTo-Text -Value $warning) -Recommendation "Review source export completeness before relying on absence of evidence." -SourceCollection $collectionPath
    }
    foreach ($errorItem in @(Get-PropertyValue -InputObject $collection -Names @("CollectionErrors", "Errors"))) {
        $findingIndex++
        $findingRows += New-Finding -Index $findingIndex -Severity "Warning" -Area "Collection" -ObjectName $serverName -Finding "Collection error" -Evidence (ConvertTo-Text -Value $errorItem) -Recommendation "Re-run collection from the role holder or provide an offline export for the missing area." -SourceCollection $collectionPath
    }

    $hasSyncImportEdge = $false
    foreach ($connector in @($newConnectorRows)) {
        if ($null -eq $connector) {
            continue
        }
        $connectorText = "$($connector.ConnectorName) $($connector.ConnectorType) $($connector.ForestOrTenant)"
        if ($connectorText -match '(?i)(azure active directory|windows azure|microsoft entra|aad|entra id)') {
            continue
        }

        $forestName = $connector.ForestOrTenant
        if (-not $forestName) { $forestName = "On-premises directory" }
        $edgeIndex++
        $topologyRows += New-TopologyEdge -Index $edgeIndex -Source $forestName -SourceType "ADForest" -Relationship "SyncImport" -Target $serverName -TargetType "EntraConnectServer" -Label $connector.ConnectorName -Status $connector.IsEnabled -SourceCollection $collectionPath -Notes $connector.ConnectorType
        $hasSyncImportEdge = $true
        if ($writeback) {
            $edgeIndex++
            $topologyRows += New-TopologyEdge -Index $edgeIndex -Source "Microsoft Entra ID" -SourceType "CloudIdentity" -Relationship "Writeback" -Target $forestName -TargetType "ADForest" -Label $writeback -Status "" -SourceCollection $collectionPath -Notes "Writeback feature evidence; review configuration before treating as enabled."
        }
    }
    if ($entra -and ($hasSyncImportEdge -or $newConnectorRows.Count -gt 0)) {
        $edgeIndex++
        $topologyRows += New-TopologyEdge -Index $edgeIndex -Source $serverName -SourceType "EntraConnectServer" -Relationship "SyncExport" -Target "Microsoft Entra ID" -TargetType "CloudIdentity" -Label $mode.SyncMode -Status "" -SourceCollection $collectionPath -Notes $writeback
    }

    foreach ($farm in @(Get-AdfsFarmRows -Adfs $adfs -Wap $wap -ServerName $serverName -CollectionPath $collectionPath)) {
        $edgeIndex++
        $topologyRows += New-TopologyEdge -Index $edgeIndex -Source $farm.ServiceName -SourceType "AdfsFarm" -Relationship "Federates" -Target "Microsoft Entra ID" -TargetType "CloudIdentity" -Label "Federation trust" -Status $farm.CertificateRisk -SourceCollection $collectionPath -Notes "AD FS farm evidence"
    }

    foreach ($rp in @(Get-RelyingPartyRows -Adfs $adfs -CollectionPath $collectionPath)) {
        $edgeIndex++
        $targetName = $rp.Name
        if (-not $targetName) { $targetName = "Relying party" }
        $edgeSource = "AD FS"
        if ($farmRows.Count -gt 0) { $edgeSource = $farmRows[-1].ServiceName }
        $topologyRows += New-TopologyEdge -Index $edgeIndex -Source $edgeSource -SourceType "AdfsFarm" -Relationship "IssuesTokenTo" -Target $targetName -TargetType "RelyingParty" -Label $rp.ProtocolProfile -Status $rp.Enabled -SourceCollection $collectionPath -Notes $rp.ClaimRulesSummary
    }

    if ($mode.PassThroughAuthentication) {
        $edgeIndex++
        $topologyRows += New-TopologyEdge -Index $edgeIndex -Source $serverName -SourceType "PtaAgent" -Relationship "AuthenticatesVia" -Target "Microsoft Entra ID" -TargetType "CloudIdentity" -Label "PTA" -Status $mode.PassThroughAuthentication -SourceCollection $collectionPath -Notes "PTA agent evidence from collection."
    }
}

$summaryRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "hybrid-identity-summary.csv" -Fields $SummaryFields
$summaryRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "hybrid-identity-summary.csv" -Fields $SummaryFields
$connectorRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "sync-connectors.csv" -Fields $ConnectorFields
$connectorRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "sync-connectors.csv" -Fields $ConnectorFields
$scopeRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "sync-scope-summary.csv" -Fields $ScopeFields
$scopeRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "sync-scope-summary.csv" -Fields $ScopeFields
$ruleRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "sync-rules-summary.csv" -Fields $RuleFields
$ruleRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "sync-rules-summary.csv" -Fields $RuleFields
$farmRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "federation-adfs-farm.csv" -Fields $FarmFields
$farmRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "federation-adfs-farm.csv" -Fields $FarmFields
$rpRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "federation-relying-parties.csv" -Fields $RelyingPartyFields
$rpRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "federation-relying-parties.csv" -Fields $RelyingPartyFields
$certRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "federation-certificates.csv" -Fields $CertificateFields
$certRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "federation-certificates.csv" -Fields $CertificateFields
$findingRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "hybrid-findings.csv" -Fields $FindingFields
$findingRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "hybrid-findings.csv" -Fields $FindingFields
$topologyRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "topology-relationships.csv" -Fields $TopologyFields
$topologyRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "topology-relationships.csv" -Fields $TopologyFields

foreach ($cert in @($certRows)) {
    if ($cert.Risk -in @("Expired", "Critical", "Warning")) {
        $findingIndex++
        $severity = if ($cert.Risk -eq "Expired") { "Critical" } elseif ($cert.Risk -eq "Critical") { "High" } else { "Medium" }
        $findingRows += New-Finding -Index $findingIndex -Severity $severity -Area "FederationCertificates" -ObjectName $cert.ServiceName -Finding "$($cert.CertificateType) certificate expiration risk: $($cert.Risk)" -Evidence "Expires $($cert.NotAfter); days remaining $($cert.DaysUntilExpiration)" -Recommendation "Validate certificate rollover and relying-party trust update process." -SourceCollection $cert.SourceCollection
    }
}

foreach ($farm in @($farmRows)) {
    if (-not $farm.TokenSigningCertExpires -or -not $farm.TokenDecryptingCertExpires) {
        $findingIndex++
        $findingRows += New-Finding -Index $findingIndex -Severity "Medium" -Area "FederationCertificates" -ObjectName $farm.ServiceName -Finding "AD FS token certificate expiration data is incomplete" -Evidence "Token signing: $($farm.TokenSigningCertExpires); token decrypting: $($farm.TokenDecryptingCertExpires)" -Recommendation "Collect AD FS certificates from a federation server and confirm automatic certificate rollover state." -SourceCollection $farm.SourceCollection
    }
}

foreach ($summary in @($summaryRows)) {
    if ($summary.ComponentType -eq "EntraConnect" -and $summary.StagingMode -eq "true") {
        $findingIndex++
        $findingRows += New-Finding -Index $findingIndex -Severity "Info" -Area "SyncMode" -ObjectName $summary.ServerName -Finding "Entra Connect staging mode is enabled" -Evidence "StagingMode=$($summary.StagingMode)" -Recommendation "Confirm whether this is the intended staging server and identify the active sync server." -SourceCollection $summary.SourceCollection
    }
    if ($summary.ComponentType -eq "PTA") {
        $ptaCount = @($summaryRows | Where-Object { $_.ComponentType -eq "PTA" }).Count
        if ($ptaCount -gt 0 -and $ptaCount -lt 3) {
            $findingIndex++
            $findingRows += New-Finding -Index $findingIndex -Severity "Medium" -Area "PTA" -ObjectName "Pass-through Authentication" -Finding "Fewer than three PTA agents were discovered in the provided exports" -Evidence "Discovered PTA summary rows: $ptaCount" -Recommendation "Validate tenant agent count in Microsoft Entra admin center or cloud export; Microsoft recommends multiple agents for production resilience." -SourceCollection $summary.SourceCollection
            break
        }
    }
}

if ($collections.Count -eq 0 -and $summaryRows.Count -eq 0 -and $connectorRows.Count -eq 0 -and $farmRows.Count -eq 0) {
    throw "No usable hybrid identity collection JSON or supported CSV exports were found in $($inputDirectory.Path)."
}

if (-not $NoRedaction) {
    $findingIndex++
    $findingRows += New-Finding -Index $findingIndex -Severity "Info" -Area "Redaction" -ObjectName "Aggregation" -Finding "Default redaction was applied" -Evidence "Tenant-sensitive identifiers, immutable IDs, thumbprints, tokens, credentials, and private material are redacted by default." -Recommendation "Use -NoRedaction only in a controlled workspace when exact identifiers are required for review." -SourceCollection ""
}

$endpointRows = Get-EndpointRows
$endpointRows += Import-ManualCsvRows -Directory $inputDirectory.Path -FileName "hybrid-endpoints-ports.csv" -Fields $EndpointFields
$endpointRows += Import-PackagedCsvRows -CollectionItems $rawCollections -FileName "hybrid-endpoints-ports.csv" -Fields $EndpointFields

$outputDirectory = New-Item -ItemType Directory -Path $OutputPath -Force
$inventoryPath = Join-Path $outputDirectory.FullName "inventory.json"
$summaryCsvPath = Join-Path $outputDirectory.FullName "hybrid-identity-summary.csv"
$connectorCsvPath = Join-Path $outputDirectory.FullName "sync-connectors.csv"
$scopeCsvPath = Join-Path $outputDirectory.FullName "sync-scope-summary.csv"
$ruleCsvPath = Join-Path $outputDirectory.FullName "sync-rules-summary.csv"
$farmCsvPath = Join-Path $outputDirectory.FullName "federation-adfs-farm.csv"
$rpCsvPath = Join-Path $outputDirectory.FullName "federation-relying-parties.csv"
$certCsvPath = Join-Path $outputDirectory.FullName "federation-certificates.csv"
$findingCsvPath = Join-Path $outputDirectory.FullName "hybrid-findings.csv"
$endpointCsvPath = Join-Path $outputDirectory.FullName "hybrid-endpoints-ports.csv"
$topologyCsvPath = Join-Path $outputDirectory.FullName "topology-relationships.csv"

$inventory = [ordered]@{
    Metadata = [ordered]@{
        Source = "HybridIdentityFederationCollections"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString("o")
        CollectionCount = $collections.Count
        SummaryCount = $summaryRows.Count
        ConnectorCount = $connectorRows.Count
        ScopeCount = $scopeRows.Count
        RuleCount = $ruleRows.Count
        AdfsFarmCount = $farmRows.Count
        RelyingPartyCount = $rpRows.Count
        CertificateCount = $certRows.Count
        FindingCount = $findingRows.Count
        TopologyEdgeCount = $topologyRows.Count
        RedactionEnabled = (-not $NoRedaction)
    }
    CollectionFiles = @($collections | ForEach-Object { $_.File })
    HybridSummary = @($summaryRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $SummaryFields })
    SyncConnectors = @($connectorRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $ConnectorFields })
    SyncScopeSummary = @($scopeRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $ScopeFields })
    SyncRulesSummary = @($ruleRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $RuleFields })
    FederationAdfsFarm = @($farmRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $FarmFields })
    FederationRelyingParties = @($rpRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $RelyingPartyFields })
    FederationCertificates = @($certRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $CertificateFields })
    HybridFindings = @($findingRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $FindingFields })
    RequiredEndpointsPorts = @($endpointRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $EndpointFields })
    TopologyEdges = @($topologyRows | ForEach-Object { ConvertTo-FieldRow -Row $_ -Fields $TopologyFields })
}

([pscustomobject]$inventory) | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
@($inventory.HybridSummary) | Select-Object $SummaryFields | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.SyncConnectors) | Select-Object $ConnectorFields | Export-Csv -LiteralPath $connectorCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.SyncScopeSummary) | Select-Object $ScopeFields | Export-Csv -LiteralPath $scopeCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.SyncRulesSummary) | Select-Object $RuleFields | Export-Csv -LiteralPath $ruleCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.FederationAdfsFarm) | Select-Object $FarmFields | Export-Csv -LiteralPath $farmCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.FederationRelyingParties) | Select-Object $RelyingPartyFields | Export-Csv -LiteralPath $rpCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.FederationCertificates) | Select-Object $CertificateFields | Export-Csv -LiteralPath $certCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.HybridFindings) | Select-Object $FindingFields | Export-Csv -LiteralPath $findingCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.RequiredEndpointsPorts) | Select-Object $EndpointFields | Export-Csv -LiteralPath $endpointCsvPath -NoTypeInformation -Encoding UTF8
@($inventory.TopologyEdges) | Select-Object $TopologyFields | Export-Csv -LiteralPath $topologyCsvPath -NoTypeInformation -Encoding UTF8

[pscustomobject]@{
    InputPath = $inputDirectory.Path
    CollectionCount = $collections.Count
    InventoryJson = $inventoryPath
    HybridIdentitySummaryCsv = $summaryCsvPath
    SyncConnectorsCsv = $connectorCsvPath
    SyncScopeSummaryCsv = $scopeCsvPath
    SyncRulesSummaryCsv = $ruleCsvPath
    FederationAdfsFarmCsv = $farmCsvPath
    FederationRelyingPartiesCsv = $rpCsvPath
    FederationCertificatesCsv = $certCsvPath
    HybridFindingsCsv = $findingCsvPath
    EndpointPortsCsv = $endpointCsvPath
    TopologyRelationshipsCsv = $topologyCsvPath
}
