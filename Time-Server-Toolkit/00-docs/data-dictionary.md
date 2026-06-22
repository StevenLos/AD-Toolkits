# Time Server Data Dictionary

## `time-relationship-details.csv`

| Column | Description |
| --- | --- |
| `TimeEdgeId` | Stable diagram edge identifier such as `T01`. |
| `SourceServer` | Queried server whose time configuration was collected. |
| `Relationship` | Relationship type: `SyncsFrom`, `ConfiguredPeer`, `UsesLocalClock`, `UsesHypervisor`, or `UnknownSource`. |
| `Target` | Time source, configured peer, local clock, hypervisor provider, or unknown target. |
| `TargetType` | Target category such as `NtpPeer`, `DomainTimeSource`, `LocalClock`, `Hypervisor`, or `Unknown`. |
| `ActiveSource` | Active source reported by `w32tm /query /source`. |
| `SourceType` | Inferred source category. |
| `IsTimeServer` | Whether evidence indicates the queried server serves time. |
| `NtpServerEnabled` | Registry/config value for the W32Time NTP server provider. |
| `NtpClientEnabled` | Registry/config value for the W32Time NTP client provider. |
| `Udp123Listening` | Whether UDP/123 appears to be listening on the queried system. |
| `W32TimeType` | W32Time sync type such as `NTP`, `NT5DS`, `AllSync`, `NoSync`, or blank. |
| `ServiceStatus` | `W32Time` service state. |
| `Stratum` | Reported stratum from `w32tm /query /status`. |
| `LastSuccessfulSyncTime` | Reported last successful sync time, when available. |
| `Offset` | Reported phase offset or clock offset, when available. |
| `Status` | Collection or relationship status. |
| `CollectionServer` | Server targeted by the collector. |
| `Notes` | Evidence summary or collection warnings. |

## `time-server-summary.csv`

| Column | Description |
| --- | --- |
| `ServerName` | Queried server name. |
| `Fqdn` | Fully qualified DNS name when resolved. |
| `IPAddress` | Resolved IP addresses joined with semicolons. |
| `IsTimeServer` | Evidence-based time-server classification. |
| `Source` | Active source reported by `w32tm`. |
| `SourceType` | Inferred source type. |
| `W32TimeType` | W32Time sync type. |
| `NtpServerEnabled` | NTP server provider enabled flag. |
| `NtpClientEnabled` | NTP client provider enabled flag. |
| `Udp123Listening` | UDP/123 listening flag. |
| `ServiceStatus` | W32Time service state. |
| `DomainRole` | Windows domain role integer from `Win32_ComputerSystem`. |
| `Stratum` | Reported stratum. |
| `LastSuccessfulSyncTime` | Reported last successful sync time. |
| `Status` | Collection status. |
| `Evidence` | Semicolon-separated classification evidence. |

