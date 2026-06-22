# Requirements

## Discovery

- Collect forest and domain functional levels.
- Collect schema naming context, schema `objectVersion`, schema master, and schema update state where readable.
- Collect domain naming master and naming contexts.
- Collect configuration, schema, domain, and application partitions.
- Identify DNS application partitions and replica locations.
- Collect optional AD features, including Recycle Bin enablement state.
- Collect tombstone lifetime and deleted object lifetime where readable.
- Collect UPN suffixes and SPN suffixes.
- Collect sites and global catalog summary only as forest context.
- Collect forest/domain-wide settings that affect migration or compatibility.
- Do not query, model, or render trusts.
- Do not modify schema, forest configuration, domain configuration, optional features, partitions, naming contexts, or any AD object.

## Aggregation

- Merge one or more `*.forest-config.collection.json` files offline.
- Preserve source collection metadata and warnings.
- Produce normalized CSVs for review:
  - `forest-summary.csv`
  - `domain-summary.csv`
  - `schema-summary.csv`
  - `naming-contexts.csv`
  - `application-partitions.csv`
  - `optional-features.csv`
  - `forest-config-findings.csv`
- Produce `inventory.json` for downstream rendering.
- Produce `forest-config-relationships.csv` and a simple Mermaid diagram for traceability.

## Rendering

- Render diagrams from `inventory.json`.
- Render diagrams from editable `forest-config-relationships.csv`.
- Keep diagrams focused on forest configuration relationships, not detailed site topology or trusts.
- Preserve relationship edge IDs so diagrams can be traced back to CSV rows.

## Safety

- Discovery scripts must use read-only cmdlets and LDAP reads only.
- Scripts must not call AD cmdlets that create, set, enable, disable, move, remove, or rename objects.
- Any unavailable attribute should be reported as a collection warning rather than causing broad failure when possible.

