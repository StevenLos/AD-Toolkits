# High-Level Design

## Purpose

This toolkit creates a current-state view of Active Directory forest configuration for migration and compatibility planning. It captures forest-wide structure and settings that are easy to miss when reviewing only domains, DNS, or Sites and Services.

## Workflow

1. Collect read-only AD forest configuration into one JSON bundle.
2. Merge one or more bundles into normalized inventory and CSV review files.
3. Render simple diagrams that show how forests, domains, naming contexts, application partitions, FSMO owners, optional features, and DNS application partition replicas relate.

## Primary Objects

- Forest
- Domains
- Schema
- Naming contexts
- Cross-reference partitions
- Application partitions
- DNS application partitions
- Optional features
- UPN and SPN suffixes
- Light site/global catalog context

## Explicit Exclusions

- Trust discovery and trust diagrams.
- Detailed AD Sites and Services topology.
- Replication connection objects and replication health.
- DNS zone/record detail.
- Any schema or AD configuration write operation.

Trusts, full ADSS topology, and DNS record maps belong in separate sibling toolkits.

## Output Model

The merger writes an `inventory.json` file with these normalized sections:

- `ForestSummary`
- `DomainSummary`
- `SchemaSummary`
- `NamingContexts`
- `ApplicationPartitions`
- `OptionalFeatures`
- `Findings`
- `Relationships`
- `SitesGcContext`
- `SourceCollections`

The renderer consumes `Relationships` to create edge-labeled diagrams. CSV outputs remain the review source of truth.

